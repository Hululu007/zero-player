import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/reading_marks_store.dart';
import 'package:zero_player/features/books/domain/reading_mark.dart';
import 'package:zero_player/features/books/presentation/epub_source.dart';
import 'package:zero_player/features/books/data/rich_book.dart';
import 'package:zero_player/features/publications/data/publication_documents.dart';
import 'package:zero_player/features/publications/data/publication_schema.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';

late AppServices services;
late File sample;
late File database;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    final root = await Directory.systemTemp.createTemp('publication-copies-');
    database = File('${root.path}/books.sqlite');
    services = AppServices.scoped(root, AppDatabase(database));
    addTearDown(() async {
      await services.close();
      await root.delete(recursive: true);
    });
    final archive = Archive()
      ..addFile(
        ArchiveFile.string('mimetype', 'application/epub+zip')
          ..compression = CompressionType.none,
      );
    for (final entry in ZipDecoder().decodeBytes(sampleEpub())) {
      archive.addFile(entry);
    }
    sample = await File(
      '${root.path}/sample.epub',
    ).writeAsBytes(ZipEncoder().encode(archive));
  });

  _independentCopies();
  _readerLeases();
  _shelfOwnership();
  _removedCopies();
  _removedCopyProtection();
  _importIdentity();
  _recovery();
}

void _independentCopies() {
  test(
    'removing an independent legacy copy preserves active reading',
    () async {
      final module = services.publications;
      final digest = await module.workflow.importLocal(sample);
      final books = services.books;
      final legacy = await books.importLocal(sample);
      await module.library.attachLegacy(legacy);
      final chapter = (await books.store.entry(legacy))!.chapters.single;
      await books.store.saveRichPosition(
        legacy,
        chapter,
        index: 0,
        horizontal: false,
        verticalPage: 0,
        offset: 12,
        fraction: .62,
      );
      await books.store.addAnnotation(legacy, {
        'id': 'reading-note',
        'chapter': chapter.id,
        'position': .62,
        'quote': '中文正文',
        'note': '保留笔记',
      });
      final copy = module.space.managedFile(digest, PublicationFormat.epub);
      final holding = (await module.library.holdings()).first;
      final opened = await module.library.open(holding, CancellationToken());
      addTearDown(() => module.space.unlease(opened.lease));
      expect(opened.file.path, copy.path);
      final access = module.reading.access(
        opened.book,
        [chapter],
        opened.allowed,
        true,
        null,
      );
      final oldNote = (await access.loadNotes()).single;

      await books.removeLocalBook(legacy);

      expect(await books.store.entry(legacy), isNull);
      expect(await books.documentFile(legacy, 'epub').exists(), isFalse);
      expect(await copy.readAsBytes(), await sample.readAsBytes());
      final position = await module.reading.position(
        opened.book,
        opened.allowed,
      );
      expect(position?.fraction, .62);
      expect(position?.offset, 12);
      expect((await access.loadNotes()).single.text, '保留笔记');
      await access.deleteNote(oldNote.id);
      expect(await access.loadNotes(), isEmpty);
    },
  );

  test('removing the last legacy owner clears its managed-file link', () async {
    final module = services.publications;
    final digest = await module.workflow.importLocal(sample);
    final books = services.books;
    final legacy = await books.importLocal(sample);
    await module.library.attachLegacy(legacy);
    for (final holding in await module.library.holdings()) {
      await module.library.remove(holding);
    }

    await books.removeLocalBook(legacy);

    expect(await books.documentFile(legacy, 'epub').exists(), isFalse);
    expect(
      (await services.db.rows(
        'SELECT placement,legacy_id FROM publication_files WHERE digest=?',
        [digest],
      )).single,
      {'placement': 'managed', 'legacy_id': null},
    );
  });
}

