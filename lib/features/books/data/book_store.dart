import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/persistence/app_database.dart';
import '../domain/book.dart';
import '../domain/book_download_plan.dart';
import 'book_source_links.dart';
import 'book_mixed_content.dart';
import 'book_download_evidence.dart';
import 'book_site_revision.dart';
import 'book_image_payload.dart';
import 'book_resource_limits.dart';
import 'book_catalog_window.dart';
import 'book_vault.dart';

final class ProvenBookText {
  const ProvenBookText(this.body, this.evidence, this.segments);
  final String body;
  final BookDownloadEvidence evidence;
  final List<BookChapterSegment> segments;
}

final class ProvenBookAudio {
  const ProvenBookAudio(this.directory, this.evidence);
  final String directory;
  final BookDownloadEvidence evidence;
}

final class BookSourceSubscription {
  const BookSourceSubscription(this.url, this.count, this.refreshedAt);
  final Uri url;
  final int count, refreshedAt;
  String get id => bookSubscriptionId(url);

  Map<String, Object> toJson() => {
    'url': url.toString(),
    'count': count,
    'refreshedAt': refreshedAt,
  };

  factory BookSourceSubscription.fromJson(Map data) => BookSourceSubscription(
    bookSourceLink(data['url'] as String),
    data['count'] as int,
    data['refreshedAt'] as int,
  );
}

final class BookSourceEntry {
  const BookSourceEntry(
    this.source,
    this.enabled,
    this.favorite,
    this.group,
    this.health,
    this.checkedAt, {
    this.subscriptionId,
    this.fromCatalog = false,
  });
  final BookSource source;
  final bool enabled, favorite;
  final String group, health;
  final int? checkedAt;
  final String? subscriptionId;
  final bool fromCatalog;

  BookSourceEntry withFavorite(bool value) => BookSourceEntry(
    source,
    enabled,
    value,
    group,
    health,
    checkedAt,
    subscriptionId: subscriptionId,
    fromCatalog: fromCatalog,
  );
}

/// Metadata from health checks does not change a source's discovery rules.
bool sameBookDiscoverySources(
  List<BookSourceEntry> current,
  List<BookSourceEntry> previous, {
  bool includeFavorites = false,
}) =>
    current.length == previous.length &&
    current.indexed.every((row) {
      final (index, entry) = row;
      final old = previous[index];
      return entry.source.id == old.source.id &&
          entry.enabled == old.enabled &&
          (!includeFavorites || entry.favorite == old.favorite) &&
          (identical(entry.source, old.source) ||
              _discoverySourceJson(entry.source) ==
                  _discoverySourceJson(old.source));
    });

String _discoverySourceJson(BookSource source) =>
    jsonEncode(source.toJson()..remove('updatedAt'));

final class BookShelfEntry {
  const BookShelfEntry(
    this.book,
    this.chapters,
    this.last,
    this.position,
    this.favorite,
    this.updated, {
    this.textOffset,
    this.following = false,
    this.newChapters = 0,
    this.catalogOmitted = 0,
    this.chapterUpdatedAt,
  });
  final Book book;
  final List<BookChapter> chapters;
  final String? last;
  final double position;
  final int? textOffset;
  final bool following;
  final int newChapters;
  final int catalogOmitted;
  final DateTime? chapterUpdatedAt;
  final bool favorite;
  final int updated;
}

final class BookStore {
  BookStore(this.db);
  final AppDatabase db;
  late final BookVault vault = BookVault(db);
  BookSiteRevisions get siteRevisions => BookSiteRevisions(db);

  Future<bool> isPrivateBook(String id) async {
    await vault.ensureLoaded();
    return vault.isPrivate(id);
  }

