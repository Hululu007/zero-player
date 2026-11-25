import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'schema.dart';
import 'installation_metadata.dart';
import '../diagnostics/performance_counters.dart';
import 'metadata_domain.dart';
export 'metadata_domain.dart';

/// Current development schema; no legacy-format migration scaffolding.
final class AppDatabase extends GeneratedDatabase {
  AppDatabase(File file) : super(NativeDatabase.createInBackground(file));
  AppDatabase.memory() : super(NativeDatabase.memory());
  final _changes = StreamController<_DatabaseChange>.broadcast();
  bool _closed = false;
  Future<void>? _closing;
  final _notificationKey = Object();
  Stream<void> get changes => _changes.stream.map((_) {});
  Stream<void> changesFor(
    Set<String> tables, {
    Set<MetadataDomain>? metadataDomains,
  }) => _changes.stream
      .where((change) => change.affects(tables, metadataDomains))
      .map((_) {});
  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      for (final sql in schemaStatements) {
        await customStatement(sql);
      }
      await customStatement('INSERT INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        freshInstallationAccess,
      ]);
    }),
    onUpgrade: (_, from, to) => transaction(() async {
      // Preserve the user's current sources, history and offline tasks.
      if (from == 1 && to == 3) {
        await customStatement(
          'CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await _addColumn('sources', 'site_title', 'TEXT');
        await _addColumn('sources', 'homepage', 'TEXT');
        await _addColumn('source_health', 'latency_ms', 'INTEGER');
        await _addColumn('downloads', 'work_json', 'TEXT');
      } else if (from != 2 || to != 3) {
        throw StateError('Unsupported database migration: $from -> $to');
      }
      await customStatement('INSERT OR IGNORE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
    }),
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS app_meta_book_text_bytes '
        'ON app_meta(length(CAST(value AS BLOB))) '
        "WHERE key GLOB 'books_text:*' OR key GLOB 'books_proven_text_record:*'",
      );
    },
  );

  Future<void> _addColumn(String table, String name, String type) async {
    final columns = await rows('PRAGMA table_info($table)');
    if (!columns.any((column) => column['name'] == name)) {
      await customStatement('ALTER TABLE $table ADD COLUMN $name $type');
    }
  }

  Future<List<Map<String, Object?>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    _checkOpen();
    final result = await customSelect(
      sql,
      variables: args.map(_variable).toList(),
    ).get();
    PerformanceCounters.add('db.queries');
    PerformanceCounters.add('db.rows', result.length);
    return result.map((row) => Map<String, Object?>.from(row.data)).toList();
  }

  Variable _variable(Object? value) => switch (value) {
    int v => Variable<int>(v),
    double v => Variable<double>(v),
    bool v => Variable<bool>(v),
    String v => Variable<String>(v),
    null => const Variable<String>(null),
    _ => throw ArgumentError('Unsupported SQL value'),
  };

  Future<void> write(String sql, [List<Object?> args = const []]) async {
    _checkOpen();
    await customStatement(sql, args);
    final match = RegExp(
      r'^\s*(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+([a-z_][a-z_0-9]*)',
      caseSensitive: false,
    ).firstMatch(sql);
    changed(tables: match == null ? null : {match[1]!.toLowerCase()});
  }

  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    await super.customStatement(statement, args);
    PerformanceCounters.add('db.statements');
    // Raw SQL is deliberately not parsed for key coverage. It still does not
    // auto-publish, but prevents a surrounding precise declaration hiding it.
    (Zone.current[_notificationKey] as _ChangeBatch?)?.untracked = true;
  }

  @override
  Future<void> batch(FutureOr<void> Function(Batch batch) runInBatch) async {
    await super.batch(runInBatch);
    (Zone.current[_notificationKey] as _ChangeBatch?)?.untracked = true;
  }

  Future<void> setMetadata(String key, String value, MetadataDomain domain) =>
      _metadataStatement(
        'INSERT OR REPLACE INTO app_meta VALUES(?,?)',
        [key, value],
        key,
        domain,
      );

  Future<void> deleteMetadata(String key, MetadataDomain domain) =>
      _metadataStatement(
        'DELETE FROM app_meta WHERE key=?',
        [key],
        key,
        domain,
      );

  Future<void> clearMusicHistory() => _metadataStatement(
    "DELETE FROM app_meta WHERE key GLOB 'music_history:*'",
    [],
    'music_history:',
    MetadataDomain.musicHistory,
  );

  Future<void> _metadataStatement(
    String sql,
    List<Object?> args,
    String key,
    MetadataDomain domain,
  ) => transaction(() async {
    _checkOpen();
    if (!domain.accepts(key)) throw ArgumentError('Metadata domain mismatch');
    final before =
        (await rows('SELECT total_changes() AS n')).single['n'] as int;
    await super.customStatement(sql, args);
    PerformanceCounters.add('db.statements');
    final after = (await rows(
      'SELECT total_changes() AS n, changes() AS direct',
    )).single;
    // Keep these counters with this statement; another caller must not replace
    // changes() between the mutation and its coverage check.
    // Trigger/cascade effects still make the explicit key insufficient.
    final exact = (after['n'] as int) - before == after['direct'];
    changed(
      tables: exact ? {'app_meta'} : null,
      metadataDomains: exact ? {domain} : null,
    );
  });

  void changed({Set<String>? tables, Set<MetadataDomain>? metadataDomains}) {
    final batch = Zone.current[_notificationKey] as _ChangeBatch?;
    if (batch != null) {
      batch.add(tables, metadataDomains);
      return;
    }
    if (tables != null && tables.isEmpty) return;
    if (!_changes.isClosed) {
      PerformanceCounters.add('db.notifications');
      _changes.add(_DatabaseChange(tables, metadataDomains));
    }
  }

  /// Pending derived state is visible only within this transaction and its
  /// children. It is discarded on rollback, like its corresponding SQL rows.
  Object? transactionState(Object key) {
    var batch = Zone.current[_notificationKey] as _ChangeBatch?;
    while (batch != null) {
      if (batch.state.containsKey(key)) return batch.state[key];
      batch = batch.parent;
    }
    return null;
  }

  void setTransactionState(Object key, Object value) {
    final batch = Zone.current[_notificationKey] as _ChangeBatch?;
    if (batch == null) throw StateError('No active transaction');
    batch.state[key] = value;
  }

  /// Runs immediately before the outer transaction commits, or after it has
  /// committed. Nested transactions publish callbacks only with their parent.
  void beforeCommit(void Function() check) {
    final batch = Zone.current[_notificationKey] as _ChangeBatch?;
    if (batch == null) throw StateError('No active transaction');
    batch.beforeCommit.add(check);
  }

  void afterCommit(void Function() publish) {
    final batch = Zone.current[_notificationKey] as _ChangeBatch?;
    if (batch == null) throw StateError('No active transaction');
    batch.afterCommit.add(publish);
  }

  Future<T> atomic<T>(
    Future<T> Function() work, {
    Set<String>? tables,
    Set<MetadataDomain>? metadataDomains,
  }) => _transaction(work, tables: tables, metadataDomains: metadataDomains);

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => _transaction(action, tables: const {}, requireNew: requireNew);

  Future<T> _transaction<T>(
    Future<T> Function() work, {
    required Set<String>? tables,
    Set<MetadataDomain>? metadataDomains,
    bool requireNew = false,
  }) async {
    _checkOpen();
    final parent = Zone.current[_notificationKey] as _ChangeBatch?;
    final batch = _ChangeBatch(parent);
    final result = await super.transaction(
      () => runZoned(() async {
        final value = await work();
        for (final check in batch.beforeCommit) {
          check();
        }
        return value;
      }, zoneValues: {_notificationKey: batch}),
      requireNew: requireNew,
    );
    batch.add(tables, metadataDomains);
    if (parent != null) {
      if (batch.untracked) parent.untracked = true;
      parent.state.addAll(batch.state);
      parent.beforeCommit.addAll(batch.beforeCommit);
      parent.afterCommit.addAll(batch.afterCommit);
    } else {
      for (final publish in batch.afterCommit) {
        publish();
      }
    }
    changed(
      tables: batch.all ? null : batch.tables,
      metadataDomains: batch.untracked ? null : batch.metadataDomains,
    );
    return result;
  }

  @override
  Future<void> close() => _closing ??= _close();

  void _checkOpen() {
    if (_closed) throw StateError('Database is closed');
  }

  Future<void> _close() async {
    _closed = true;
    await _changes.close();
    await super.close();
  }
}

