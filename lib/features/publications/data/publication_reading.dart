import 'dart:convert';

import '../../books/data/book_store.dart';
import '../../books/domain/book.dart';
import '../../books/domain/rich_document_access.dart';
import '../domain/publication.dart';
import 'publication_store.dart';

final class PublicationReading {
  PublicationReading(this.store, this.legacy);
  final PublicationStore store;
  final BookStore legacy;

  RichDocumentAccess access(
    Book book,
    List<BookChapter> chapters,
    bool Function() allowed,
    bool searchable,
    String? password,
  ) => RichDocumentAccess(
    chapters: chapters,
    isAllowed: allowed,
    searchable: searchable,
    password: password,
    loadPosition: () => position(book, allowed),
    savePosition: (value) => _save(book, chapters, value, allowed),
    loadNotes: () => notes(book, chapters, allowed),
    addNote: (index, fraction, excerpt, text) =>
        _add(book, chapters, index, fraction, excerpt, text, allowed),
    deleteNote: (id) => _delete(book, id, allowed),
  );

  Future<RichDocumentPosition?> position(
    Book book,
    bool Function() allowed,
  ) async {
    _require(allowed);
    final oldPosition = await legacyPublicationPosition(legacy, book);
    _require(allowed);
    if (oldPosition != null) return oldPosition;
    final row = (await store.db.rows(
      'SELECT data FROM publication_positions WHERE digest=?',
      [book.uri.path],
    )).firstOrNull;
    _require(allowed);
    return row == null
        ? null
        : decodeRichPosition(jsonDecode(row['data'] as String) as Map);
  }

  Future<void> _save(
    Book book,
    List<BookChapter> chapters,
    RichDocumentPosition position,
    bool Function() allowed,
  ) async {
    _require(allowed);
    await store.db.atomic(() async {
      final entry = await legacy.entry(book);
      _require(allowed);
      store.db.beforeCommit(() => _require(allowed));
      if (entry != null) {
        if (position.index >= entry.chapters.length) return;
        await legacy.saveRichPosition(
          book,
          entry.chapters[position.index],
          index: position.index,
          horizontal: position.horizontal,
          verticalPage: position.verticalPage,
          sourceOffset: position.sourceOffset,
          offset: position.offset,
          fraction: position.fraction,
        );
      } else {
        if (await legacy.isPrivateBook(book.id) ||
            position.index >= chapters.length) {
          return;
        }
        await store.db.write(
          'INSERT OR REPLACE INTO publication_positions VALUES(?,?,?)',
          [
            book.uri.path,
            jsonEncode(encodeRichPosition(position)),
            publicationNow(),
          ],
        );
      }
      await store.db.write(
        'UPDATE publication_files SET last_read=? WHERE digest=?',
        [publicationNow(), book.uri.path],
      );
    }, tables: {'app_meta', 'publication_positions', 'publication_files'});
  }

  Future<List<RichDocumentNote>> notes(
    Book book,
    List<BookChapter>? chapters,
    bool Function() allowed,
  ) async {
    _require(allowed);
    final existing =
        await legacy.entry(book) ?? await legacy.detachedEntry(book);
    final copied = existing == null
        ? const <Map>[]
        : await legacy.annotations(book);
    final locations = chapters ?? existing?.chapters ?? [];
    final private = await legacy.isPrivateBook(book.id);
    final persisted = private
        ? const <Map<String, Object?>>[]
        : await store.db.rows(
            'SELECT * FROM publication_notes WHERE digest=? ORDER BY created DESC',
            [book.uri.path],
          );
    _require(allowed);
    final oldNotes = <RichDocumentNote>[
      for (final raw in copied)
        if (raw['id'] is String)
          if (locations.indexWhere((chapter) => chapter.id == raw['chapter'])
              case final int index when index >= 0)
            (
              id: 'legacy:${raw['id']}',
              index: index,
              fraction: ((raw['position'] as num?) ?? 0).toDouble().clamp(0, 1),
              excerpt: publicationLabel(raw['quote'], max: 1200),
              text: publicationLabel(raw['note'], max: 4000),
            ),
    ];
    final duplicated = {
      for (final note in oldNotes)
        publicationId('${book.uri.path}:${note.id.substring(7)}'),
    };
    return [
      for (final note in persisted)
        if (!duplicated.contains(note['id']))
          (
            id: note['id'] as String,
            index: note['section'] as int,
            fraction: note['fraction'] as double,
            excerpt: note['excerpt'] as String,
            text: note['text'] as String,
          ),
      ...oldNotes,
    ];
  }

