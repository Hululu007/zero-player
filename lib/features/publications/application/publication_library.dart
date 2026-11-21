import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../books/data/book_site_check.dart';
import '../../books/data/book_store.dart';
import '../../books/domain/book.dart';
import '../../supervision/application/content_policy.dart';
import '../data/publication_documents.dart';
import '../data/publication_reading.dart';
import '../data/publication_space.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';

typedef PublicationOpened = ({
  Book book,
  File file,
  DocumentAdmission admission,
  String lease,
  bool Function() allowed,
});

final class PublicationLibrary {
  PublicationLibrary(
    this.store,
    this.space,
    this.legacy,
    this.legacyDocuments,
    this.policy,
    this.bookAllowed,
  );
  final PublicationStore store;
  final PublicationSpace space;
  final BookStore legacy;
  final Directory legacyDocuments;
  final ContentPolicy policy;
  final bool Function(Book) bookAllowed;

  String get _policy => '1:${bookSitePolicySnapshot(policy)}';

  void requireImport(String text) {
    if (policy.supervision.enabled ||
        policy.supervision.corrupted ||
        !policy.textAllowed(text)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  Future<List<PublicationHolding>> holdings() => _holdings(unlisted: false);

  Future<List<PublicationHolding>> unlistedCopies() =>
      _holdings(unlisted: true);

  Future<List<PublicationHolding>> _holdings({required bool unlisted}) async {
    await store.initialize();
    final books = {
      for (final entry in [
        ...await legacy.shelf(),
        ...await legacy.vaultShelf(),
      ])
        entry.book.id: entry.book,
    };
    final selection = unlisted
        ? '''s.removed=1 AND f.placement IN ('managed','retained')
        AND NOT EXISTS(SELECT 1 FROM publication_shelf active
          WHERE active.digest=f.digest AND active.removed=0)'''
        : 's.removed=0';
    final rows = await store.db.rows('''
      SELECT s.id,s.edition,s.digest,s.kept,s.added,f.legacy_id,f.placement,f.format,f.bytes
      FROM publication_shelf s JOIN publication_files f ON f.digest=s.digest
      WHERE $selection ORDER BY s.added DESC,s.id''');
    final results = <PublicationHolding>[];
    final copies = <String>{};
    for (final row in rows) {
      final format = PublicationFormat.values.byName(row['format'] as String);
      final digest = row['digest'] as String;
      final id = row['legacy_id'] as String?;
      final attached = books[id];
      final raw = row['edition'];
      if (raw == null && attached == null) continue;
      final edition = raw == null
          ? _legacyEdition(attached!)
          : PublicationEdition.fromJson(jsonDecode(raw as String) as Map);
      final book =
          attached ??
          publicationReaderBook(digest, format, edition.title, edition.author);
      if (!await _canOpen(book)) continue;
      if (unlisted &&
          (await legacy.isPrivateBook(book.id) ||
              (_usesLegacyCopy(row) && await _hasLegacyOwner(book)) ||
              !copies.add(digest))) {
        continue;
      }
      results.add(
        PublicationHolding(
          id: row['id'] as String,
          edition: edition,
          digest: digest,
          format: format,
          bytes: row['bytes'] as int,
          resident: row['placement'] != null,
          kept: row['kept'] == 1,
          added: row['added'] as int,
          legacyId: id,
        ),
      );
    }
    return results;
  }

  Future<List<Book>> legacyBooks() async {
    return [
      for (final entry in [
        ...await legacy.shelf(),
        ...await legacy.vaultShelf(),
      ])
        if (entry.book.sourceId == 'local' &&
            isPublicationDigest(entry.book.uri.path) &&
            await _canOpen(entry.book) &&
            await _legacyFormat(entry.book) != null)
          entry.book,
    ];
  }

  Future<PublicationFormat?> _legacyFormat(Book book) async {
    final declared = PublicationFormat.fromName('book.${book.documentFormat}');
    for (final format
        in declared == null
            ? const [PublicationFormat.epub, PublicationFormat.pdf]
            : [declared]) {
      if (format != PublicationFormat.zip &&
          await _legacyFile(book.id, format).exists()) {
        return format;
      }
    }
    return null;
  }

  Future<void> attachLegacy(Book book) async {
    await store.initialize();
    final format = await _legacyFormat(book);
    if (format == null ||
        !_legacyIdentity(book) ||
        !await _canOpen(book) ||
        await legacy.entry(book) == null) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    final file = _legacyFile(book.id, format);
    final bytes = await file.length();
    final digest = book.uri.path;
    if (await publicationFileDigest(file, CancellationToken()) != digest) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    await store.db.atomic(() async {
      if (!await _canOpen(book) ||
          await legacy.entry(book) == null ||
          !await file.exists()) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      await store.db.write(
        'INSERT OR IGNORE INTO publication_files(digest,format,bytes,placement,legacy_id) VALUES(?,?,?,?,?)',
        [digest, format.name, bytes, 'legacy', book.id],
      );
      await store.db.write(
        "UPDATE publication_files SET legacy_id=?,placement=CASE "
        "WHEN placement='managed' THEN placement ELSE 'legacy' END WHERE digest=?",
        [book.id, digest],
      );
      await _hold(_legacyEdition(book), digest, attached: true);
      store.db.beforeCommit(() {
        if (!bookAllowed(book) ||
            (legacy.vault.isPrivate(book.id) && !legacy.vault.unlocked)) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
      });
    }, tables: {'publication_files', 'publication_shelf'});
  }

  Future<bool> removeLegacyDocument(
    Book book,
    Future<void> Function() removeRecord,
    bool clearOffline,
  ) async {
    if (!_legacyIdentity(book) || book.documentFormat == 'txt') return false;
    await store.initialize();
    final digest = book.uri.path;
    Future<void>? cleanup;
    final handled = await store.db.atomic(
      () async {
        final row = (await store.db.rows(
          '''SELECT f.placement,f.format,
          EXISTS(SELECT 1 FROM publication_shelf s WHERE s.digest=f.digest AND s.removed=0) AS held
          FROM publication_files f WHERE f.digest=?''',
          [digest],
        )).firstOrNull;
        final format = row == null
            ? await _legacyFormat(book)
            : PublicationFormat.values.byName(row['format'] as String);
        if (format == null) return false;
        final oldFile = _legacyFile(book.id, format);
        final held = row?['held'] == 1;
        if ((clearOffline && await space.hasLease(digest, oldFile)) ||
            (held && await legacy.isPrivateBook(book.id))) {
          throw const PublicationFailure(PublicationProblem.inUse);
        }
        if (held) await _saveLegacyReading(book);
        await removeRecord();
        if (!clearOffline) return true;
        if (_usesLegacyCopy(row) && held) {
          await store.db.write(
            "UPDATE publication_files SET placement='retained' WHERE digest=?",
            [digest],
          );
          return true;
        }
        if (row != null) {
          await store.db.write(
            _usesLegacyCopy(row)
                ? 'UPDATE publication_files SET legacy_id=NULL,placement=NULL,admitted=NULL WHERE digest=?'
                : 'UPDATE publication_files SET legacy_id=NULL WHERE digest=?',
            [digest],
          );
        }
        await store.db.write(
          'INSERT OR IGNORE INTO publication_legacy_releases VALUES(?,?)',
          [digest, format.name],
        );
        store.db.afterCommit(
          () => cleanup = _finishLegacyRelease(digest, format),
        );
        return true;
      },
      tables: {
        'app_meta',
        'publication_files',
        'publication_shelf',
        'publication_positions',
        'publication_notes',
        'publication_legacy_releases',
      },
    );
    await cleanup;
    return handled;
  }

  Future<Future<void> Function()?> holdLegacyDocument(
    Book book,
    File file,
  ) async {
    if (!_legacyIdentity(book)) return null;
    final format = PublicationFormat.fromName(file.path);
    if (format == null ||
        format == PublicationFormat.zip ||
        !p.equals(file.path, _legacyFile(book.id, format).path)) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    await store.initialize();
    final lease = await store.db.atomic(() async {
      if (!await _canOpen(book)) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      if (!await file.exists() || !await _hasLegacyOwner(book)) {
        throw const PublicationFailure(PublicationProblem.missing);
      }
      return space.lease(book.uri.path, file);
    }, tables: {'publication_leases'});
    return () => space.unlease(lease);
  }

  bool _legacyIdentity(Book book) =>
      book.sourceId == 'local' &&
      isPublicationDigest(book.uri.path) &&
      book.uri == Uri(scheme: 'book', path: book.uri.path) &&
      book.request.isEmpty;

  Future<void> _saveLegacyReading(Book book) async {
    final digest = book.uri.path;
    final reading = await legacyPublicationPosition(legacy, book);
    if (reading != null) {
      await store.db.write(
        'INSERT INTO publication_positions VALUES(?,?,?) '
        'ON CONFLICT(digest) DO UPDATE SET data=excluded.data,updated=excluded.updated',
        [digest, jsonEncode(encodeRichPosition(reading)), publicationNow()],
      );
    }
    final saved = await legacy.entry(book) ?? await legacy.detachedEntry(book);
    for (final note in await legacy.annotations(book)) {
      final index =
          saved?.chapters.indexWhere(
            (chapter) => chapter.id == note['chapter'],
          ) ??
          -1;
      await _copyLegacyNote(digest, note, index < 0 ? 0 : index);
    }
    await store.db.write(
      'UPDATE publication_shelf SET edition=? WHERE digest=? AND edition IS NULL',
      [jsonEncode(_legacyEdition(book).toJson()), digest],
    );
  }

  Future<void> _finishLegacyRelease(
    String digest,
    PublicationFormat format,
  ) async {
    final book = publicationReaderBook(digest, format, '', '');
    final file = _legacyFile(book.id, format);
    try {
      await store.db.atomic(() async {
        if ((await store.db.rows(
              'SELECT 1 FROM publication_legacy_releases WHERE digest=? AND format=?',
              [digest, format.name],
            )).isEmpty ||
            await space.hasLease(digest, file)) {
          return;
        }
        final state = await _fileState(digest);
        if (!(_usesLegacyCopy(state) && state?['legacy_id'] == book.id) &&
            !await _hasLegacyOwner(book) &&
            !await legacy.isPrivateBook(book.id) &&
            await file.exists()) {
          await file.delete();
        }
        await store.db.write(
          'DELETE FROM publication_legacy_releases WHERE digest=? AND format=?',
          [digest, format.name],
        );
      }, tables: {'publication_legacy_releases'});
    } on FileSystemException {
      // The committed removal can be retried when the file is accessible.
    }
  }

  Future<bool> _hasLegacyOwner(Book book) async =>
      await legacy.entry(book) != null ||
      await legacy.detachedEntry(book) != null;

  bool _usesLegacyCopy(Map<String, Object?>? state) =>
      state?['placement'] == 'legacy' || state?['placement'] == 'retained';

  Future<void> _copyLegacyNote(String digest, Map note, int index) async {
    final id = note['id'];
    if (id is! String || id.isEmpty) return;
    await store.db.write(
      'INSERT OR IGNORE INTO publication_notes VALUES(?,?,?,?,?,?,?)',
      [
        publicationId('$digest:$id'),
        digest,
        index,
        ((note['position'] as num?) ?? 0).toDouble().clamp(0, 1),
        publicationLabel(note['quote'], max: 1200),
        publicationLabel(note['note'], max: 4000),
        note['created'] is int ? note['created'] : publicationNow(),
      ],
    );
  }

  Future<String> importStaged(
    File file,
    String name,
    PublicationFormat format,
    String owner,
    CancellationToken token, {
    PublicationEdition? edition,
    String? pdfPassword,
    bool downloaded = false,
    void Function()? authorize,
    AcquisitionTask? task,
    Future<void> Function()? confirmSource,
    bool retainArchive = false,
  }) async {
    final snapshot = _policy;
    void check([String text = '']) {
      token.check();
      authorize?.call();
      requireImport(text);
      if (snapshot != _policy) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
    }

    check('${edition?.title ?? name} ${edition?.author ?? ''}');
    final bytes = await file.length();
    final digest = await publicationFileDigest(file, token);
    if (await detectPublicationFormat(file) != format) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    final admission = await admitPublication(
      file,
      format,
      name,
      token,
      authorize: check,
      password: pdfPassword,
    );
    final selected =
        edition ??
        PublicationEdition(
          id: publicationId('local:$digest'),
          title: admission.title,
          author: admission.author,
        );
    final book = publicationReaderBook(
      digest,
      format,
      selected.title,
      selected.author,
    );
    if (!bookAllowed(book) || await legacy.isPrivateBook(book.id)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await _publish(
      file,
      book,
      selected,
      digest,
      format,
      bytes,
      owner,
      downloaded,
      (snapshot, admission.hasText, admission.password),
      check,
      token: token,
      task: task,
      confirmSource: confirmSource,
      retainArchive: retainArchive,
    );
    return digest;
  }

  Future<void> _publish(
    File stage,
    Book book,
    PublicationEdition edition,
    String digest,
    PublicationFormat format,
    int bytes,
    String owner,
    bool downloaded,
    (String, bool, bool) admission,
    void Function() check, {
    required CancellationToken token,
    AcquisitionTask? task,
    Future<void> Function()? confirmSource,
    required bool retainArchive,
  }) async {
    final target = space.managedFile(digest, format);
    await target.parent.create(recursive: true);
    final stagedName = p.basename(stage.path);
    await store.db.write(
      'INSERT OR REPLACE INTO publication_imports VALUES(?,?,?,?)',
      [owner, digest, format.name, stagedName],
    );
    var moved = false;
    try {
      await store.db.atomic(
        () async {
          check();
          if (await legacy.isPrivateBook(book.id)) {
            throw const PublicationFailure(PublicationProblem.blocked);
          }
          var (placement, legacyId) = await _existingPlacement(
            book,
            format,
            digest,
            bytes,
            target,
          );
          if (placement == null) {
            if (await target.exists()) {
              throw const PublicationFailure(PublicationProblem.storage);
            }
            await stage.rename(target.path);
            moved = true;
            placement = 'managed';
          }
          await store.db.write(
            '''INSERT INTO publication_files(digest,format,bytes,placement,legacy_id,downloaded,admitted)
          VALUES(?,?,?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET
          bytes=excluded.bytes,placement=excluded.placement,legacy_id=excluded.legacy_id,
          downloaded=MAX(downloaded,excluded.downloaded),admitted=excluded.admitted''',
            [
              digest,
              format.name,
              bytes,
              placement,
              legacyId,
              downloaded ? 1 : 0,
              jsonEncode([admission.$1, admission.$2, admission.$3]),
            ],
          );
          await _hold(edition, digest);
          if (moved) await _commitSpace(owner, bytes);
          await store.db.write(
            'DELETE FROM publication_imports WHERE owner=?',
            [owner],
          );
          await confirmSource?.call();
          if (task != null) {
            await store.updateTask(
              task,
              AcquisitionState.complete,
              result: digest,
              retainedArchive: retainArchive,
            );
          }
          final admittedFile = moved ? target : stage;
          await _requireFileIdentity(admittedFile, bytes, digest, token);
          store.db.beforeCommit(check);
        },
        tables: {
          'publication_files',
          'publication_shelf',
          'publication_space',
          'publication_imports',
          if (task != null) 'publication_tasks',
        },
      );
    } catch (_) {
      if (moved && await target.exists() && !await stage.exists()) {
        await target.rename(stage.path);
      }
      await store.db.write('DELETE FROM publication_imports WHERE owner=?', [
        owner,
      ]);
      rethrow;
    }
  }

  Future<void> _commitSpace(String owner, int bytes) async {
    final reservation = (await store.db.rows(
      'SELECT used FROM publication_space WHERE owner=?',
      [owner],
    )).firstOrNull;
    final allocated = reservation?['used'] as int? ?? bytes;
    if (allocated < bytes) {
      throw const PublicationFailure(PublicationProblem.storage);
    }
    await space.release(owner, used: allocated - bytes);
  }

  Future<(String?, String?)> _existingPlacement(
    Book book,
    PublicationFormat format,
    String digest,
    int bytes,
    File target,
  ) async {
    final existing = (await store.db.rows(
      'SELECT placement,legacy_id FROM publication_files WHERE digest=?',
      [digest],
    )).firstOrNull;
    final placement = existing?['placement'] as String?;
    final legacyId = existing?['legacy_id'] as String?;
    if (placement == null) {
      final legacyPath = _legacyFile(book.id, format);
      if (await _hasLegacyOwner(book) &&
          await legacyPath.exists() &&
          await legacyPath.length() == bytes &&
          await publicationFileDigest(legacyPath, CancellationToken()) ==
              digest) {
        return ('legacy', book.id);
      }
      return (null, legacyId);
    }
    final legacyPlacement = placement == 'legacy' || placement == 'retained';
    final existingPath = legacyPlacement
        ? _legacyFile(legacyId ?? book.id, format)
        : target;
    if (!await existingPath.exists() || await existingPath.length() != bytes) {
      return (null, legacyId);
    }
    if (await publicationFileDigest(existingPath, CancellationToken()) !=
        digest) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return (placement, legacyPlacement ? legacyId ?? book.id : legacyId);
  }

  Future<void> _hold(
    PublicationEdition edition,
    String digest, {
    bool attached = false,
  }) => store.db.write(
    'INSERT INTO publication_shelf(id,edition,digest,added) VALUES(?,?,?,?) '
    'ON CONFLICT(id) DO UPDATE SET removed=0',
    [
      publicationId('${edition.id}:$digest'),
      attached ? null : jsonEncode(edition.toJson()..remove('candidates')),
      digest,
      publicationNow(),
    ],
  );

  Future<PublicationOpened> open(
    PublicationHolding holding,
    CancellationToken token, {
    String? password,
  }) async {
    final book = publicationReaderBook(
      holding.digest,
      holding.format,
      holding.edition.title,
      holding.edition.author,
    );
    if (!await _canOpen(book)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    final (fileState, file, lease) = await store.db.atomic(() async {
      final state = await _fileState(holding.digest);
      if (state == null || state['placement'] == null) {
        throw const PublicationFailure(PublicationProblem.missing);
      }
      final selected = _file(holding, state);
      return (state, selected, await space.lease(holding.digest, selected));
    }, tables: {'publication_leases'});
    final snapshot = _policy;
    bool allowed() =>
        snapshot == _policy &&
        bookAllowed(book) &&
        (!legacy.vault.isPrivate(book.id) || legacy.vault.unlocked);
    void check(String text) {
      token.check();
      if (!allowed() || !policy.textAllowed(text)) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
    }

    try {
      if (!await file.exists()) {
        await _markMissing(holding.digest, fileState, file);
        throw const PublicationFailure(PublicationProblem.missing);
      }
      await _requireFileIdentity(file, holding.bytes, holding.digest, token);
      final saved = fileState['admitted'] == null
          ? null
          : jsonDecode(fileState['admitted'] as String) as List;
      final cached =
          holding.format == PublicationFormat.pdf &&
          saved != null &&
          saved[0] == snapshot;
      final admission = await admitPublication(
        file,
        holding.format,
        '${book.title}.${holding.format.name}',
        token,
        authorize: check,
        password: password,
        scan: !cached,
      );
      final checked = (
        title: admission.title,
        author: admission.author,
        chapters: admission.chapters,
        hasText: cached ? saved[1] == true : admission.hasText,
        password: admission.password,
      );
      check(book.title);
      await store.db.write(
        'UPDATE publication_files SET last_read=?,admitted=? WHERE digest=?',
        [
          publicationNow(),
          jsonEncode([snapshot, checked.hasText, checked.password]),
          holding.digest,
        ],
      );
      check(book.title);
      return (
        book: book,
        file: file,
        admission: checked,
        lease: lease,
        allowed: allowed,
      );
    } catch (_) {
      await space.unlease(lease);
      rethrow;
    }
  }

  Future<void> _requireFileIdentity(
    File file,
    int bytes,
    String digest,
    CancellationToken token,
  ) async {
    if (await file.length() != bytes ||
        await publicationFileDigest(file, token) != digest) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
  }

  Future<bool> _canOpen(Book book) async =>
      bookAllowed(book) &&
      (!(await legacy.isPrivateBook(book.id)) || legacy.vault.unlocked);

  Future<Map<String, Object?>?> _fileState(String digest) async =>
      (await store.db.rows('SELECT * FROM publication_files WHERE digest=?', [
        digest,
      ])).firstOrNull;

  File _file(PublicationHolding entry, Map<String, Object?>? state) =>
      _usesLegacyCopy(state)
      ? _legacyFile(state!['legacy_id'] as String, entry.format)
      : space.managedFile(entry.digest, entry.format);

  File _legacyFile(String id, PublicationFormat format) =>
      File(p.join(legacyDocuments.path, '$id.${format.name}'));

  Future<void> remove(PublicationHolding entry) => store.db.write(
    'UPDATE publication_shelf SET removed=1 WHERE id=?',
    [entry.id],
  );
  Future<void> setKept(PublicationHolding entry, bool value) => store.db.write(
    'UPDATE publication_shelf SET kept=? WHERE id=?',
    [value ? 1 : 0, entry.id],
  );

  Future<void> deleteFile(
    PublicationHolding entry, {
    bool onlyUnlisted = false,
  }) async {
    final book = publicationReaderBook(
      entry.digest,
      entry.format,
      entry.edition.title,
      entry.edition.author,
    );
    await space.releases.release(
      () async {
        if (!await _canOpen(book)) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
        final state = await _fileState(entry.digest);
        final placement = state?['placement'];
        if (placement == null) return const [];
        final file = _file(entry, state);
        final others = await store.db.rows(
          'SELECT 1 FROM publication_shelf WHERE digest=? AND removed=0 '
          'AND (?=1 OR id<>?) LIMIT 1',
          [entry.digest, onlyUnlisted ? 1 : 0, entry.id],
        );
        if (others.isNotEmpty ||
            (onlyUnlisted &&
                placement != 'managed' &&
                placement != 'retained') ||
            await space.hasLease(entry.digest, file) ||
            (_usesLegacyCopy(state) && await _hasLegacyOwner(book)) ||
            await legacy.isPrivateBook(book.id)) {
          throw const PublicationFailure(PublicationProblem.inUse);
        }
        return [(digest: entry.digest, file: file)];
      },
      authorize: () {
        if (!bookAllowed(book)) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
      },
    );
  }

  Future<void> _markMissing(
    String digest,
    Map<String, Object?> state,
    File file,
  ) => store.db.atomic(() async {
    if (await file.exists()) return;
    await store.db.write(
      'UPDATE publication_files SET placement=NULL,admitted=NULL '
      "WHERE digest=? AND placement=? AND (placement='managed' OR legacy_id IS ?)",
      [digest, state['placement'], state['legacy_id']],
    );
  }, tables: {'publication_files'});

  Future<void> reconcile() async {
    await store.initialize();
    await space.releases.recover();
    for (final row in await store.db.rows(
      'SELECT digest,format FROM publication_legacy_releases',
    )) {
      await _finishLegacyRelease(
        row['digest'] as String,
        PublicationFormat.values.byName(row['format'] as String),
      );
    }
    for (final row in await store.db.rows(
      'SELECT * FROM publication_imports',
    )) {
      final id = row['owner'] as String;
      final digest = row['digest'] as String;
      final format = PublicationFormat.values.byName(row['format'] as String);
      final stagedName = row['staged_name'] as String;
      if (!const {
        'download.part',
        'book.pdf',
        'book.epub',
      }.contains(stagedName)) {
        continue;
      }
      final stage = File(p.join(space.taskDirectory(id).path, stagedName));
      final target = space.managedFile(digest, format);
      final recorded = await _fileState(digest);
      if (!await stage.exists() &&
          await target.exists() &&
          recorded?['placement'] != 'managed') {
        await stage.parent.create(recursive: true);
        await target.rename(stage.path);
      }
      await store.db.write('DELETE FROM publication_imports WHERE owner=?', [
        id,
      ]);
    }
    for (final row in await store.db.rows(
      'SELECT digest FROM publication_files WHERE placement IS NOT NULL OR legacy_id IS NOT NULL',
    )) {
      await _reconcileCopy(row['digest'] as String);
    }
  }

  Future<void> _reconcileCopy(String digest) => store.db.atomic(() async {
    final row = await _fileState(digest);
    if (row == null) return;
    final format = PublicationFormat.values.byName(row['format'] as String);
    final legacyId = row['legacy_id'] as String?;
    if (row['placement'] != null) {
      final file = _usesLegacyCopy(row)
          ? _legacyFile(legacyId!, format)
          : space.managedFile(digest, format);
      await space.releases.restoreUncommitted(digest, file);
      if (!await file.exists()) await _markMissing(digest, row, file);
    }
    if (legacyId == null || row['placement'] == 'retained') return;
    final book = publicationReaderBook(digest, format, '', '');
    if (legacyId == book.id &&
        !await _legacyFile(legacyId, format).exists() &&
        !await _hasLegacyOwner(book) &&
        !await legacy.isPrivateBook(book.id)) {
      await store.db.write(
        'UPDATE publication_files SET legacy_id=NULL WHERE digest=?',
        [digest],
      );
    }
  }, tables: {'publication_files'});
}

PublicationEdition _legacyEdition(Book book) => PublicationEdition(
  id: publicationId('legacy:${book.id}'),
  title: book.title,
  author: book.author,
);
