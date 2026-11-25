import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/network/cancellation_token.dart';
import '../data/publication_http.dart';
import '../data/publication_share.dart';
import '../data/publication_share_provider.dart';
import '../data/publication_sources.dart';
import '../data/publication_store.dart';
import '../data/publication_transfer.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_discovery.dart';

typedef _BoundShareAccess = ({
  String? code,
  String? baiduAccessToken,
  String candidate,
});
typedef WebsiteDownloadResolver =
    Future<PublicationDownload> Function(
      AcquisitionCandidate candidate,
      PublicationSource? source,
      CancellationToken token,
    );
typedef _WebsiteRetry = ({
  (int, int) selection,
  WebsiteDownloadResolver resolve,
});

/// The same acquisition runner is hosted by Windows or the Android download
/// engine. A task is claimed in SQLite before opening its partial file.
final class PublicationAcquisitions {
  PublicationAcquisitions(
    this.store,
    this.discovery,
    this.resolver,
    this.transfer,
    this.authorize, {
    this.reloadPolicy,
    this.checkDownload,
    this.activity,
  });
  final PublicationStore store;
  final PublicationDiscovery discovery;
  final PublicationShareResolver resolver;
  final PublicationTransfer transfer;
  final void Function(String) authorize;
  final Future<void> Function()? reloadPolicy;
  final Future<void> Function()? checkDownload;
  final void Function()? activity;
  final _owner = '$pid:${newPublicationId()}';
  final _pending = <String, _BoundShareAccess?>{};
  final _active = <String, (CancellationToken, Future<void>)>{};
  bool _closing = false;
  PublicationProblem? _cancelReason;

  Future<void> recover({bool oldHostOnly = true}) async {
    await store.initialize();
    await store.db.write(
      'UPDATE publication_tasks SET owner=NULL,state=\'paused\' '
      'WHERE owner IS NOT NULL${oldHostOnly ? " AND owner NOT LIKE ?" : ""}',
      [if (oldHostOnly) '$pid:%'],
    );
  }

  void start(
    String id, {
    String? code,
    String? codeFor,
    String? baiduAccessToken,
  }) {
    if (_closing || _active.containsKey(id) || _pending.containsKey(id)) return;
    _pending[id] = codeFor == null || (code == null && baiduAccessToken == null)
        ? null
        : (code: code, baiduAccessToken: baiduAccessToken, candidate: codeFor);
    if (_active.isEmpty) _cancelReason = null;
    _pump();
  }

  void _pump() {
    while (!_closing && _active.length < 2 && _pending.isNotEmpty) {
      final next = _pending.entries.first;
      final id = next.key;
      final access = next.value;
      _pending.remove(id);
      final token = CancellationToken();
      final future = _run(id, access, token).whenComplete(() {
        _active.remove(id);
        _pump();
        activity?.call();
      });
      _active[id] = (token, future);
      unawaited(future.catchError((Object _, StackTrace _) {}));
    }
  }

  bool get busy => _active.isNotEmpty || _pending.isNotEmpty;

  Future<void> resumeWebsite(
    AcquisitionTask task,
    CancellationToken parent,
    WebsiteDownloadResolver resolve,
  ) async {
    parent.check();
    if (_closing ||
        _active.length >= 2 ||
        _active.containsKey(task.id) ||
        _pending.containsKey(task.id)) {
      throw const PublicationFailure(PublicationProblem.downloadSlotsBusy);
    }
    if (_active.isEmpty) _cancelReason = null;
    final token = CancellationToken();
    final detach = parent.listen(token.cancel);
    final future = _run(
      task.id,
      null,
      token,
      website: (selection: (task.generation, task.selected), resolve: resolve),
    );
    _active[task.id] = (token, future);
    try {
      await future;
      parent.check();
    } finally {
      detach();
      _active.remove(task.id);
      _pump();
      activity?.call();
    }
  }

  Future<void> pause(String id, {int? generation}) async {
    final task = await store.task(id);
    if (task == null || (generation != null && task.generation != generation)) {
      return;
    }
    _pending.remove(id);
    final running = _active[id];
    if (running != null) {
      running.$1.cancel();
      await running.$2;
    }
    await store.db.write(
      "UPDATE publication_tasks SET state='paused' "
      "WHERE id=? AND generation=? AND state='waiting' AND owner IS NULL AND problem IS NULL",
      [id, task.generation],
    );
  }

  void cancelRunning({PublicationProblem? reason}) {
    _cancelReason = reason ?? _cancelReason;
    _pending.clear();
    for (final running in _active.values) {
      running.$1.cancel();
    }
  }