final class _ChangeBatch {
  _ChangeBatch(this.parent);
  final _ChangeBatch? parent;
  final state = <Object, Object>{};
  final beforeCommit = <void Function()>[];
  final afterCommit = <void Function()>[];
  bool all = false;
  bool untracked = false;
  final tables = <String>{};
  Set<MetadataDomain>? metadataDomains = {};
  void add(Set<String>? changed, Set<MetadataDomain>? domains) {
    if (changed == null) {
      all = true;
    } else {
      tables.addAll(changed);
    }
    if (changed == null || changed.contains('app_meta')) {
      if (domains == null) {
        metadataDomains = null;
      } else {
        metadataDomains?.addAll(domains);
      }
    }
  }
}

final class _DatabaseChange {
  _DatabaseChange(Set<String>? tables, Set<MetadataDomain>? domains)
    : tables = tables == null ? null : Set.unmodifiable(tables),
      metadataDomains = domains == null ? null : Set.unmodifiable(domains);
  final Set<String>? tables;
  final Set<MetadataDomain>? metadataDomains;

  bool affects(Set<String> watched, Set<MetadataDomain>? domains) {
    final changed = tables;
    if (changed == null) return true;
    return changed.any(
      (table) =>
          watched.contains(table) &&
          (table != 'app_meta' ||
              domains == null ||
              metadataDomains == null ||
              metadataDomains!.any(domains.contains)),
    );
  }
}