  Future<Object?> readBookValue(Book book, String key) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return null;
      return vault.read(key);
    }
    return read(key);
  }

  Future<void> writeBookValue(Book book, String key, Object? value) async {
    if (await isPrivateBook(book.id)) {
      if (value == null) {
        await vault.delete(key);
      } else {
        await vault.write(key, value);
      }
      return;
    }
    await write(key, value);
  }

  Future<Object?> read(String key) async {
    final row = (await db.rows('SELECT value FROM app_meta WHERE key=?', [
      key,
    ])).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  }

  Future<void> write(String key, Object? value) => key.startsWith('books_')
      ? db.setMetadata(key, jsonEncode(value), MetadataDomain.books)
      : db.write('INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)', [
          key,
          jsonEncode(value),
        ]);

  static String _contentEpochKey(String id) => 'books_content_epoch:$id';
  static String _contentFingerprintKey(String id) =>
      'books_content_fingerprint:$id';
  static const _bumpEpochSql =
      'UPDATE app_meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) '
      "WHERE key=? AND value GLOB '[1-9]*' "
      "AND value NOT GLOB '*[^0-9]*' AND length(value)<18";

  Future<Map<String, int>> contentEpochs() async {
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_content_epoch:*'",
    );
    final result = <String, int>{};
    for (final row in rows) {
      final id = (row['key'] as String).substring(
        'books_content_epoch:'.length,
      );
      try {
        final value = jsonDecode(row['value'] as String);
        result[id] = value is int && value >= 1 && value < 100000000000000000
            ? value
            : 0;
      } on Object {
        result[id] = 0;
      }
    }
    return result;
  }

  /// Called inside the transaction that captures the source identity.
  Future<int> ensureContentEpoch(String id, String fingerprint) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      _contentEpochKey(id),
    ]);
    if (rows.isEmpty) {
      await write(_contentEpochKey(id), 1);
      await write(_contentFingerprintKey(id), fingerprint);
      return 1;
    }
    final value = jsonDecode(rows.single['value'] as String);
    if (value is! int || value < 1 || value >= 100000000000000000) {
      throw const FormatException('离线内容来源版本损坏');
    }
    final observed = await read(_contentFingerprintKey(id));
    if (observed != fingerprint) {
      if (value >= 99999999999999999) {
        throw const FormatException('离线内容来源版本超出限制');
      }
      await write(_contentEpochKey(id), value + 1);
      await write(_contentFingerprintKey(id), fingerprint);
      return value + 1;
    }
    return value;
  }

  /// Track changes to built-in rules too, including A → B → A across launches.
  Future<void> observeTrackedSources(List<BookSourceEntry> entries) async {
    final tracked = await db.rows(
      "SELECT key FROM app_meta WHERE key GLOB 'books_content_epoch:*'",
    );
    if (tracked.isEmpty) return;
    final byId = {for (final entry in entries) entry.source.id: entry.source};
    await db.atomic(() async {
      for (final row in tracked) {
        final id = (row['key'] as String).substring(
          'books_content_epoch:'.length,
        );
        final source = byId[id];
        final fingerprint = source == null
            ? 'missing'
            : bookDownloadSourceFingerprint(source);
        Object? observed;
        try {
          observed = await read(_contentFingerprintKey(id));
        } on FormatException {
          // Do not bless an old proof when its revision metadata is damaged.
        }
        if (observed == fingerprint) continue;
        await db.write(_bumpEpochSql, [_contentEpochKey(id)]);
        await write(_contentFingerprintKey(id), fingerprint);
      }
    }, tables: {'app_meta'});
  }

  Future<int> contentEpoch(String id) async {
    final rows = await db.rows('SELECT value FROM app_meta WHERE key=?', [
      _contentEpochKey(id),
    ]);
    if (rows.isEmpty) return 0;
    try {
      final value = jsonDecode(rows.single['value'] as String);
      return value is int && value >= 1 && value < 100000000000000000
          ? value
          : 0;
    } on Object {
      return 0;
    }
  }

  Future<List<BookSourceEntry>> sources(
    List<BookSource> builtins, {
    bool enabledOnly = false,
  }) async {
    final rows = await db.rows(
      "SELECT * FROM app_meta WHERE key GLOB 'books_source:*'",
    );
    final sources = {for (final source in builtins) source.id: source};
    final states = <String, Map>{};
    for (final row in rows) {
      try {
        final id = (row['key'] as String).substring('books_source:'.length);
        final state = jsonDecode(row['value'] as String) as Map;
        final custom = state['source'];
        if (!sources.containsKey(id) &&
            custom is Map &&
            (!enabledOnly || state['enabled'] == true)) {
          final source = BookSource.fromJson(custom);
          if (source.id == id) sources[id] = source;
        }
        states[id] = state;
      } catch (_) {
        // Keep damaged records available for recovery.
      }
    }
    return [
      for (final source in sources.values)
        if (states[source.id]?['removed'] != true &&
            (!enabledOnly ||
                (states[source.id]?['enabled'] ??
                        (source.builtin && source.defaultEnabled)) ==
                    true))
          _sourceEntry(source, states[source.id] ?? const {}),
    ];
  }

  Future<BookSourceEntry?> source(BookSource? builtin, String id) async {
    try {
      final state = await read('books_source:$id');
      final data = state is Map ? state : const {};
      if (data['removed'] == true) return null;
      final custom = data['source'];
      final source =
          builtin ?? (custom is Map ? BookSource.fromJson(custom) : null);
      return source?.id == id ? _sourceEntry(source!, data) : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  BookSourceEntry _sourceEntry(BookSource source, Map state) => BookSourceEntry(
    source,
    state['enabled'] is bool
        ? state['enabled'] as bool
        : source.builtin && source.defaultEnabled,
    state['favorite'] == true,
    state['group'] is String ? state['group'] as String : source.group,
    state['health'] is String ? state['health'] as String : '',
    state['checkedAt'] is int ? state['checkedAt'] as int : null,
    subscriptionId: state['subscription'] is String
        ? state['subscription'] as String
        : null,
    fromCatalog: state['catalog'] == true,
  );

  Future<void> saveSource(
    BookSource source,
    Map<String, Object?> changes,
  ) async {
    final key = 'books_source:${source.id}';
    await db.atomic(() async {
      final old = await read(key);
      if ((!source.builtin && old is! Map) ||
          (old is Map && old['removed'] == true)) {
        throw const FormatException('该来源已移除');
      }
      if (changes.containsKey('source')) {
        await db.write(_bumpEpochSql, [_contentEpochKey(source.id)]);
      }
      final state = old is Map ? old : const {};
      final oldEnabled = state['enabled'] is bool
          ? state['enabled']
          : source.builtin && source.defaultEnabled;
      final changed =
          (changes.containsKey('source') &&
              jsonEncode(changes['source']) !=
                  jsonEncode(state['source'] ?? source.toJson())) ||
          (changes.containsKey('enabled') &&
              changes['enabled'] != oldEnabled) ||
          (changes.containsKey('removed') &&
              changes['removed'] != (state['removed'] == true)) ||
          (changes.containsKey('group') &&
              changes['group'] != (state['group'] ?? source.group));
      if (changed) await siteRevisions.change(source.id);
      await write(key, {if (old is Map) ...old, ...changes});
    }, tables: {'app_meta'});
  }

  Future<void> deleteSource(BookSource source) => db.atomic(() async {
    await db.write(_bumpEpochSql, [_contentEpochKey(source.id)]);
    await siteRevisions.change(source.id);
    if (source.builtin) {
      await write('books_source:${source.id}', {'removed': true});
    } else {
      await db.write('DELETE FROM app_meta WHERE key=?', [
        'books_source:${source.id}',
      ]);
    }
  }, tables: {'app_meta'});

  Future<Map<String, String>> blockedSources() async {
    final value = await read('books_source_blacklist');
    return value is Map ? Map<String, String>.from(value) : {};
  }

  Future<Set<String>> blockedAliases() async {
    final value = await read('books_source_blacklist_aliases');
    return value is Map ? value.keys.whereType<String>().toSet() : {};
  }

  Future<void> setSourcesEnabled(Set<String> ids, bool enabled) =>
      db.atomic(() async {
        final rows = await db.rows(
          "SELECT key,value FROM app_meta WHERE key GLOB 'books_source:*'",
        );
        final states = {
          for (final row in rows) row['key']: row['value'] as String,
        };
        await db.batch((batch) {
          for (final id in ids) {
            final key = 'books_source:$id';
            final old = states[key];
            final state = old == null
                ? <String, Object?>{}
                : jsonDecode(old) as Map;
            if (state['enabled'] != enabled) {
              batch.customStatement(BookSiteRevisions.upsertSql, [
                BookSiteRevisions.key(id),
                jsonEncode(BookSiteRevisions.newToken()),
              ]);
            }
            batch.customStatement(
              'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
              [
                key,
                jsonEncode({...state, 'enabled': enabled}),
              ],
            );
          }
        });
      }, tables: {'app_meta'});

  /// Restoring a removed built-in is a source configuration change, even
  /// though the rule itself is supplied by the application bundle.
  Future<void> restoreBuiltinSource(BookSource source) => db.atomic(() async {
    final key = 'books_source:${source.id}';
    final old = await read(key);
    final state = old is Map ? old : const {};
    final oldEnabled = state['enabled'] is bool
        ? state['enabled']
        : source.defaultEnabled;
    if (state['removed'] == true || oldEnabled != true) {
      await siteRevisions.change(source.id);
    }
    await write(key, {...state, 'enabled': true, 'removed': false});
  }, tables: {'app_meta'});

  Future<void> writeImported(
    List<({BookSource source, BookSourceEntry? previous})> entries, {
    String? subscriptionId,
    bool fromCatalog = false,
  }) async {
    await db.atomic(() async {
      await db.batch((batch) {
        for (final (:source, :previous) in entries) {
          batch.customStatement(_bumpEpochSql, [_contentEpochKey(source.id)]);
          batch.customStatement(BookSiteRevisions.upsertSql, [
            BookSiteRevisions.key(source.id),
            jsonEncode(BookSiteRevisions.newToken()),
          ]);
          batch.customStatement(
            'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
            [
              'books_source:${source.id}',
              jsonEncode({
                'source': source.toJson(),
                'enabled': previous?.enabled ?? false,
                'favorite': previous?.favorite ?? false,
                if (previous != null) 'group': previous.group,
                'subscription': ?subscriptionId,
                if (fromCatalog) 'catalog': true,
              }),
            ],
          );
        }
      });
    }, tables: {'app_meta'});
  }

  Future<List<BookSourceSubscription>> subscriptions() async {
    final rows = await db.rows(
      "SELECT value FROM app_meta WHERE key GLOB 'books_subscription:*'",
    );
    final result = <BookSourceSubscription>[];
    for (final row in rows) {
      try {
        result.add(
          BookSourceSubscription.fromJson(
            jsonDecode(row['value'] as String) as Map,
          ),
        );
      } on Object {
        // A damaged bookmark does not hide other subscriptions.
      }
    }
    return result..sort((a, b) => b.refreshedAt.compareTo(a.refreshedAt));
  }

  Future<void> saveSubscription(BookSourceSubscription subscription) =>
      write('books_subscription:${subscription.id}', subscription.toJson());

  Future<void> deleteSubscription(BookSourceSubscription subscription) =>
      db.write('DELETE FROM app_meta WHERE key=?', [
        'books_subscription:${subscription.id}',
      ]);

  Future<List<BookShelfEntry>> shelf() async {
    await vault.ensureLoaded();
    final rows = await db.rows(
      "SELECT value FROM app_meta WHERE key GLOB 'books_shelf:*'",
    );
    final result = <BookShelfEntry>[];
    for (final row in rows) {
      try {
        final entry = _entry(jsonDecode(row['value'] as String) as Map);
        if (vault.isPrivate(entry.book.id)) continue;
        result.add(entry);
      } catch (_) {
        // A bad record must not hide the rest of the shelf.
      }
    }
    return result..sort((a, b) => b.updated.compareTo(a.updated));
  }

  /// Encrypted shelf records. Empty while the vault is locked.
  Future<List<BookShelfEntry>> vaultShelf() async {
    await vault.ensureLoaded();
    if (!vault.unlocked) return [];
    final result = <BookShelfEntry>[];
    for (final id in vault.ids) {
      final raw = await vault.read('books_shelf:$id');
      if (raw is! Map) continue;
      try {
        result.add(_entry(raw));
      } catch (_) {
        // One damaged private record does not hide the others.
      }
    }
    return result..sort((a, b) => b.updated.compareTo(a.updated));
  }

  Future<BookShelfEntry?> entry(Book book) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return null;
      final raw = await vault.read('books_shelf:${book.id}');
      return raw is Map ? _entry(raw) : null;
    }
    final raw = await read('books_shelf:${book.id}');
    return raw is Map ? _entry(raw) : null;
  }

  /// Download plans outside the private space.
  Future<Map<String, BookDownloadPlan>> downloadPlans() async {
    await vault.ensureLoaded();
    final rows = await db.rows(
      "SELECT key,value FROM app_meta WHERE key GLOB 'books_download:*'",
    );
    final plans = <String, BookDownloadPlan>{};
    for (final row in rows) {
      try {
        final id = (row['key'] as String).substring('books_download:'.length);
        if (vault.isPrivate(id)) continue;
        final plan = BookDownloadPlan.fromJson(
          jsonDecode(row['value'] as String),
        );
        if (plan != null) plans[id] = plan;
      } on Object {
        // A damaged plan does not hide other downloads.
      }
    }
    return plans;
  }

  Future<Map<String, BookDownloadPlan>> vaultDownloadPlans() async {
    await vault.ensureLoaded();
    if (!vault.unlocked) return {};
    final plans = <String, BookDownloadPlan>{};
    for (final id in vault.ids) {
      final raw = await vault.read('books_download:$id');
      if (raw == null) continue;
      final plan = BookDownloadPlan.fromJson(raw);
      if (plan != null) plans[id] = plan;
    }
    return plans;
  }

  BookShelfEntry _entry(Map raw) => BookShelfEntry(
    Book.fromJson(raw['book'] as Map),
    (raw['chapters'] as List? ?? [])
        .whereType<Map>()
        .map(BookChapter.fromJson)
        .toList(),
    raw['last'] as String?,
    (raw['position'] as num?)?.toDouble() ?? 0,
    raw['favorite'] == true,
    raw['updated'] as int? ?? 0,
    textOffset: raw['textOffset'] is int ? raw['textOffset'] as int : null,
    following: raw['following'] == true,
    newChapters: raw['newChapters'] as int? ?? 0,
    catalogOmitted: raw['catalogOmitted'] is int
        ? (raw['catalogOmitted'] as int).clamp(0, 1 << 30)
        : 0,
    chapterUpdatedAt: switch (raw['chapterUpdatedAt']) {
      final int timestamp => DateTime.fromMillisecondsSinceEpoch(timestamp),
      _ => null,
    },
  );

  Future<void> saveBook(
    Book book, {
    List<BookChapter>? chapters,
    BookChapter? last,
    double? position,
    int? textOffset,
    bool? favorite,
    bool? following,
    bool clearUpdates = false,
    bool preserveCatalog = false,
  }) async {
    final key = 'books_shelf:${book.id}';
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) throw const VaultLockedException();
    await db.atomic(
      () async {
        final old = private ? await vault.read(key) : await read(key);
        final window = chapters == null
            ? null
            : await _chapterWindow(
                book,
                chapters,
                old,
                preserve:
                    preserveCatalog ||
                    (following ?? (old is Map && old['following'] == true)),
                last: last,
              );
        final next = <String, Object?>{
          if (old is Map) ...old,
          'book': book.toJson(),
          if (window != null)
            'chapters': window.chapters.map((c) => c.toJson()).toList(),
          if (window != null)
            'catalogOmitted':
                preserveCatalog && window.omitted == 0 && old is Map
                ? old['catalogOmitted'] ?? 0
                : window.omitted,
          if (last != null) 'last': last.id,
          'position': ?position,
          if (position != null ||
              (last != null && (old is! Map || old['last'] != last.id)))
            'textOffset': textOffset,
          'favorite': ?favorite,
          'following': ?following,
          if (clearUpdates || following == false) 'newChapters': 0,
          'updated': DateTime.now().millisecondsSinceEpoch,
        };
        if (private) {
          await vault.write(key, next);
        } else {
          await write(key, next);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  /// Progress updates avoid decoding/re-encoding a potentially large catalog in
  /// Dart. SQLite preserves all other shelf fields, including follow state.
  Future<void> saveReadingPosition(
    Book book,
    BookChapter chapter,
    double fraction,
    int? textOffset,
  ) async {
    final key = 'books_shelf:${book.id}';
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return;
      final raw = await vault.read(key);
      if (raw is! Map) {
        await saveBook(
          book,
          last: chapter,
          position: fraction,
          textOffset: textOffset,
        );
        return;
      }
      await vault.write(key, {
        ...raw,
        'last': chapter.id,
        'position': fraction,
        'textOffset': textOffset,
        'updated': DateTime.now().millisecondsSinceEpoch,
      });
      return;
    }
    await db.atomic(() async {
      final existing = await db.rows('SELECT key FROM app_meta WHERE key=?', [
        key,
      ]);
      if (existing.isEmpty) {
        await saveBook(
          book,
          last: chapter,
          position: fraction,
          textOffset: textOffset,
        );
        return;
      }
      await db.customStatement(
        "UPDATE app_meta SET value=json_set(value, '\$.last', ?, "
        "'\$.position', ?, '\$.textOffset', ?, '\$.updated', ?) WHERE key=?",
        [
          chapter.id,
          fraction,
          textOffset,
          DateTime.now().millisecondsSinceEpoch,
          key,
        ],
      );
    }, tables: {'app_meta'});
  }

  /// Clear resume state while retaining shelf membership and offline content.
  Future<void> clearHistory(Iterable<Book> books) async {
    for (final book in books) {
      final key = 'books_shelf:${book.id}';
      final private = await isPrivateBook(book.id);
      if (private) {
        if (!vault.unlocked) continue;
        final raw = await vault.read(key);
        if (raw is! Map) continue;
        await vault.write(key, {
          ...raw,
          'last': null,
          'position': 0,
          'textOffset': null,
        });
        await vault.delete('rich_position_${book.id}');
        continue;
      }
      await db.atomic(() async {
        final raw = await read(key);
        if (raw is! Map) return;
        await write(key, {
          ...raw,
          'last': null,
          'position': 0,
          'textOffset': null,
        });
        await db.customStatement('DELETE FROM app_meta WHERE key=?', [
          'rich_position_${book.id}',
        ]);
      }, tables: {'app_meta'});
    }
  }

  Future<void> saveRichPosition(
    Book book,
    BookChapter chapter, {
    required int index,
    required bool horizontal,
    required int verticalPage,
    required double offset,
    required double fraction,
  }) async {
    if (await entry(book) == null) return;
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) return;
    await db.atomic(
      () async {
        final position = <String, Object?>{
          'index': index,
          'horizontal': horizontal,
          'verticalPage': verticalPage,
          'offset': offset,
        };
        if (private) {
          await vault.write('rich_position_${book.id}', position);
        } else {
          await write('rich_position_${book.id}', position);
        }
        await saveBook(book, last: chapter, position: fraction);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> updateFollowedChapters(Book book, List<BookChapter> fresh) =>
      updateShelfChapters(book, fresh, followedOnly: true);

  Future<BookCatalogWindow?> updateShelfChapters(
    Book book,
    List<BookChapter> fresh, {
    bool followedOnly = false,
  }) async {
    final key = 'books_shelf:${book.id}';
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) return null;
    return db.atomic(
      () async {
        final raw = private ? await vault.read(key) : await read(key);
        if (raw is! Map || (followedOnly && raw['following'] != true)) {
          return null;
        }
        final previous = _entry(raw);
        final tail = previous.chapters.lastOrNull;
        final boundary = fresh.indexWhere((chapter) => chapter.id == tail?.id);
        final known = previous.chapters.map((chapter) => chapter.id).toSet();
        final added = boundary < 0
            ? 0
            : fresh
                  .skip(boundary + 1)
                  .where((chapter) => !known.contains(chapter.id))
                  .length;
        final window = await _chapterWindow(book, fresh, raw, preserve: true);
        final next = <String, Object?>{
          ...raw,
          'chapters': window.chapters
              .map((chapter) => chapter.toJson())
              .toList(),
          'catalogOmitted': window.omitted == 0
              ? previous.catalogOmitted
              : window.omitted,
          'newChapters': previous.newChapters + added,
          if (added > 0)
            'chapterUpdatedAt': DateTime.now().millisecondsSinceEpoch,
        };
        if (private) {
          await vault.write(key, next);
        } else {
          await write(key, next);
        }
        return window;
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<BookCatalogWindow> _chapterWindow(
    Book book,
    List<BookChapter> chapters,
    Object? raw, {
    required bool preserve,
    BookChapter? last,
  }) async {
    final old = raw is Map ? _entry(raw).chapters : <BookChapter>[];
    final lastId = last?.id ?? (raw is Map ? raw['last'] as String? : null);
    final plan = BookDownloadPlan.fromJson(
      await readBookValue(book, 'books_download:${book.id}'),
    );
    final pending =
        plan?.chapterIds ??
        (plan == null
            ? <String>[]
            : old
                  .skip(plan.first - 1)
                  .take(plan.last - plan.first + 1)
                  .map((c) => c.id)
                  .toList());
    final protected = {
      ...await savedText(book),
      ...await savedImages(book),
      ...await provenChapters('audio', book),
      ...pending,
      ?lastId,
    };
    return BookCatalogWindow(
      preserve ? old : old.where((c) => protected.contains(c.id)).toList(),
      chapters,
      last:
          last ??
          [...chapters, ...old].where((c) => c.id == lastId).firstOrNull,
      protectedIds: protected,
    );
  }

  String _provenPointer(String type, Book book, BookChapter chapter) =>
      'books_proven_${type}_current:${book.id}:${chapter.id}';

  String _provenRecord(
    String type,
    Book book,
    BookChapter chapter,
    String hash,
  ) => 'books_proven_${type}_record:${book.id}:${chapter.id}:$hash';

  Future<void> _writeProven(
    String type,
    Book book,
    BookChapter chapter,
    Map<String, Object?> value,
    Future<void> Function() validate,
  ) async {
    final encoded = jsonEncode(value);
    final hash = sha256.convert(utf8.encode(encoded)).toString();
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) throw const VaultLockedException();
    await db.atomic(
      () async {
        await validate();
        if (type == 'text') {
          final key = _provenRecord(type, book, chapter, hash);
          if (private) {
            if (await vault.read(key) == null) {
              final used =
                  (await db.rows(
                        "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                        "FROM app_meta WHERE key GLOB 'books_vault_data:*'",
                      )).single['bytes']
                      as int;
              if (used + utf8.encode(encoded).length > 96 * 1024 * 1024) {
                throw const FormatException('私密书架存储空间已满');
              }
            }
            await vault.write(key, value);
            await vault.write(_provenPointer(type, book, chapter), {
              'hash': hash,
            });
          } else {
            final existing = await db.rows(
              'SELECT 1 FROM app_meta WHERE key=?',
              [key],
            );
            if (existing.isEmpty) {
              final used =
                  (await db.rows(
                        "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                        "FROM app_meta WHERE key GLOB 'books_text:*' "
                        "OR key GLOB 'books_proven_text_record:*'",
                      )).single['bytes']
                      as int;
              if (used + utf8.encode(encoded).length > 96 * 1024 * 1024) {
                throw const FormatException('离线正文空间已满');
              }
            }
            await db.write(
              'INSERT OR IGNORE INTO app_meta(key,value) VALUES(?,?)',
              [key, encoded],
            );
            await write(_provenPointer(type, book, chapter), {'hash': hash});
          }
        } else {
          if (private) {
            await vault.write(_provenRecord(type, book, chapter, hash), value);
            await vault.write(_provenPointer(type, book, chapter), {
              'hash': hash,
            });
          } else {
            await db.write(
              'INSERT OR IGNORE INTO app_meta(key,value) VALUES(?,?)',
              [_provenRecord(type, book, chapter, hash), encoded],
            );
            await write(_provenPointer(type, book, chapter), {'hash': hash});
          }
        }
        await validate();
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<Map?> _readProven(String type, Book book, BookChapter chapter) async {
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) return null;
    try {
      final rawPointer = private
          ? await vault.read(_provenPointer(type, book, chapter))
          : await read(_provenPointer(type, book, chapter));
      if (rawPointer == null) return null;
      final pointer = rawPointer;
      final hash = pointer is Map ? pointer['hash'] : null;
      if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('离线内容来源记录损坏');
      }
      if (private) {
        final value = await vault.read(
          _provenRecord(type, book, chapter, hash),
        );
        if (value is! Map) throw const FormatException('离线内容来源记录缺失');
        if (sha256.convert(utf8.encode(jsonEncode(value))).toString() != hash) {
          throw const FormatException('离线内容来源记录损坏');
        }
        return value;
      }
      final records = await db.rows('SELECT value FROM app_meta WHERE key=?', [
        _provenRecord(type, book, chapter, hash),
      ]);
      if (records.length != 1) throw const FormatException('离线内容来源记录缺失');
      final encoded = records.single['value'] as String;
      if (sha256.convert(utf8.encode(encoded)).toString() != hash) {
        throw const FormatException('离线内容来源记录损坏');
      }
      final value = jsonDecode(encoded);
      if (value is! Map) throw const FormatException('离线内容来源记录损坏');
      return value;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('离线内容来源记录损坏');
    }
  }

  Future<void> saveProvenText(
    Book book,
    BookChapter chapter,
    String body,
    BookDownloadEvidence evidence,
    Future<void> Function() validate, {
    List<BookChapterSegment> segments = const [],
  }) {
    if (!evidence.describes(book, chapter)) {
      throw const FormatException('离线内容与来源记录不一致');
    }
    return _writeProven('text', book, chapter, {
      'body': body,
      'evidence': evidence.toJson(),
      if (segments.isNotEmpty)
        'segments': [
          for (final segment in segments)
            switch (segment) {
              BookTextSegment text => {'text': text.text},
              BookImageSegment image => {'image': image.address.toString()},
            },
        ],
    }, validate);
  }

  Future<ProvenBookText?> provenText(Book book, BookChapter chapter) async {
    final value = await _readProven('text', book, chapter);
    if (value == null) return null;
    if (value['body'] is! String) throw const FormatException('离线内容来源记录损坏');
    final evidence = BookDownloadEvidence.fromJson(value['evidence']);
    if (!evidence.describes(book, chapter)) {
      throw const FormatException('离线内容与来源记录不一致');
    }
    final rawSegments = value['segments'];
    if (rawSegments != null &&
        (rawSegments is! List || rawSegments.length > 5000)) {
      throw const FormatException('离线图文来源记录损坏');
    }
    final segments = <BookChapterSegment>[];
    for (final raw in rawSegments as List? ?? const []) {
      if (raw is! Map || raw.length != 1) {
        throw const FormatException('离线图文来源记录损坏');
      }
      if (raw['text'] is String) {
        segments.add(BookTextSegment(raw['text'] as String));
      } else if (raw['image'] is String) {
        segments.add(BookImageSegment(Uri.parse(raw['image'] as String)));
      } else {
        throw const FormatException('离线图文来源记录损坏');
      }
    }
    return ProvenBookText(value['body'] as String, evidence, segments);
  }

  Future<void> saveProvenAudio(
    Book book,
    BookChapter chapter,
    String directory,
    BookDownloadEvidence evidence,
    Future<void> Function() validate,
  ) {
    if (!evidence.describes(book, chapter) ||
        !_validAudioDirectory(book, chapter, directory)) {
      throw const FormatException('离线音频与来源记录不一致');
    }
    return _writeProven('audio', book, chapter, {
      'directory': directory,
      'evidence': evidence.toJson(),
    }, validate);
  }

  Future<ProvenBookAudio?> provenAudio(Book book, BookChapter chapter) async {
    final value = await _readProven('audio', book, chapter);
    if (value == null) return null;
    final directory = value['directory'];
    if (directory is! String ||
        !_validAudioDirectory(book, chapter, directory)) {
      throw const FormatException('离线音频来源记录损坏');
    }
    final evidence = BookDownloadEvidence.fromJson(value['evidence']);
    if (!evidence.describes(book, chapter)) {
      throw const FormatException('离线音频与来源记录不一致');
    }
    return ProvenBookAudio(directory, evidence);
  }

  bool _validAudioDirectory(Book book, BookChapter chapter, String directory) =>
      RegExp(
        r'^v2-[a-f0-9]{64}-[a-f0-9]{64}-[a-zA-Z0-9_-]+$',
      ).hasMatch(directory) &&
      directory.startsWith('v2-${book.id}-${chapter.id}-');

  Future<Set<String>> provenChapters(String type, Book book) async {
    final prefix = 'books_proven_${type}_current:${book.id}:';
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return {};
      final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '${BookVault.dataPrefix}$prefix*',
      ]);
      final offset = BookVault.dataPrefix.length + prefix.length;
      return {for (final row in rows) (row['key'] as String).substring(offset)};
    }
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    return {
      for (final row in rows) (row['key'] as String).substring(prefix.length),
    };
  }

  Future<void> clearProvenAudio(Book book, {BookChapter? chapter}) async {
    final suffix = chapter == null ? '*' : '${chapter.id}*';
    if (await isPrivateBook(book.id)) {
      for (final type in ['current', 'record']) {
        await vault.deletePrefix('books_proven_audio_$type:${book.id}:$suffix');
      }
      return;
    }
    await db.atomic(() async {
      for (final type in ['current', 'record']) {
        await db.write('DELETE FROM app_meta WHERE key GLOB ?', [
          'books_proven_audio_$type:${book.id}:$suffix',
        ]);
      }
    }, tables: {'app_meta'});
  }

  String _textKey(Book book, BookChapter chapter) =>
      'books_text:${book.id}:${chapter.id}';

  Future<String?> text(Book book, BookChapter chapter) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return null;
      return await vault.read(_textKey(book, chapter)) as String?;
    }
    return await read(_textKey(book, chapter)) as String?;
  }

  String _readingCacheKey(Book book, BookChapter chapter) =>
      'books_read_cache:${book.id}:${chapter.id}';

  Future<String?> readingCache(Book book, BookChapter chapter) async {
    // Reading caches stay in memory only for private books so the plaintext
    // cannot outlive the unlocked session in the database.
    if (await isPrivateBook(book.id)) return null;
    return await read(_readingCacheKey(book, chapter)) as String?;
  }

  Future<void> cacheReading(
    Book book,
    BookChapter chapter,
    String text, {
    void Function()? validate,
  }) async {
    if (await isPrivateBook(book.id)) return;
    final value = jsonEncode(text);
    final size = utf8.encode(value).length;
    if (size > 2 * 1024 * 1024) return;
    await db.atomic(() async {
      validate?.call();
      final key = _readingCacheKey(book, chapter);
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [key, value],
      );
      final rows = await db.rows(
        "SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta "
        "WHERE key GLOB 'books_read_cache:*' ORDER BY rowid DESC",
      );
      var used = 0;
      for (final row in rows) {
        used += row['bytes'] as int;
        if (used > 24 * 1024 * 1024) {
          await db.customStatement('DELETE FROM app_meta WHERE key=?', [
            row['key'],
          ]);
        }
      }
      validate?.call();
    }, tables: {'app_meta'});
  }

  Future<void> clearReadingCache([Book? book]) => db.atomic(() async {
    await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
      book == null ? 'books_read_cache:*' : 'books_read_cache:${book.id}:*',
    ]);
    await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
      book == null ? 'books_image_cache:*' : 'books_image_cache:${book.id}:*',
    ]);
    await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
      book == null ? 'books_mixed_cache:*' : 'books_mixed_cache:${book.id}:*',
    ]);
  }, tables: {'app_meta'});

  String _mixedKey(Book book, BookChapter chapter) =>
      'books_mixed_cache:${book.id}:${chapter.id}';

  Future<List<BookChapterSegment>> mixedReading(
    Book book,
    BookChapter chapter,
  ) async {
    if (await isPrivateBook(book.id)) return const [];
    final raw = await read(_mixedKey(book, chapter));
    if (raw is! List) return const [];
    try {
      return [
        for (final part in raw.cast<Map>())
          if (part['text'] is String)
            BookTextSegment(part['text'] as String)
          else if (part['image'] is String)
            BookImageSegment(Uri.parse(part['image'] as String)),
      ];
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  Future<void> cacheMixedReading(
    Book book,
    BookChapter chapter,
    List<BookChapterSegment> parts, {
    void Function()? validate,
  }) async {
    if (await isPrivateBook(book.id)) return;
    final value = jsonEncode([
      for (final part in parts)
        switch (part) {
          BookTextSegment text => {'text': text.text},
          BookImageSegment image => {'image': image.address.toString()},
        },
    ]);
    if (utf8.encode(value).length > 512 * 1024) return;
    await db.atomic(() async {
      validate?.call();
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [_mixedKey(book, chapter), value],
      );
      final rows = await db.rows(
        "SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta "
        "WHERE key GLOB 'books_mixed_cache:*' ORDER BY rowid DESC",
      );
      var used = 0;
      for (final row in rows) {
        used += row['bytes'] as int;
        if (used > 24 * 1024 * 1024) {
          await db.customStatement('DELETE FROM app_meta WHERE key=?', [
            row['key'],
          ]);
        }
      }
      validate?.call();
    }, tables: {'app_meta'});
  }

  String _imageCacheKey(Book book, Uri image) =>
      'books_image_cache:${book.id}:${base64UrlEncode(utf8.encode(image.toString()))}';

  Future<List<int>?> readingImage(Book book, Uri image) async {
    if (await isPrivateBook(book.id)) return null;
    final encoded = await read(_imageCacheKey(book, image));
    if (encoded is! String) return null;
    try {
      final bytes = base64Decode(encoded);
      await validateReadableBookImage(image, bytes);
      return bytes;
    } on FormatException {
      await db.customStatement('DELETE FROM app_meta WHERE key=?', [
        _imageCacheKey(book, image),
      ]);
      return null;
    }
  }

  Future<void> cacheReadingImage(
    Book book,
    Uri image,
    List<int> bytes, {
    void Function()? validate,
  }) async {
    if (await isPrivateBook(book.id)) return;
    if (bytes.length > BookResourceLimits.imageBytes) return;
    await validateReadableBookImage(image, bytes);
    await db.atomic(() async {
      validate?.call();
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [_imageCacheKey(book, image), jsonEncode(base64Encode(bytes))],
      );
      final rows = await db.rows(
        "SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta "
        "WHERE key GLOB 'books_image_cache:*' ORDER BY rowid DESC",
      );
      var used = 0;
      for (final row in rows) {
        used += row['bytes'] as int;
        if (used > BookResourceLimits.readingBytes) {
          await db.customStatement('DELETE FROM app_meta WHERE key=?', [
            row['key'],
          ]);
        }
      }
      validate?.call();
    }, tables: {'app_meta'});
  }

  String _offlineImageKey(Book book, BookChapter chapter) =>
      'books_image_offline:${book.id}:${chapter.id}';

  String _offlineImagePartPrefix(Book book, BookChapter chapter) =>
      'books_image_data:${book.id}:${chapter.id}:';

  Future<List<Uri>?> offlineImageAddresses(
    Book book,
    BookChapter chapter,
  ) async {
    final raw = await read(_offlineImageKey(book, chapter));
    if (raw is! List) return null;
    try {
      return raw.cast<String>().map(Uri.parse).toList();
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<List<int>?> offlineImageBytes(
    Book book,
    BookChapter chapter,
    Uri image,
  ) async {
    final addresses = await offlineImageAddresses(book, chapter);
    final index = addresses?.indexOf(image) ?? -1;
    if (index < 0) return null;
    final raw = await read('${_offlineImagePartPrefix(book, chapter)}$index');
    if (raw is! String) return null;
    try {
      return base64Decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<Map<Uri, List<int>>?> offlineImages(
    Book book,
    BookChapter chapter,
  ) async {
    final addresses = await offlineImageAddresses(book, chapter);
    if (addresses == null) return null;
    final images = <Uri, List<int>>{};
    for (var index = 0; index < addresses.length; index++) {
      final raw = await read('${_offlineImagePartPrefix(book, chapter)}$index');
      if (raw is! String) return null;
      try {
        images[addresses[index]] = base64Decode(raw);
      } on FormatException {
        return null;
      }
    }
    return images;
  }

  Future<void> saveOfflineImages(
    Book book,
    BookChapter chapter,
    Map<Uri, List<int>> images,
    Future<void> Function() validate,
  ) async {
    if (images.isEmpty || images.length > BookResourceLimits.chapterImages) {
      throw const FormatException('章节图片数量无效');
    }
    final rawBytes = images.values.fold<int>(
      0,
      (total, value) => total + value.length,
    );
    if (rawBytes > BookResourceLimits.chapterImageBytes ||
        images.values.any(
          (bytes) => bytes.length > BookResourceLimits.imageBytes,
        )) {
      throw const FormatException('单章图片超过离线空间限制');
    }
    for (final entry in images.entries) {
      await validate();
      await validateReadableBookImage(entry.key, entry.value);
    }
    // Account for base64 and JSON quotes without holding another chapter-sized
    // collection. Encode and release only one image at a time in the transaction.
    final bytes = images.values.fold<int>(
      0,
      (total, value) => total + ((value.length + 2) ~/ 3) * 4 + 2,
    );
    await db.atomic(() async {
      final key = _offlineImageKey(book, chapter);
      final prefix = _offlineImagePartPrefix(book, chapter);
      final used =
          (await db.rows(
                "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                "FROM app_meta WHERE key GLOB 'books_image_data:*' AND key NOT GLOB ?",
                ['$prefix*'],
              )).single['bytes']
              as int;
      if (used + bytes > BookResourceLimits.offlineImageBytes) {
        throw const FormatException('离线图片空间已满');
      }
      await validate();
      await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]);
      var index = 0;
      for (final image in images.values) {
        await db.customStatement(
          'INSERT INTO app_meta(key,value) VALUES(?,?)',
          ['$prefix${index++}', jsonEncode(base64Encode(image))],
        );
      }
      await validate();
      await db.customStatement(
        'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
        [key, jsonEncode(images.keys.map((uri) => uri.toString()).toList())],
      );
    }, tables: {'app_meta'});
  }

  Future<Set<String>> savedImages(Book book) async {
    final prefix = 'books_image_offline:${book.id}:';
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    return {
      for (final row in rows) (row['key'] as String).substring(prefix.length),
    };
  }

  Future<void> deleteImages(Book book, BookChapter chapter) =>
      db.atomic(() async {
        await db.customStatement('DELETE FROM app_meta WHERE key=?', [
          _offlineImageKey(book, chapter),
        ]);
        await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
          '${_offlineImagePartPrefix(book, chapter)}*',
        ]);
      }, tables: {'app_meta'});

  Future<void> saveText(Book book, BookChapter chapter, String text) async {
    await saveTexts(book, {chapter: text});
  }

  Future<void> saveTexts(Book book, Map<BookChapter, String> contents) async {
    final data = {
      for (final entry in contents.entries)
        _textKey(book, entry.key): jsonEncode(entry.value),
    };
    final private = await isPrivateBook(book.id);
    if (private) {
      if (!vault.unlocked) throw const VaultLockedException();
      final prefix = '${BookVault.dataPrefix}books_text:${book.id}:';
      final used =
          (await db.rows(
                "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes "
                "FROM app_meta WHERE key GLOB 'books_vault_data:*'",
              )).single['bytes']
              as int;
      final current = await db.rows(
        'SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta '
        'WHERE key GLOB ?',
        ['$prefix*'],
      );
      final replaced = current
          .where(
            (row) =>
                data.keys.any((key) => (row['key'] as String) == '$prefix$key'),
          )
          .fold<int>(0, (sum, row) => sum + (row['bytes'] as int));
      final bytes = data.values.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(value).length * 4 ~/ 3 + 64,
      );
      if (used - replaced + bytes > 96 * 1024 * 1024) {
        throw const FormatException('私密书架存储空间已满');
      }
      for (final entry in contents.entries) {
        await vault.write(_textKey(book, entry.key), entry.value);
      }
      return;
    }
    await db.atomic(() async {
      final used =
          (await db.rows(
                "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes FROM app_meta "
                "WHERE key GLOB 'books_text:*' OR key GLOB 'books_proven_text_record:*'",
              )).single['bytes']
              as int;
      final current = await db.rows(
        'SELECT key,length(CAST(value AS BLOB)) AS bytes FROM app_meta WHERE key GLOB ?',
        ['books_text:${book.id}:*'],
      );
      final replaced = current
          .where((row) => data.containsKey(row['key']))
          .fold<int>(0, (sum, row) => sum + (row['bytes'] as int));
      final bytes = data.values.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(value).length,
      );
      if (used - replaced + bytes > 96 * 1024 * 1024) {
        throw const FormatException('离线正文空间已满');
      }
      for (final entry in data.entries) {
        await db.customStatement(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [entry.key, entry.value],
        );
      }
    }, tables: {'app_meta'});
  }

  Future<List<Map>> annotations(Book book) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return [];
      final raw = await vault.read('books_notes:${book.id}');
      return raw is List ? raw.whereType<Map>().toList() : [];
    }
    final raw = await read('books_notes:${book.id}');
    return raw is List ? raw.whereType<Map>().toList() : [];
  }

  Future<void> addAnnotation(Book book, Map<String, Object?> entry) async {
    final private = await isPrivateBook(book.id);
    await db.atomic(
      () async {
        final entries = await annotations(book);
        if (entries.length >= 1000) {
          throw const FormatException('每本书最多保存 1000 条记录');
        }
        final next = [entry, ...entries];
        if (private) {
          await vault.write('books_notes:${book.id}', next);
        } else {
          await write('books_notes:${book.id}', next);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> deleteAnnotation(Book book, String id) async {
    final private = await isPrivateBook(book.id);
    await db.atomic(
      () async {
        final entries = await annotations(book);
        final next = entries.where((e) => e['id'] != id).toList();
        if (private) {
          await vault.write('books_notes:${book.id}', next);
        } else {
          await write('books_notes:${book.id}', next);
        }
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> removeLocal(Book book) async {
    final private = await isPrivateBook(book.id);
    await db.atomic(
      () async {
        await _deleteBookKeys(book, includeOffline: true, includeNotes: true);
        if (private) await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<Set<String>> savedText(Book book) async {
    if (await isPrivateBook(book.id)) {
      if (!vault.unlocked) return {};
      final prefix = '${BookVault.dataPrefix}books_text:${book.id}:';
      final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '$prefix*',
      ]);
      return {
        for (final row in rows) (row['key'] as String).substring(prefix.length),
        ...await provenChapters('text', book),
      };
    }
    final prefix = 'books_text:${book.id}:';
    final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
      '$prefix*',
    ]);
    return {
      for (final row in rows) (row['key'] as String).substring(prefix.length),
      ...await provenChapters('text', book),
    };
  }

  Future<void> deleteText(Book book, BookChapter chapter) async {
    if (await isPrivateBook(book.id)) {
      await vault.delete(_textKey(book, chapter));
      await vault.delete(_provenPointer('text', book, chapter));
      await vault.deletePrefix(
        'books_proven_text_record:${book.id}:${chapter.id}:',
      );
      return;
    }
    await db.atomic(() async {
      await db.write('DELETE FROM app_meta WHERE key=?', [
        _textKey(book, chapter),
      ]);
      await db.write('DELETE FROM app_meta WHERE key=?', [
        _provenPointer('text', book, chapter),
      ]);
      await db.write('DELETE FROM app_meta WHERE key GLOB ?', [
        'books_proven_text_record:${book.id}:${chapter.id}:*',
      ]);
    }, tables: {'app_meta'});
  }

  Future<void> clearOffline(Book book) async {
    if (book.kind == BookKind.comic) {
      await db.atomic(() async {
        for (final pattern in [
          'books_image_offline:${book.id}:*',
          'books_image_data:${book.id}:*',
        ]) {
          await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
            pattern,
          ]);
        }
      }, tables: {'app_meta'});
      return;
    }
    if (await isPrivateBook(book.id)) {
      for (final prefix in [
        'books_text:${book.id}:',
        'books_proven_text_current:${book.id}:',
        'books_proven_text_record:${book.id}:',
        'books_proven_audio_current:${book.id}:',
        'books_proven_audio_record:${book.id}:',
      ]) {
        await vault.deletePrefix(prefix);
      }
      return;
    }
    await db.atomic(() async {
      for (final pattern in [
        'books_text:${book.id}:*',
        'books_proven_text_current:${book.id}:*',
        'books_proven_text_record:${book.id}:*',
      ]) {
        await db.customStatement('DELETE FROM app_meta WHERE key GLOB ?', [
          pattern,
        ]);
      }
    }, tables: {'app_meta'});
  }

  /// Removes the shelf record but can retain downloads and notes.
  Future<void> removeFromShelf(Book book, {required bool clearOffline}) =>
      _deleteBookRecord(book, offline: clearOffline, notes: false);

  /// Full delete of the visible record; downloads are optional.
  Future<void> deleteBook(Book book, {required bool clearOffline}) =>
      _deleteBookRecord(book, offline: clearOffline, notes: true);

  Future<void> _deleteBookRecord(
    Book book, {
    required bool offline,
    required bool notes,
  }) async {
    final private = await isPrivateBook(book.id);
    if (private && !vault.unlocked) throw const VaultLockedException();
    await db.atomic(
      () async {
        await _deleteBookKeys(
          book,
          includeOffline: offline,
          includeNotes: notes,
        );
        if (private && offline) await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<void> _deleteBookKeys(
    Book book, {
    required bool includeOffline,
    required bool includeNotes,
  }) async {
    final private = await isPrivateBook(book.id);
    if (private) {
      await vault.delete('books_shelf:${book.id}');
      await vault.delete('rich_position_${book.id}');
      if (includeNotes) await vault.delete('books_notes:${book.id}');
      if (includeOffline) {
        for (final prefix in [
          'books_text:${book.id}:',
          'books_proven_text_current:${book.id}:',
          'books_proven_text_record:${book.id}:',
          'books_proven_audio_current:${book.id}:',
          'books_proven_audio_record:${book.id}:',
          'books_download:${book.id}',
          'books_download_failures:${book.id}',
          'books_download_blocked:${book.id}',
        ]) {
          await vault.deletePrefix(prefix);
        }
      }
    } else {
      for (final key in [
        'books_shelf:${book.id}',
        'rich_position_${book.id}',
        'publication_${book.id}',
        if (includeNotes) 'books_notes:${book.id}',
      ]) {
        await db.write('DELETE FROM app_meta WHERE key=?', [key]);
      }
      if (includeOffline) {
        for (final pattern in [
          'books_text:${book.id}:*',
          'books_proven_text_current:${book.id}:*',
          'books_proven_text_record:${book.id}:*',
          'books_proven_audio_current:${book.id}:*',
          'books_proven_audio_record:${book.id}:*',
          'books_download:${book.id}',
          'books_download_failures:${book.id}',
          'books_download_blocked:${book.id}',
        ]) {
          await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
        }
      }
    }
    for (final pattern in [
      'books_read_cache:${book.id}:*',
      'books_image_cache:${book.id}:*',
      'books_mixed_cache:${book.id}:*',
      if (includeOffline) ...[
        'books_image_offline:${book.id}:*',
        'books_image_data:${book.id}:*',
      ],
    ]) {
      await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
    }
  }

  /// Moves every book-scoped record into the encrypted space.
  Future<void> moveToVault(Book book) async {
    await vault.ensureLoaded();
    if (!vault.unlocked) throw const VaultLockedException();
    if (vault.isPrivate(book.id)) return;
    await db.atomic(
      () async {
        for (final key in await _bookScopedKeys(book.id)) {
          final raw = await read(key);
          if (raw == null) continue;
          await vault.write(key, raw);
          await db.write('DELETE FROM app_meta WHERE key=?', [key]);
        }
        // Plaintext reading caches are re-fetchable and must not outlive the
        // move into the encrypted space.
        for (final pattern in [
          'books_read_cache:${book.id}:*',
          'books_mixed_cache:${book.id}:*',
          'books_image_cache:${book.id}:*',
        ]) {
          await db.write('DELETE FROM app_meta WHERE key GLOB ?', [pattern]);
        }
        await vault.addBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  /// Decrypts and restores every record to the public shelf.
  Future<void> moveOutOfVault(Book book) async {
    await vault.ensureLoaded();
    if (!vault.unlocked) throw const VaultLockedException();
    if (!vault.isPrivate(book.id)) return;
    await db.atomic(
      () async {
        final keys = await _vaultBookKeys(book.id);
        for (final key in keys) {
          final raw = await vault.read(key);
          if (raw != null) {
            await write(key, raw);
          }
          await vault.delete(key);
        }
        await vault.removeBook(book.id);
      },
      tables: {'app_meta'},
      metadataDomains: {MetadataDomain.books},
    );
  }

  Future<List<String>> _bookScopedKeys(String id) async {
    final keys = <String>{};
    for (final key in [
      'books_shelf:$id',
      'books_notes:$id',
      'rich_position_$id',
      'books_download:$id',
      'books_download_failures:$id',
      'books_download_blocked:$id',
    ]) {
      final rows = await db.rows('SELECT key FROM app_meta WHERE key=?', [key]);
      if (rows.isNotEmpty) keys.add(key);
    }
    for (final pattern in [
      'books_text:$id:*',
      'books_proven_text_current:$id:*',
      'books_proven_text_record:$id:*',
      'books_proven_audio_current:$id:*',
      'books_proven_audio_record:$id:*',
    ]) {
      final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        pattern,
      ]);
      keys.addAll(rows.map((row) => row['key'] as String));
    }
    return keys.toList();
  }

  Future<List<String>> _vaultBookKeys(String id) async {
    final prefix = BookVault.dataPrefix;
    final keys = <String>{};
    for (final pattern in [
      'books_shelf:$id',
      'books_notes:$id',
      'rich_position_$id',
      'books_download:$id',
      'books_download_failures:$id',
      'books_download_blocked:$id',
      'books_text:$id:*',
      'books_proven_text_current:$id:*',
      'books_proven_text_record:$id:*',
      'books_proven_audio_current:$id:*',
      'books_proven_audio_record:$id:*',
    ]) {
      final rows = await db.rows('SELECT key FROM app_meta WHERE key GLOB ?', [
        '$prefix$pattern',
      ]);
      for (final row in rows) {
        keys.add((row['key'] as String).substring(prefix.length));
      }
    }
    return keys.toList();
  }
}