void _readerLeases() {
  test('removing a shared legacy copy waits for its reader lease', () async {
    final module = services.publications;
    final books = services.books;
    final legacy = await books.importLocal(sample);
    final copy = books.documentFile(legacy, 'epub');
    await module.library.attachLegacy(legacy);
    final holding = (await module.library.holdings()).single;
    final opened = await module.library.open(holding, CancellationToken());
    try {
      expect(opened.file.path, copy.path);
      await expectLater(
        books.removeLocalBook(legacy),
        throwsA(
          isA<PublicationFailure>().having(
            (failure) => failure.problem,
            'problem',
            PublicationProblem.inUse,
          ),
        ),
      );
      expect(await books.store.entry(legacy), isNotNull);
    } finally {
      await module.space.unlease(opened.lease);
    }

    await books.removeLocalBook(legacy);

    expect(await books.store.entry(legacy), isNull);
    final reopened = await module.library.open(
      (await module.library.holdings()).single,
      CancellationToken(),
    );
    try {
      expect(reopened.file.path, copy.path);
      expect(await reopened.file.readAsBytes(), await sample.readAsBytes());
    } finally {
      await module.space.unlease(reopened.lease);
    }
  });

  test('legacy sessions lease a file before it joins the library', () async {
    final books = services.books;
    final legacy = await books.importLocal(sample);
    final file = books.documentFile(legacy, 'epub');
    final release = (await books.localBooks.holdDocument!(legacy, file))!;
    try {
      await expectLater(books.removeLocalBook(legacy), throwsA(_inUse));
      expect(await file.readAsBytes(), await sample.readAsBytes());
    } finally {
      await release();
    }
    await books.removeLocalBook(legacy);
    expect(await file.exists(), isFalse);
  });

  test('an independent legacy reader does not pin the managed copy', () async {
    final module = services.publications;
    final digest = await module.workflow.importLocal(sample);
    final books = services.books;
    final legacy = await books.importLocal(sample);
    final file = books.documentFile(legacy, 'epub');
    final release = (await books.localBooks.holdDocument!(legacy, file))!;
    try {
      final holding = (await module.library.holdings()).single;
      await module.library.deleteFile(holding);
      expect((await module.library.holdings()).single.resident, isFalse);
      expect(
        await module.space.managedFile(digest, PublicationFormat.epub).exists(),
        isFalse,
      );
      expect(await file.readAsBytes(), await sample.readAsBytes());
      expect(await books.store.entry(legacy), isNotNull);
    } finally {
      await release();
    }
  });
}

void _shelfOwnership() {
  test(
    'a shared copy retained by the detached legacy shelf cannot be deleted',
    () async {
      final module = services.publications;
      final books = services.books;
      final legacy = await books.importLocal(sample);
      await module.library.attachLegacy(legacy);
      await books.localBooks.removeLocalBook(
        legacy,
        removeRecord: () =>
            books.store.removeFromShelf(legacy, clearOffline: false),
        clearOffline: false,
      );
      expect(await books.store.entry(legacy), isNull);
      expect(await books.store.detachedEntry(legacy), isNotNull);
      final holding = (await module.library.holdings()).single;
      await expectLater(module.library.deleteFile(holding), throwsA(_inUse));
      final file = books.documentFile(legacy, 'epub');
      expect(await file.readAsBytes(), await sample.readAsBytes());
      await books.removeLocalBook(legacy);
      expect(await books.store.detachedEntry(legacy), isNull);
      expect(await file.readAsBytes(), await sample.readAsBytes());
      await module.library.deleteFile(holding);
      expect(await file.exists(), isFalse);
    },
  );

  test('a failed outer commit keeps both copies and all owners', () async {
    final module = services.publications;
    final digest = await module.workflow.importLocal(sample);
    final books = services.books;
    final legacy = await books.importLocal(sample);
    await module.library.attachLegacy(legacy);
    await expectLater(
      services.db.atomic(() async {
        await books.removeLocalBook(legacy);
        services.db.beforeCommit(() => throw const FormatException('fixture'));
      }),
      throwsFormatException,
    );
    expect(await books.store.entry(legacy), isNotNull);
    expect(
      await books.documentFile(legacy, 'epub').readAsBytes(),
      await sample.readAsBytes(),
    );
    expect(
      await module.space
          .managedFile(digest, PublicationFormat.epub)
          .readAsBytes(),
      await sample.readAsBytes(),
    );
    expect(
      await services.db.rows('SELECT * FROM publication_legacy_releases'),
      isEmpty,
    );
    expect((await module.library.holdings()).length, 2);
  });
}

void _removedCopies() {
  test(
    'only copies with no shelf references appear, once per digest',
    () async {
      final module = services.publications;
      final digest = await module.workflow.importLocal(sample);
      final books = services.books;
      final legacy = await books.importLocal(sample);
      await module.library.attachLegacy(legacy);
      final holdings = await module.library.holdings();
      expect(holdings, hasLength(2));

      await module.library.remove(holdings.first);
      expect(await module.library.unlistedCopies(), isEmpty);
      await module.library.remove(holdings.last);
      final copy = (await module.library.unlistedCopies()).single;
      expect(copy.digest, digest);
      expect(copy.bytes, await sample.length());
      await module.library.deleteFile(copy, onlyUnlisted: true);

      expect(await module.library.unlistedCopies(), isEmpty);
      expect((await module.space.usage()).used, 0);
      expect(
        await books.documentFile(legacy, 'epub').readAsBytes(),
        await sample.readAsBytes(),
      );
    },
  );
}