  Future<void> close() async {
    _closing = true;
    cancelRunning();
    await Future.wait(_active.values.map((item) => item.$2));
  }

  Future<void> _run(
    String id,
    _BoundShareAccess? access,
    CancellationToken token, {
    _WebsiteRetry? website,
  }) async {
    final AcquisitionTask? claimed;
    try {
      claimed = await store.claim(
        id,
        _owner,
        websiteSelection: website?.selection,
      );
    } catch (_) {
      if (website == null) await store.failUnclaimedTask(id);
      rethrow;
    }
    if (claimed == null) {
      if (website != null) {
        throw const PublicationFailure(PublicationProblem.inUse);
      }
      return;
    }
    final task = claimed;
    final failures = [...task.failures];
    final cooldowns = _savedCooldowns(task);
    var index = task.selected;
    var received = task.received;
    int? total = task.total;
    var settled = false;
    try {
      for (; index < task.candidates.length; index++) {
        final candidate = task.candidates[index];
        final group = _requestGroup(candidate.link);
        try {
          await _beginCandidate(task, index, failures, cooldowns[group]);
          var progressSeen = false;
          received = await _acquireCandidate(
            task,
            candidate,
            access?.candidate == candidate.id ? access : null,
            token,
            (count, length) async {
              if (progressSeen &&
                  count < received &&
                  received <= (length ?? count) &&
                  count != 0 &&
                  length == total) {
                return;
              }
              progressSeen = true;
              received = count;
              total = length;
              await store.updateTask(
                task,
                AcquisitionState.downloading,
                selected: index,
                received: received,
                total: total,
                failures: failures,
              );
              activity?.call();
            },
            website: website?.resolve,
          );
          await store.updateTask(
            task,
            AcquisitionState.downloaded,
            selected: index,
            received: received,
            total: received,
            failures: failures,
          );
          settled = true;
          return;
        } catch (error) {
          if (error is RequestCancelled) rethrow;
          final failure = classify(error);
          if (failure.retryAt != null) {
            cooldowns[group] = PublicationFailure(
              PublicationProblem.rateLimit,
              retryAt: failure.retryAt,
            );
          }
          if (failure.problem != PublicationProblem.space) {
            failures.add((
              candidate: index,
              problem: failure.problem,
              at: DateTime.now(),
              retryAt: failure.retryAt,
            ));
          }
          if (website != null ||
              index + 1 == task.candidates.length ||
              _endsAcquisition(failure.problem)) {
            await store.updateTask(
              task,
              _failureState(failure.problem, received),
              selected: index,
              received: received,
              total: total,
              failures: failures,
              failure: failure,
            );
            settled = true;
            return;
          }
          await _prepareFallback(task, failures);
          received = 0;
          total = null;
        }
      }
    } on RequestCancelled {
      final reason = _cancelReason;
      await store.updateTask(
        task,
        AcquisitionState.paused,
        selected: index,
        received: received,
        total: total,
        failures: failures,
        failure: reason == null ? null : PublicationFailure(reason),
      );
      settled = true;
    } finally {
      if (!settled) await store.failUnsettledClaim(task, _owner);
    }
  }

  Map<Object, PublicationFailure> _savedCooldowns(AcquisitionTask task) {
    final cooldowns = <Object, PublicationFailure>{};
    final now = DateTime.now();
    for (final failure in task.failures) {
      final retryAt = failure.retryAt;
      if (retryAt == null || !retryAt.isAfter(now)) {
        continue;
      }
      final group = _requestGroup(task.candidates[failure.candidate].link);
      if (retryAt.isAfter(cooldowns[group]?.retryAt ?? now)) {
        cooldowns[group] = PublicationFailure(
          PublicationProblem.rateLimit,
          retryAt: retryAt,
        );
      }
    }
    return cooldowns;
  }

  Future<void> _beginCandidate(
    AcquisitionTask task,
    int index,
    List<CandidateFailure> failures,
    PublicationFailure? cooldown,
  ) async {
    if (cooldown != null && cooldown.retryAt?.isAfter(DateTime.now()) == true) {
      throw cooldown;
    }
    await store.updateTask(
      task,
      AcquisitionState.resolving,
      selected: index,
      failures: failures,
    );
  }

  bool _endsAcquisition(PublicationProblem problem) => const {
    PublicationProblem.blocked,
    PublicationProblem.space,
    PublicationProblem.storage,
    PublicationProblem.metered,
  }.contains(problem);

