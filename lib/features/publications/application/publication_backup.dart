import 'dart:convert';
import 'dart:io';

import '../../books/data/reading_marks_store.dart';
import '../../books/domain/book.dart';
import '../../books/domain/reading_mark.dart';
import '../../books/domain/rich_document_access.dart';
import '../data/publication_documents.dart';
import '../data/publication_http.dart';
import '../data/publication_reading.dart';
import '../data/publication_store.dart';
import '../domain/publication.dart';
import 'publication_library.dart';

typedef _BackupHolding = ({
  String id,
  PublicationEdition edition,
  String digest,
  PublicationFormat format,
  int bytes,
  bool kept,
  int added,
});

final class PublicationBackup {
  PublicationBackup(this.library, this.reading);
  final PublicationLibrary library;
  final PublicationReading reading;
  PublicationStore get store => library.store;
  static const maxBytes = 8 << 20;

  Future<String> encode() async {
    library.requireImport('');
    final entries = <Map<String, Object?>>[];
    final positions = <String, Map<String, Object?>>{};
    final notes = <String, List<Map<String, Object?>>>{};
    final marks = <String, List<Map<String, Object?>>>{};
    for (final item in await library.holdings()) {
      final book = publicationReaderBook(
        item.digest,
        item.format,
        item.edition.title,
        item.edition.author,
      );
      if (await library.legacy.isPrivateBook(book.id)) continue;
      bool allowed() =>
          !library.policy.supervision.enabled &&
          !library.policy.supervision.corrupted &&
          library.bookAllowed(book) &&
          !library.legacy.vault.isPrivate(book.id);
      if (!allowed()) continue;
      if (await reading.position(book, allowed) case final position?) {
        positions[item.digest] = encodeRichPosition(position);
      }
      final items = await reading.notes(book, null, allowed);
      notes[item.digest] = [
        for (final note in items)
          {
            'id': note.id.startsWith('legacy:')
                ? publicationId('${item.digest}:${note.id}')
                : note.id,
            'section': note.index,
            'fraction': note.fraction,
            'excerpt': note.excerpt,
            'text': note.text,
          },
      ];
      final annotations = await ReadingMarksStore(
        library.legacy,
        book,
        allowed,
      ).load(digest: item.digest);
      if (annotations.isNotEmpty) {
        marks[item.digest] = [for (final mark in annotations) mark.toJson()];
      }
      if (!allowed()) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      entries.add({
        'id': item.id,
        'edition': item.edition.toJson()..remove('candidates'),
        'bytes': item.bytes,
        'digest': item.digest,
        'format': item.format.name,
        'kept': item.kept,
        'added': item.added,
      });
    }
    final data = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'holdings': entries,
      'positions': positions,
      'notes': notes,
      if (marks.isNotEmpty) 'marks': marks,
    });
    if (utf8.encode(data).length > maxBytes) {
      throw const FormatException('图书元数据备份超过 8 MiB');
    }
    return data;
  }

  Future<int> restore(File file) async {
    library.requireImport('');
    final size = await file.length();
    if (size > maxBytes) throw const FormatException('图书备份超过 8 MiB');
    final data = jsonDecode(
      await utf8.decoder.bind(file.openRead(0, size)).join(),
    );
    if (data is! Map ||
        data['version'] != 1 ||
        data['holdings'] is! List ||
        data['positions'] is! Map ||
        data['notes'] is! Map ||
        (data['marks'] != null && data['marks'] is! Map) ||
        (data['holdings'] as List).length > 5000) {
      throw const FormatException('图书备份结构或版本无效');
    }
    final entries = [for (final row in data['holdings'] as List) _entry(row)];
    final digests = {
      for (final entry in entries) entry.digest: (entry.format, entry.bytes),
    };
    if (entries.map((entry) => entry.id).toSet().length != entries.length ||
        entries.any(
          (entry) => digests[entry.digest] != (entry.format, entry.bytes),
        )) {
      throw const FormatException('备份包含冲突的图书记录');
    }
    final positions = <String, RichDocumentPosition>{};
    final notes = <String, List<List<Object?>>>{};
    for (final MapEntry(:key, :value) in (data['positions'] as Map).entries) {
      if (!digests.containsKey(key) || value is! Map) {
        throw const FormatException('备份进度引用无效');
      }
      positions[key as String] = decodeRichPosition(value);
    }
    for (final MapEntry(:key, :value) in (data['notes'] as Map).entries) {
      if (!digests.containsKey(key) || value is! List || value.length > 1000) {
        throw const FormatException('备份笔记引用无效');
      }
      notes[key as String] = [for (final note in value) _note(note, key)];
    }
    final marks = <String, List<ReadingMark>>{};
    for (final MapEntry(:key, :value)
        in ((data['marks'] as Map?) ?? {}).entries) {
      if (key is! String || !digests.containsKey(key)) {
        throw const FormatException('备份标注引用无效');
      }
      marks[key] = ReadingMark.decode(value, digest: key);
    }
    await store.initialize();
    return store.db.atomic(
      () async {
        final restored = <String, Book>{};
        var count = 0;
        for (final entry in entries) {
          final book = publicationReaderBook(
            entry.digest,
            entry.format,
            entry.edition.title,
            entry.edition.author,
          );
          library.requireImport('${book.title} ${book.author}');
          if (!library.bookAllowed(book) ||
              await library.legacy.isPrivateBook(book.id)) {
            continue;
          }
          await _restoreEntry(entry);
          restored[entry.digest] = book;
          count++;
        }
        for (final MapEntry(key: digest, value: book) in restored.entries) {
          if (positions[digest] case final position?) {
            await store.db.write(
              'INSERT OR IGNORE INTO publication_positions VALUES(?,?,?)',
              [
                digest,
                jsonEncode(encodeRichPosition(position)),
                publicationNow(),
              ],
            );
          }
          for (final note in notes[digest] ?? const []) {
            await _restoreNote(note);
          }
          if (marks[digest] case final annotations?) {
            await ReadingMarksStore(
              library.legacy,
              book,
              () =>
                  !library.policy.supervision.enabled &&
                  !library.policy.supervision.corrupted &&
                  library.bookAllowed(book) &&
                  !library.legacy.vault.isPrivate(book.id),
            ).merge(annotations);
          }
        }
        store.db.beforeCommit(() => library.requireImport(''));
        return count;
      },
      tables: {
        'publication_files',
        'publication_shelf',
        'publication_positions',
        'publication_notes',
      },
    );
  }

  Future<void> _restoreEntry(_BackupHolding entry) async {
    final existing = (await store.db.rows(
      'SELECT bytes,format FROM publication_files WHERE digest=?',
      [entry.digest],
    )).firstOrNull;
    if (existing != null &&
        (existing['bytes'] != entry.bytes ||
            existing['format'] != entry.format.name)) {
      throw const FormatException('备份文件的摘要与本地图书记录冲突');
    }
    await store.db.write(
      'INSERT OR IGNORE INTO publication_files(digest,bytes,format) VALUES(?,?,?)',
      [entry.digest, entry.bytes, entry.format.name],
    );
    await store.db.write(
      'INSERT INTO publication_shelf(id,edition,digest,kept,added) VALUES(?,?,?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET removed=0,kept=MAX(kept,excluded.kept)',
      [
        entry.id,
        jsonEncode(entry.edition.toJson()..remove('candidates')),
        entry.digest,
        entry.kept ? 1 : 0,
        entry.added,
      ],
    );
  }

  Future<void> _restoreNote(List<Object?> note) async {
    final current = (await store.db.rows(
      'SELECT * FROM publication_notes WHERE id=?',
      [note[0]],
    )).firstOrNull;
    if (current != null &&
        current['digest'] == note[1] &&
        current['section'] == note[2] &&
        current['fraction'] == note[3] &&
        current['excerpt'] == note[4] &&
        current['text'] == note[5]) {
      return;
    }
    await store.db.write(
      'INSERT OR IGNORE INTO publication_notes VALUES(?,?,?,?,?,?,?)',
      [
        current == null
            ? note[0]
            : publicationId(jsonEncode(note.take(6).toList())),
        ...note.skip(1),
      ],
    );
  }

  _BackupHolding _entry(Object? row) {
    if (row is! Map ||
        row['edition'] is! Map ||
        row['id'] is! String ||
        row['digest'] is! String ||
        row['bytes'] is! int ||
        row['added'] is! int) {
      throw const FormatException('备份条目无效');
    }
    final values = row['edition'] as Map;
    final format = PublicationFormat.values.byName(row['format'] as String);
    final digest = row['digest'] as String;
    final id = row['id'] as String;
    final edition = PublicationEdition.fromJson({
      ...values,
      'candidates': const [],
    });
    final bytes = row['bytes'] as int;
    if (!isPublicationDigest(digest) ||
        !isPublicationDigest(edition.id) ||
        id != publicationId('${edition.id}:$digest') ||
        bytes <= 0 ||
        bytes > format.maxBytes ||
        format == PublicationFormat.zip ||
        edition.title.isEmpty ||
        edition.title.length > 300 ||
        edition.author.length > 300 ||
        edition.tags.length > 32 ||
        values.values.whereType<String>().any((value) => value.length > 2048)) {
      throw const FormatException('备份文件信息或书目无效');
    }
    if (edition.page case final page?) {
      validatePublicationAddress(page);
      if (page.hasQuery || page.hasFragment) {
        throw const FormatException('备份来源地址无效');
      }
    }
    return (
      id: id,
      edition: edition,
      digest: digest,
      format: format,
      bytes: bytes,
      kept: row['kept'] == true,
      added: row['added'] as int,
    );
  }

  List<Object?> _note(Object? note, String digest) {
    if (note is! Map ||
        note['id'] is! String ||
        !isPublicationDigest(note['id'] as String) ||
        note['section'] is! int ||
        (note['section'] as int) < 0 ||
        (note['section'] as int) >= 4000 ||
        note['fraction'] is! num ||
        note['excerpt'] is! String ||
        note['text'] is! String ||
        (note['excerpt'] as String).length > 1200 ||
        (note['text'] as String).length > 4000) {
      throw const FormatException('备份笔记内容无效');
    }
    return [
      note['id'],
      digest,
      note['section'],
      (note['fraction'] as num).toDouble().clamp(0, 1),
      note['excerpt'],
      note['text'],
      publicationNow(),
    ];
  }
}