void _removedCopyProtection() {
  test(
    'publication backup restores an EPUB mark and its linked bookmark',
    () async {
      final module = services.publications;
      final digest = await module.workflow.importLocal(sample);
      final book = publicationReaderBook(
        digest,
        PublicationFormat.epub,
        '',
        '',
      );
      final section = readRichEpub(await sample.readAsBytes()).single;
      final source = EpubSource(section.html).text;
      const quote = '中文正文';
      final start = source.indexOf(quote);
      final mark = ReadingMark(
        digest: digest,
        section: 0,
        range: (start: start, end: start + quote.length),
        quote: quote,
        style: ReadingMarkStyle.outline,
        color: 4,
        bookmark: true,
      );
      final store = ReadingMarksStore(services.books.store, book, () => true);
      await store.save(mark);
      final json = await module.output.backup.encode();
      final path = File('${sample.parent.path}/marked-library.json');
      await path.writeAsString(json);
      await store.delete(mark);
      expect(await store.load(), isEmpty);
      expect(await module.output.backup.restore(path), 1);
      final restored = (await store.load(digest: digest)).single;
      expect(restored.toJson(), mark.toJson());
      expect(restored.matches(source), isTrue);
    },
  );

  test('the last alias can be removed and its reading data restored', () async {
    final module = services.publications;
    final digest = await module.workflow.importLocal(sample);
    final holding = (await module.library.holdings()).single;
    final opened = await module.library.open(holding, CancellationToken());
    final access = module.reading.access(
      opened.book,
      publicationReaderChapters(opened.book, opened.admission.chapters),
      opened.allowed,
      true,
      null,
    );
    const position = (
      index: 0,
      horizontal: false,
      verticalPage: 0,
      sourceOffset: null,
      offset: 10.0,
      fraction: .42,
    );
    try {
      await access.savePosition(position);
      await access.addNote(0, .42, '中文正文', '保留摘录');
      await module.library.remove(holding);
      final selected = (await module.library.unlistedCopies()).single;
      await expectLater(
        module.library.deleteFile(selected, onlyUnlisted: true),
        throwsA(_inUse),
      );
      expect(await opened.file.exists(), isTrue);
    } finally {
      await module.space.unlease(opened.lease);
    }

    final selected = (await module.library.unlistedCopies()).single;
    await module.workflow.importLocal(sample);
    await expectLater(
      module.library.deleteFile(selected, onlyUnlisted: true),
      throwsA(_inUse),
    );
    expect(await opened.file.exists(), isTrue);
    await module.library.remove((await module.library.holdings()).single);
    await module.library.deleteFile(
      (await module.library.unlistedCopies()).single,
      onlyUnlisted: true,
    );
    expect(await opened.file.exists(), isFalse);
    expect(await module.workflow.importLocal(sample), digest);
    expect(await access.loadPosition(), position);
    expect((await access.loadNotes()).single.text, '保留摘录');
  });

  test(
    'removing a shared association leaves the original in the old library',
    () async {
      final module = services.publications;
      final books = services.books;
      final legacy = await books.importLocal(sample);
      await module.library.attachLegacy(legacy);
      final holding = (await module.library.holdings()).single;
      await module.library.remove(holding);
      expect(await module.library.unlistedCopies(), isEmpty);
      await expectLater(
        module.library.deleteFile(holding, onlyUnlisted: true),
        throwsA(_inUse),
      );
      expect(
        await books.documentFile(legacy, 'epub').readAsBytes(),
        await sample.readAsBytes(),
      );
      expect(await books.store.entry(legacy), isNotNull);
    },
  );
}