  Future<void> _add(
    Book book,
    List<BookChapter> chapters,
    int index,
    double fraction,
    String excerpt,
    String text,
    bool Function() allowed,
  ) async {
    _require(allowed);
    if (index < 0 || index >= chapters.length) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    await store.db.atomic(() async {
      _require(allowed);
      final existing = await legacy.entry(book);
      final quote = publicationLabel(excerpt, max: 1200);
      final note = publicationLabel(text, max: 4000);
      final id = newPublicationId();
      store.db.beforeCommit(() => _require(allowed));
      if (existing != null && index < existing.chapters.length) {
        final chapter = existing.chapters[index];
        await legacy.addAnnotation(book, {
          'id': id,
          'chapter': chapter.id,
          'title': chapter.title,
          'position': fraction,
          'quote': quote,
          'note': note,
        });
        return;
      }
      if (await legacy.isPrivateBook(book.id)) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      final total =
          (await store.db.rows(
                'SELECT COUNT(*) AS n FROM publication_notes WHERE digest=?',
                [book.uri.path],
              )).single['n']
              as int;
      if (total >= 1000) throw const FormatException('每本书最多保存 1000 条记录');
      await store.db.write(
        'INSERT INTO publication_notes VALUES(?,?,?,?,?,?,?)',
        [
          id,
          book.uri.path,
          index,
          fraction.clamp(0, 1),
          quote,
          note,
          publicationNow(),
        ],
      );
    }, tables: {'app_meta', 'publication_notes'});
  }

  Future<void> _delete(Book book, String id, bool Function() allowed) async {
    _require(allowed);
    await store.db.atomic(() async {
      store.db.beforeCommit(() => _require(allowed));
      if (id.startsWith('legacy:')) {
        await legacy.deleteAnnotation(book, id.substring(7));
        if (await legacy.isPrivateBook(book.id)) return;
      }
      final savedId = id.startsWith('legacy:')
          ? publicationId('${book.uri.path}:${id.substring(7)}')
          : id;
      await store.db.write(
        'DELETE FROM publication_notes WHERE id=? AND digest=?',
        [savedId, book.uri.path],
      );
    }, tables: {'app_meta', 'publication_notes'});
  }

  void _require(bool Function() allowed) {
    if (!allowed()) throw const PublicationFailure(PublicationProblem.blocked);
  }
}

Future<RichDocumentPosition?> legacyPublicationPosition(
  BookStore store,
  Book book,
) async {
  final entry = await store.entry(book);
  if (entry == null) return null;
  final raw = await store.readBookValue(book, 'rich_position_${book.id}');
  if (raw is Map) {
    return decodeRichPosition({...raw, 'fraction': entry.position});
  }
  final index = entry.chapters.indexWhere(
    (chapter) => chapter.id == entry.last,
  );
  if (index < 0) return null;
  return (
    index: index,
    horizontal: false,
    verticalPage: 0,
    sourceOffset: null,
    offset: 0.0,
    fraction: entry.position,
  );
}

Map<String, Object?> encodeRichPosition(RichDocumentPosition value) => {
  'index': value.index,
  'horizontal': value.horizontal,
  'verticalPage': value.verticalPage,
  'sourceOffset': ?value.sourceOffset,
  'offset': value.offset,
  'fraction': value.fraction,
};

RichDocumentPosition decodeRichPosition(Map value) => (
  index: (value['index'] as int? ?? 0).clamp(0, 3999),
  horizontal: value['horizontal'] == true,
  verticalPage: (value['verticalPage'] as int? ?? 0).clamp(0, 100000),
  sourceOffset: switch (value['sourceOffset']) {
    final int offset when offset >= 0 && offset <= 32 * 1024 * 1024 => offset,
    _ => null,
  },
  offset: (value['offset'] as num? ?? 0).toDouble().clamp(0, 10000000),
  fraction: (value['fraction'] as num? ?? 0).toDouble().clamp(0, 1),
);
