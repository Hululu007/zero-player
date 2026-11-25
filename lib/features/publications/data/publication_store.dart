import 'dart:convert';
import 'dart:math';

import '../../../core/persistence/app_database.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_schema.dart';

String newPublicationId() {
  final random = Random.secure();
  return publicationId(List.generate(32, (_) => random.nextInt(256)).join(','));
}

int publicationNow() => DateTime.now().millisecondsSinceEpoch;

final class PublicationStore {
  PublicationStore(this.db);
  final AppDatabase db;
  Future<void>? _initializing;

  Future<void> initialize() => _initializing ??= _install();

  Future<void> _install() async {
    try {
      await db.atomic(() async {
        for (final sql in publicationSchema) {
          await db.customStatement(sql);
        }
        for (final (table, column, definition) in const [
          (
            'publication_source_settings',
            'favorite',
            'INTEGER NOT NULL DEFAULT 0',
          ),
          ('publication_tasks', 'archive_kept', 'INTEGER NOT NULL DEFAULT 0'),
          ('publication_tasks', 'space_shortfall', 'TEXT'),
        ]) {
          final columns = await db.rows('PRAGMA table_info($table)');
          if (!columns.any((row) => row['name'] == column)) {
            await db.customStatement(
              'ALTER TABLE $table ADD COLUMN $column $definition',
            );
          }
        }
        await _upgradeLeases();
        await db.customStatement(
          "DELETE FROM publication_source_settings WHERE spec IS NULL "
          "AND id IN ('rust-zh','pro-git')",
        );
      }, tables: const {});
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  Future<void> _upgradeLeases() async {
    // Old leases were tied to a shelf digest. A legacy reader may open a file
    // before it has been attached to a publication.
    if ((await db.rows(
      'PRAGMA foreign_key_list(publication_leases)',
    )).isEmpty) {
      return;
    }
    await db.customStatement(
      'ALTER TABLE publication_leases RENAME TO publication_leases_previous',
    );
    await db.customStatement(publicationLeasesSchema);
    await db.customStatement(
      'INSERT INTO publication_leases(id,digest,process) '
      'SELECT id,digest,process FROM publication_leases_previous',
    );
    await db.customStatement('DROP TABLE publication_leases_previous');
  }

  Future<String?> preference(String key) async {
    await initialize();
    return (await db.rows(
          'SELECT value FROM publication_preferences WHERE key=?',
          [key],
        )).firstOrNull?['value']
        as String?;
  }

  Future<void> setPreference(String key, String value) async {
    await initialize();
    await db.write(
      'INSERT OR REPLACE INTO publication_preferences VALUES(?,?)',
      [key, value],
    );
  }

  Future<List<AcquisitionTask>> tasks() async {
    await initialize();
    return (await db.rows(
      'SELECT * FROM publication_tasks ORDER BY created DESC',
    )).map(_task).toList(growable: false);
  }

  Future<List<AcquisitionTask>> pendingImports() async {
    await initialize();
    final rows = await db.rows(
      "SELECT * FROM publication_tasks WHERE state IN ('downloaded','importing') "
      'AND problem IS NULL ORDER BY created,id',
    );
    return rows.map(_task).toList();
  }

  Future<AcquisitionTask?> task(String id) async {
    await initialize();
    final row = (await db.rows('SELECT * FROM publication_tasks WHERE id=?', [
      id,
    ])).firstOrNull;
    return row == null ? null : _task(row);
  }

  Future<String> addTask(
    PublicationEdition edition,
    List<AcquisitionCandidate> candidates, {
    PublicationFailure? preflightFailure,
  }) async {
    await initialize();
    if (candidates.isEmpty || candidates.length > 32) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return db.atomic(() async {
      final stable = jsonEncode(
        candidates.map((item) => item.toJson()).toList(),
      );
      final encoded = jsonEncode(
        candidates
            .map((item) => item.toJson(includePublishedAccess: true))
            .toList(),
      );
      final previous = await db.rows(
        'SELECT id,candidates FROM publication_tasks WHERE json_extract(edition,\'\$.id\')=? '
        "AND state NOT IN ('complete','failed') ORDER BY created DESC",
        [edition.id],
      );
      for (final task in previous) {
        final saved = jsonDecode(task['candidates'] as String) as List;
        final references = [
          for (final item in saved)
            AcquisitionCandidate.fromJson(item as Map).toJson(),
        ];
        if (jsonEncode(references) == stable) return task['id'] as String;
      }
      final count =
          (await db.rows(
                'SELECT count(*) AS n FROM publication_tasks',
              )).single['n']
              as int;
      if (count >= 100) throw const FormatException('请先整理已结束的图书任务');
      final id = newPublicationId();
      final now = publicationNow();
      final stopped = preflightFailure != null && candidates.length == 1;
      await db.write(
        'INSERT INTO publication_tasks(id,edition,candidates,state,created,selected,failures,problem,retry_at) '
        'VALUES(?,?,?,?,?,?,?,?,?)',
        [
          id,
          jsonEncode(edition.toJson()..remove('candidates')),
          encoded,
          stopped ? 'failed' : 'waiting',
          now,
          preflightFailure != null && !stopped ? 1 : 0,
          _encodeFailures([
            if (preflightFailure != null)
              (
                candidate: 0,
                problem: preflightFailure.problem,
                at: DateTime.fromMillisecondsSinceEpoch(now),
                retryAt: preflightFailure.retryAt,
              ),
          ]),
          stopped ? preflightFailure.problem.name : null,
          stopped ? preflightFailure.retryAt?.millisecondsSinceEpoch : null,
        ],
      );
      return id;
    }, tables: {'publication_tasks'});
  }

  Future<AcquisitionTask?> claim(
    String id,
    String owner, {
    (int, int)? websiteSelection,
  }) async {
    await initialize();
    return db.atomic(() async {
      final count =
          (await db.rows(
                'SELECT count(*) AS n FROM publication_tasks WHERE owner IS NOT NULL',
              )).single['n']
              as int;
      if (count >= 2) return null;
      final requiredSelection = websiteSelection == null
          ? ''
          : " AND state IN ('failed','paused') AND generation=? AND selected=?";
      await db.write(
        'UPDATE publication_tasks SET owner=?,generation=generation+1,state=?,problem=NULL,space_shortfall=NULL '
        "WHERE id=? AND owner IS NULL AND state IN ('waiting','failed','paused') "
        'AND COALESCE(retry_at,0)<=?$requiredSelection',
        [
          owner,
          'resolving',
          id,
          publicationNow(),
          if (websiteSelection case (final generation, final selected)) ...[
            generation,
            selected,
          ],
        ],
      );
      final row = (await db.rows(
        'SELECT * FROM publication_tasks WHERE id=? AND owner=?',
        [id, owner],
      )).firstOrNull;
      return row == null ? null : _task(row);
    }, tables: {'publication_tasks'});
  }

  Future<void> recordCandidateFailures(
    AcquisitionTask task,
    List<CandidateFailure> failures,
  ) => db.write(
    'UPDATE publication_tasks SET failures=? '
    'WHERE id=? AND generation=? AND owner IS NOT NULL',
    [_encodeFailures(failures), task.id, task.generation],
  );

  Future<void> failUnsettledClaim(AcquisitionTask task, String owner) =>
      db.write(
        "UPDATE publication_tasks SET owner=NULL,state='failed',problem=? "
        'WHERE id=? AND generation=? AND owner=?',
        [
          PublicationProblem.taskUpdateFailed.name,
          task.id,
          task.generation,
          owner,
        ],
      );

  Future<void> failUnclaimedTask(String id) => db.write(
    "UPDATE publication_tasks SET state='failed',problem=? "
    "WHERE id=? AND state='waiting' AND problem IS NULL AND owner IS NULL",
    [PublicationProblem.taskUpdateFailed.name, id],
  );

  Future<void> replaceCandidate(
    AcquisitionTask task,
    AcquisitionCandidate candidate,
    Future<void> Function() discardTransfer,
  ) => db.atomic(() async {
    final row = (await db.rows(
      'SELECT owner,state,generation FROM publication_tasks WHERE id=?',
      [task.id],
    )).firstOrNull;
    if (row == null ||
        row['generation'] != task.generation ||
        row['owner'] != null ||
        !const {'failed', 'paused', 'waiting'}.contains(row['state'])) {
      throw const PublicationFailure(PublicationProblem.inUse);
    }
    final candidates = [...task.candidates];
    final key = jsonEncode(candidate.toJson());
    var index = candidates.indexWhere(
      (item) => jsonEncode(item.toJson()) == key,
    );
    if (index < 0) {
      if (candidates.length >= 32) {
        throw const PublicationFailure(PublicationProblem.tooManyCandidates);
      }
      index = candidates.length;
      candidates.add(candidate);
    }
    final sameFile = index == task.selected;
    if (!sameFile) await discardTransfer();
    await db.write(
      "UPDATE publication_tasks SET candidates=?,selected=?,generation=generation+1,state='waiting', "
      'received=?,total=?,problem=NULL,retry_at=NULL,space_shortfall=NULL WHERE id=?',
      [
        jsonEncode([
          for (final item in candidates)
            item.toJson(includePublishedAccess: true),
        ]),
        index,
        sameFile ? task.received : 0,
        sameFile ? task.total : null,
        task.id,
      ],
    );
  }, tables: {'publication_tasks', 'publication_transfer', 'publication_space'});

  Future<void> updateTask(
    AcquisitionTask task,
    AcquisitionState state, {
    int? received,
    int? total,
    int? selected,
    List<CandidateFailure>? failures,
    PublicationFailure? failure,
    String? result,
    bool? retainedArchive,
  }) => db.write(
    'UPDATE publication_tasks SET state=?,received=?,total=?,selected=?,failures=?,problem=?,retry_at=?,result=?, '
    'space_shortfall=?,archive_kept=COALESCE(?,archive_kept), '
    "owner=CASE WHEN ? IN ('resolving','downloading') THEN owner ELSE NULL END "
    'WHERE id=? AND generation=?',
    [
      state.name,
      received ?? task.received,
      total ?? task.total,
      selected ?? task.selected,
      _encodeFailures(failures ?? task.failures),
      failure?.problem.name,
      failure?.retryAt?.millisecondsSinceEpoch,
      result,
      if (failure?.spaceShortfall case final info?)
        jsonEncode([
          info.requiredBytes,
          info.availableBytes,
          info.protectedBytes,
        ])
      else
        null,
      retainedArchive == null ? null : (retainedArchive ? 1 : 0),
      state.name,
      task.id,
      task.generation,
    ],
  );

  String _encodeFailures(List<CandidateFailure> failures) => jsonEncode([
    for (final failure in failures)
      [
        failure.candidate,
        failure.problem.name,
        failure.at.millisecondsSinceEpoch,
        failure.retryAt?.millisecondsSinceEpoch,
      ],
  ]);

  AcquisitionTask _task(Map<String, Object?> row) => AcquisitionTask(
    id: row['id'] as String,
    edition: PublicationEdition.fromJson(
      jsonDecode(row['edition'] as String) as Map,
    ),
    candidates: [
      for (final item in jsonDecode(row['candidates'] as String) as List)
        AcquisitionCandidate.fromJson(
          item as Map,
          includePublishedAccess: true,
        ),
    ],
    state: AcquisitionState.values.byName(row['state'] as String),
    selected: row['selected'] as int,
    total: row['total'] as int?,
    received: row['received'] as int,
    generation: row['generation'] as int,
    failures: [
      for (final entry in jsonDecode(row['failures'] as String) as List)
        (
          candidate: entry[0] as int,
          problem: PublicationProblem.values.byName(entry[1] as String),
          at: DateTime.fromMillisecondsSinceEpoch(entry[2] as int),
          retryAt: entry.length < 4 || entry[3] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(entry[3] as int),
        ),
    ],
    problem: row['problem'] == null
        ? null
        : PublicationProblem.values.byName(row['problem'] as String),
    spaceShortfall: _readSpaceShortfall(row['space_shortfall']),
    retryAt: row['retry_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['retry_at'] as int),
    result: row['result'] as String?,
    retainedArchive: row['archive_kept'] == 1,
  );

  PublicationSpaceShortfall? _readSpaceShortfall(Object? raw) {
    if (raw == null) return null;
    final values = jsonDecode(raw as String) as List;
    return (
      requiredBytes: values[0] as int,
      availableBytes: values[1] as int,
      protectedBytes: values[2] as int,
    );
  }
}