  AcquisitionState _failureState(PublicationProblem problem, int received) =>
      switch (problem) {
        PublicationProblem.space when received == 0 => AcquisitionState.waiting,
        PublicationProblem.space => AcquisitionState.paused,
        PublicationProblem.metered => AcquisitionState.paused,
        _ => AcquisitionState.failed,
      };

  Object _requestGroup(Uri link) {
    final provider = PublicationShareProvider.of(link);
    return provider == PublicationShareProvider.direct ? link.origin : provider;
  }

  Future<void> _prepareFallback(
    AcquisitionTask task,
    List<CandidateFailure> failures,
  ) async {
    await store.recordCandidateFailures(task, failures);
    await transfer.space.removeTemporaries(task.id);
    await store.db.write('DELETE FROM publication_transfer WHERE task=?', [
      task.id,
    ]);
  }

  Future<int> _acquireCandidate(
    AcquisitionTask task,
    AcquisitionCandidate candidate,
    _BoundShareAccess? access,
    CancellationToken token,
    TransferProgress progress, {
    WebsiteDownloadResolver? website,
  }) async {
    final text =
        '${task.edition.title} ${task.edition.author} ${candidate.link.host}';
    void check() {
      token.check();
      authorize(text);
    }

    Future<PublicationSource?> currentSource() async {
      await reloadPolicy?.call();
      check();
      await checkDownload?.call();
      check();
      if (candidate.source == 'manual') return null;
      final source = await discovery.enabledSource(candidate.source);
      if (source == null) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      return source;
    }

    final source = await currentSource();
    final spec = source?.configurable == true
        ? jsonEncode(source!.toSpec())
        : null;
    Future<void> reauthorize() async {
      final current = await currentSource();
      if (spec != null && jsonEncode(current?.toSpec()) != spec) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
    }

    final previous = task.failures.lastOrNull;
    final limited =
        previous?.problem == PublicationProblem.rateLimit &&
        previous?.candidate == task.selected &&
        candidate.id == task.candidate.id;
    final path = await _download(
      task.id,
      candidate,
      source,
      access?.code ?? candidate.publishedAccess?.code,
      token,
      check,
      (count, length) async {
        // The UI and the worker both honor source and policy changes.
        await reauthorize();
        await progress(count, length);
      },
      allowRanges: website == null && !limited,
      website: website,
      baiduAccessToken: access?.baiduAccessToken,
    );
    await reauthorize();
    return path.length();
  }

  Future<File> _download(
    String id,
    AcquisitionCandidate candidate,
    PublicationSource? source,
    String? code,
    CancellationToken token,
    void Function() check,
    TransferProgress progress, {
    required bool allowRanges,
    WebsiteDownloadResolver? website,
    String? baiduAccessToken,
  }) async {
    for (var attempt = 0; ; attempt++) {
      PublicationDownload? resolved;
      try {
        resolved = await (website == null
            ? resolver.resolve(
                candidate,
                source,
                code,
                token,
                baiduAccessToken: baiduAccessToken,
              )
            : website(candidate, source, token));
        return await transfer.download(
          id,
          candidate,
          resolved,
          token,
          progress,
          check,
          allowRanges: allowRanges && resolved.allowRanges,
        );
      } catch (error) {
        final refresh =
            website == null &&
            resolved?.guest != null &&
            error is PublicationFailure &&
            const {
              PublicationProblem.login,
              PublicationProblem.missing,
            }.contains(error.problem);
        final transient =
            error is TimeoutException ||
            error is SocketException ||
            (error is PublicationFailure &&
                const {
                  PublicationProblem.network,
                  PublicationProblem.timeout,
                }.contains(error.problem));
        if (website != null || attempt > 0 || (!refresh && !transient)) {
          rethrow;
        }
        if (transient) {
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }
        // A fresh resolution binds the new session to its own URL. Range
        // checkpoints still require the new probe to prove file identity.
        check();
      }
    }
  }

  PublicationFailure classify(Object error) => switch (error) {
    PublicationFailure(problem: PublicationProblem.rateLimit, retryAt: null) =>
      PublicationFailure(
        PublicationProblem.rateLimit,
        retryAt: DateTime.now().add(const Duration(seconds: 30)),
      ),
    PublicationFailure value => value,
    TimeoutException() => const PublicationFailure(PublicationProblem.timeout),
    FormatException() ||
    TypeError() => const PublicationFailure(PublicationProblem.invalid),
    FileSystemException() => const PublicationFailure(
      PublicationProblem.storage,
    ),
    _ => const PublicationFailure(PublicationProblem.network),
  };
}