void _importIdentity() {
  test('a changed import cannot publish its previous admission', () async {
    final module = services.publications;
    await module.workflow.initialize();
    final owner = publicationId('import whose bytes changed');
    final stage = module.workflow.transfer.part(owner);
    final original = await sample.readAsBytes();
    final changed = [...original];
    changed[changed.length - 1] ^= 1;
    final digest = await publicationFileDigest(sample, CancellationToken());
    final target = module.space.managedFile(digest, PublicationFormat.epub);
    await stage.parent.create(recursive: true);
    await module.space.reserve(owner, original.length);
    await stage.writeAsBytes(original, flush: true);
    await module.space.checkpoint(owner, original.length);

    Future<String> publish({Future<void> Function()? confirmSource}) =>
        module.library.importStaged(
          stage,
          'Reference.epub',
          PublicationFormat.epub,
          owner,
          CancellationToken(),
          confirmSource: confirmSource,
        );

    await expectLater(
      publish(
        confirmSource: () async {
          await target.writeAsBytes(changed, flush: true);
        },
      ),
      throwsA(_invalid),
    );
    expect(await module.library.holdings(), isEmpty);
    expect(await target.exists(), isFalse);
    expect(await stage.readAsBytes(), changed);
    expect(await sample.readAsBytes(), original);
    expect(
      await services.db.rows('SELECT * FROM publication_imports'),
      isEmpty,
    );
    expect((await module.space.usage()).used, original.length);

    await stage.writeAsBytes(original, flush: true);
    expect(await publish(), digest);
    expect(await target.readAsBytes(), original);

    final holding = (await module.library.holdings()).single;
    await target.writeAsBytes(changed, flush: true);
    await expectLater(
      module.library.open(holding, CancellationToken()),
      throwsA(_invalid),
    );
    expect(await module.space.hasLease(digest, target), isFalse);
  });
}

void _recovery() {
  test('opening a previous database recovers only ownerless copies', () async {
    final module = services.publications;
    final digest = await module.workflow.importLocal(sample);
    final books = services.books;
    final orphan = await books.importLocal(sample);
    await module.library.attachLegacy(orphan);
    final otherSample = await File(
      '${sample.parent.path}/other.epub',
    ).writeAsBytes(sampleEpub(paragraphs: 2));
    final owner = await books.importLocal(otherSample);
    final orphanFile = books.documentFile(orphan, 'epub');
    final ownedFile = books.documentFile(owner, 'epub');
    final managed = module.space.managedFile(digest, PublicationFormat.epub);
    await services.db.atomic(() async {
      await books.store.deleteBook(orphan, clearOffline: true);
      for (final id in [orphan.uri.path, owner.uri.path]) {
        await services.db.write(
          'INSERT INTO publication_legacy_releases VALUES(?,?)',
          [id, 'epub'],
        );
      }
    });
    await services.close();
    services = AppServices.scoped(sample.parent, AppDatabase(database));
    await services.publications.workflow.initialize();
    expect(await orphanFile.exists(), isFalse);
    expect(await ownedFile.readAsBytes(), await otherSample.readAsBytes());
    expect(await managed.readAsBytes(), await sample.readAsBytes());
    expect(
      await services.db.rows('SELECT * FROM publication_legacy_releases'),
      isEmpty,
    );
    expect(
      (await services.db.rows(
        'SELECT legacy_id FROM publication_files WHERE digest=?',
        [digest],
      )).single['legacy_id'],
      isNull,
    );
  });

  test(
    'the previous lease schema migrates without dropping its protection',
    () async {
      final legacy = await services.books.importLocal(sample);
      final digest = legacy.uri.path;
      await services.db.customStatement(publicationSchema.first);
      await services.db.customStatement('''CREATE TABLE publication_leases(
      id TEXT PRIMARY KEY, digest TEXT NOT NULL REFERENCES publication_files(digest),
      process INTEGER NOT NULL)''');
      await services.db.write(
        'INSERT INTO publication_files(digest,format,bytes,placement,legacy_id) VALUES(?,?,?,?,?)',
        [digest, 'epub', await sample.length(), 'legacy', legacy.id],
      );
      await services.db.write('INSERT INTO publication_leases VALUES(?,?,?)', [
        'previous',
        digest,
        pid,
      ]);

      final module = services.publications;
      await module.store.initialize();
      await expectLater(
        services.books.removeLocalBook(legacy),
        throwsA(_inUse),
      );
      await module.space.unlease('previous');
      await services.books.removeLocalBook(legacy);
      expect(
        await services.books.documentFile(legacy, 'epub').exists(),
        isFalse,
      );
    },
  );
}

final _inUse = isA<PublicationFailure>().having(
  (failure) => failure.problem,
  'problem',
  PublicationProblem.inUse,
);

final _invalid = isA<PublicationFailure>().having(
  (failure) => failure.problem,
  'problem',
  PublicationProblem.invalid,
);
