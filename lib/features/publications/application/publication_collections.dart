import 'dart:convert';

import '../data/publication_store.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';

typedef PublicationGroup = ({String id, String name});
typedef PublicationBookList = ({String id, String name, Uri? source});

final class PublicationCollections {
  PublicationCollections(this.store, this.allowed);

  final PublicationStore store;
  final bool Function(String) allowed;

  Future<List<PublicationGroup>> groups() async {
    await store.initialize();
    return [
      for (final row in await store.db.rows(
        'SELECT id,name FROM publication_groups ORDER BY name,id',
      ))
        if (allowed(row['name'] as String))
          (id: row['id'] as String, name: row['name'] as String),
    ];
  }

  Future<void> saveGroup(String raw, {String? id}) async {
    final name = _name(raw);
    await _write(name, {'publication_groups'}, () async {
      if (id == null) {
        await store.db.write('INSERT INTO publication_groups VALUES(?,?)', [
          newPublicationId(),
          name,
        ]);
      } else {
        await store.db.write(
          'UPDATE publication_groups SET name=? WHERE id=?',
          [name, id],
        );
      }
    });
  }

  Future<void> deleteGroup(PublicationGroup group) => _write(
    group.name,
    {'publication_groups', 'publication_shelf_details'},
    () =>
        store.db.write('DELETE FROM publication_groups WHERE id=?', [group.id]),
  );

  Future<void> move(PublicationHolding holding, PublicationGroup? group) =>
      _shelfChange(holding, () async {
        _require(group?.name ?? '');
        await store.db.write(
          'INSERT INTO publication_shelf_details(holding,group_id) VALUES(?,?) '
          'ON CONFLICT(holding) DO UPDATE SET group_id=excluded.group_id',
          [holding.id, group?.id],
        );
      });

  Future<void> setFinished(PublicationHolding holding, bool value) =>
      _shelfChange(
        holding,
        () => store.db.write(
          'INSERT INTO publication_shelf_details(holding,finished) VALUES(?,?) '
          'ON CONFLICT(holding) DO UPDATE SET finished=excluded.finished',
          [holding.id, value ? 1 : 0],
        ),
      );

  Future<void> _shelfChange(
    PublicationHolding holding,
    Future<void> Function() write,
  ) => _write('${holding.edition.title} ${holding.edition.author}', {
    'publication_shelf_details',
  }, write);

  Future<List<PublicationBookList>> lists() async {
    await store.initialize();
    return [
      for (final row in await store.db.rows(
        'SELECT id,name,source FROM publication_book_lists ORDER BY name,id',
      ))
        if (allowed(row['name'] as String))
          (
            id: row['id'] as String,
            name: row['name'] as String,
            source: switch (row['source']) {
              final String value => Uri.tryParse(value),
              _ => null,
            },
          ),
    ];
  }

  Future<List<PublicationEdition>> items(PublicationBookList list) async {
    await store.initialize();
    final rows = await store.db.rows(
      'SELECT data FROM publication_list_items WHERE list_id=? ORDER BY rowid',
      [list.id],
    );
    _require(list.name);
    return [
      for (final row in rows)
        if (PublicationEdition.fromJson(
              jsonDecode(row['data'] as String) as Map,
            )
            case final book when allowed('${book.title} ${book.author}'))
          book,
    ];
  }

  Future<String> createList(
    String raw, {
    Uri? source,
    Iterable<PublicationEdition> books = const [],
  }) async {
    final name = _name(raw);
    final id = newPublicationId();
    await _write(
      name,
      {'publication_book_lists', 'publication_list_items'},
      () async {
        await store.db.write(
          'INSERT INTO publication_book_lists VALUES(?,?,?)',
          [id, name, source?.toString()],
        );
        final permitted = books
            .take(250)
            .where((book) => allowed('${book.title} ${book.author}'))
            .toList();
        for (final book in permitted) {
          await _add(id, book);
        }
        store.db.beforeCommit(() {
          for (final book in permitted) {
            _require('${book.title} ${book.author}');
          }
        });
      },
    );
    return id;
  }

  Future<void> renameList(PublicationBookList list, String raw) async {
    final name = _name(raw);
    _require(list.name);
    await _write(
      name,
      {'publication_book_lists'},
      () => store.db.write(
        'UPDATE publication_book_lists SET name=? WHERE id=?',
        [name, list.id],
      ),
    );
  }

  Future<void> deleteList(PublicationBookList list) => _write(
    list.name,
    {'publication_book_lists', 'publication_list_items'},
    () => store.db.write('DELETE FROM publication_book_lists WHERE id=?', [
      list.id,
    ]),
  );

  Future<void> add(PublicationBookList list, PublicationEdition book) => _write(
    '${list.name} ${book.title} ${book.author}',
    {'publication_list_items'},
    () => _add(list.id, book),
  );

  Future<void> _add(String id, PublicationEdition book) => store.db.write(
    'INSERT OR IGNORE INTO publication_list_items VALUES(?,?,?)',
    [
      id,
      book.id,
      jsonEncode({
        'id': book.id,
        'title': book.title,
        'author': book.author,
        'isbn': book.isbn,
        if (book.page != null) 'page': book.page.toString(),
      }),
    ],
  );

  Future<void> remove(PublicationBookList list, PublicationEdition book) =>
      _write(
        list.name,
        {'publication_list_items'},
        () => store.db.write(
          'DELETE FROM publication_list_items WHERE list_id=? AND id=?',
          [list.id, book.id],
        ),
      );

  Future<void> _write(
    String text,
    Set<String> tables,
    Future<void> Function() operation,
  ) async {
    await store.initialize();
    await store.db.atomic(() async {
      _require(text);
      store.db.beforeCommit(() => _require(text));
      await operation();
    }, tables: tables);
  }

  void _require(String text) {
    if (!allowed(text)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  String _name(String raw) {
    final name = publicationLabel(raw, max: 100);
    if (name.isEmpty) throw const FormatException('请输入名称');
    return name;
  }
}
