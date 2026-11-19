import '../../../core/persistence/app_database.dart';
import '../domain/book.dart';
import 'book_store.dart';

enum ShelfListKind { group, collection, list }

final class ShelfList {
  const ShelfList(this.id, this.name, this.kind, this.books);
  final String id, name;
  final ShelfListKind kind;
  final Set<String> books;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'books': books.toList(),
  };

  static ShelfList? fromJson(Object? value) {
    if (value case {
      'id': final String id,
      'name': final String name,
      'kind': final String kind,
      'books': final List books,
    }) {
      final type = ShelfListKind.values
          .where((item) => item.name == kind)
          .firstOrNull;
      if (type != null) {
        return ShelfList(id, name, type, books.whereType<String>().toSet());
      }
    }
    return null;
  }
}

final class BookShelfLists {
  const BookShelfLists(this.store, this.kind, {this.private = false});
  final BookStore store;
  final BookKind kind;

  /// Private lists live inside the encrypted vault and require an unlock.
  final bool private;

  String get _key => 'books_shelf_lists:${kind.name}';

  Future<List<ShelfList>> load() async {
    final data = private
        ? await store.vault.read(_key)
        : await store.read(_key);
    return data is List
        ? data.map(ShelfList.fromJson).whereType<ShelfList>().toList()
        : [];
  }

  Future<void> save(String name, ShelfListKind kind, {String? id}) =>
      _edit((lists) {
        final label = bookLabel(name, 60);
        if (label.isEmpty ||
            lists.any(
              (list) =>
                  list.id != id && list.kind == kind && list.name == label,
            )) {
          throw const FormatException('名称为空或已存在');
        }
        if (id == null && lists.length >= 100) {
          throw const FormatException('最多可保存 100 个书架列表');
        }
        final old = lists.where((list) => list.id == id).firstOrNull;
        var nextId = DateTime.now().microsecondsSinceEpoch;
        final usedIds = lists.map((list) => list.id).toSet();
        while (usedIds.contains('$nextId')) {
          nextId++;
        }
        return [
          for (final list in lists)
            if (list.id != id) list,
          ShelfList(id ?? '$nextId', label, kind, old?.books ?? {}),
        ];
      });

  Future<void> delete(String id) =>
      _edit((lists) => lists.where((list) => list.id != id).toList());

  Future<void> removeBook(String bookId) => _edit((lists) {
    if (!lists.any((list) => list.books.contains(bookId))) return lists;
    return [
      for (final list in lists)
        ShelfList(list.id, list.name, list.kind, {
          ...list.books.where((id) => id != bookId),
        }),
    ];
  });

  Future<void> assign(Book book, Set<String> memberships) => _edit((lists) {
    if (book.kind != kind) return lists;
    final group = lists
        .where(
          (list) =>
              list.kind == ShelfListKind.group && memberships.contains(list.id),
        )
        .firstOrNull;
    return [
      for (final list in lists)
        ShelfList(list.id, list.name, list.kind, {
          ...list.books.where((id) => id != book.id),
          if (list.kind == ShelfListKind.group
              ? list.id == group?.id
              : memberships.contains(list.id))
            book.id,
        }),
    ];
  });

  Future<void> _edit(List<ShelfList> Function(List<ShelfList>) change) async {
    if (private && !store.vault.unlocked) {
      throw const FormatException('私密书架已锁定');
    }
    await store.db.atomic(
      () async {
        final lists = change(await load());
        final data = lists.map((list) => list.toJson()).toList();
        if (private) {
          await store.vault.write(_key, data);
        } else {
          await store.write(_key, data);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }
}
