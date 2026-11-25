import '../../../core/persistence/app_database.dart';
import '../domain/book.dart';
import 'book_store.dart';

final class BookSourceGroup {
  const BookSourceGroup(this.id, this.name, this.sourceIds);

  final String id, name;
  final Set<String> sourceIds;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'sources': sourceIds.toList(),
  };

  static BookSourceGroup? fromJson(Object? value) => switch (value) {
    {
      'id': final String id,
      'name': final String name,
      'sources': final List sources,
    } =>
      BookSourceGroup(id, name, Set.unmodifiable(sources.whereType<String>())),
    _ => null,
  };
}

final class BookSourceGroups {
  const BookSourceGroups(this.store, this.kind);

  final BookStore store;
  final BookKind kind;
  String get _key => 'books_channel_groups:${kind.name}';

  Future<List<BookSourceGroup>> load() async {
    try {
      return await _read();
    } on FormatException {
      return [];
    }
  }

  Future<List<BookSourceGroup>> _read() async {
    final data = await store.read(_key);
    return data is List
        ? data
              .map(BookSourceGroup.fromJson)
              .whereType<BookSourceGroup>()
              .toList()
        : [];
  }

  Future<void> save(String name, {String? id}) => _edit((groups) {
    final label = bookLabel(name, 60);
    if (label.isEmpty ||
        groups.any((group) => group.id != id && group.name == label)) {
      throw const FormatException('分组名称为空或已存在');
    }
    if (id == null) {
      var next = DateTime.now().microsecondsSinceEpoch;
      while (groups.any((group) => group.id == '$next')) {
        next++;
      }
      return [...groups, BookSourceGroup('$next', label, const {})];
    }
    _requireGroup(groups, id);
    return [
      for (final group in groups)
        group.id == id ? BookSourceGroup(id, label, group.sourceIds) : group,
    ];
  });

  Future<void> remove(String id) =>
      _edit((groups) => groups.where((group) => group.id != id).toList());

  Future<void> updateMembers(
    String id, {
    required Set<String> add,
    required Set<String> remove,
  }) => _edit((groups) {
    _requireGroup(groups, id);
    return [
      for (final group in groups)
        group.id == id
            ? BookSourceGroup(id, group.name, {
                ...group.sourceIds.difference(remove),
                ...add,
              })
            : group,
    ];
  });

  void _requireGroup(List<BookSourceGroup> groups, String id) {
    if (!groups.any((group) => group.id == id)) {
      throw const FormatException('渠道分组已删除，请重新选择');
    }
  }

  Future<void> _edit(
    List<BookSourceGroup> Function(List<BookSourceGroup>) change,
  ) => store.db.atomic(
    () async => store.write(
      _key,
      change(await _read()).map((group) => group.toJson()).toList(),
    ),
    tables: {'app_meta'},
    metadataDomains: {MetadataDomain.books},
  );
}
