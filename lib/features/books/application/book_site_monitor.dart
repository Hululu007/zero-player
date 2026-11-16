import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/cancellation_token.dart';
import '../../settings/application/settings_controller.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';
import 'book_site_checks.dart';

/// Runs only while the app process is alive, not as an OS background service.
final class BookSiteMonitor {
  BookSiteMonitor(
    this.checks,
    this.settings, {
    this.startDelay = const Duration(seconds: 30),
    this.interval = const Duration(minutes: 30),
  }) {
    checks.books.sourceConfigurationChanges.addListener(_sourceRiskChanged);
  }
  final BookSiteChecks checks;
  final SettingsController settings;
  final Duration startDelay, interval;
  Timer? _initial, _periodic;
  CancellationToken? _token;
  Future<void>? _pending;
  int? _configurationAtStart;
  bool _started = false, _closed = false;
  int _manualOperations = 0;
  final _manualTokens = <CancellationToken>{};
  final _manualDone = <Completer<void>>{};
  late String _policySnapshot;

  bool get _allowed =>
      !_closed &&
      _manualOperations == 0 &&
      !checks.books.sourceRisksSuspended &&
      !checks.books.sourceConfigurationChanging &&
      settings.value.backgroundProbe &&
      !checks.books.policy.supervision.corrupted;

  void start() {
    if (_started || _closed) return;
    _started = true;
    unawaited(
      checks.books.ensureSiteObservations().catchError((
        Object error,
        StackTrace stack,
      ) {
        if (error is! RequestCancelled) {
          debugPrint('书源抽查版本初始化未完成: ${error.runtimeType}');
        }
      }),
    );
    _policySnapshot = bookSitePolicySnapshot(checks.books.policy);
    settings.addListener(_policyChanged);
    checks.books.policy.addListener(_policyChanged);
    _initial = Timer(startDelay, () => unawaited(check()));
    _periodic = Timer.periodic(interval, (_) => unawaited(check()));
  }

  void _policyChanged() {
    final next = bookSitePolicySnapshot(checks.books.policy);
    if (next != _policySnapshot || !_allowed) _token?.cancel();
    _policySnapshot = next;
  }

  void _sourceRiskChanged() {
    if (checks.books.sourceRisksSuspended ||
        (_configurationAtStart != null &&
            _configurationAtStart !=
                checks.books.sourceConfigurationRevision)) {
      _token?.cancel();
    }
    if (checks.books.sourceRisksSuspended) {
      for (final token in _manualTokens.toList()) {
        token.cancel();
      }
    }
  }

  Future<void> check() {
    if (!_allowed) return Future.value();
    return _pending ??= _run()
        .catchError((Object error, StackTrace stack) {
          if (error is! RequestCancelled) {
            debugPrint('书源网页后台抽查未完成: ${error.runtimeType}');
          }
        })
        .whenComplete(() => _pending = null);
  }

  Future<void> _run() async {
    final token = _token = CancellationToken();
    _configurationAtStart = checks.books.sourceConfigurationRevision;
    try {
      if (checks.books.policy.supervision.enabled) {
        await checks.books.checkSupervisedBuiltinSites(token);
        return;
      }
      final entries = [
        for (final kind in BookKind.values)
          ...await checks.books.sources(kind, enabledOnly: true),
      ];
      token.check();
      if (!_allowed) return;
      final saved = await checks.load(entries);
      token.check();
      if (!_allowed) return;
      final now = DateTime.now();
      final due =
          entries.where((entry) {
            final check = saved[entry.source.id];
            return check == null || check.isDue(now);
          }).toList()..sort(
            (a, b) => (saved[a.source.id]?.nextDue.millisecondsSinceEpoch ?? 0)
                .compareTo(
                  saved[b.source.id]?.nextDue.millisecondsSinceEpoch ?? 0,
                ),
          );
      await checks.run(due.take(20).toList(), token, enabledOnly: true);
    } finally {
      if (identical(_token, token)) {
        _token = null;
        _configurationAtStart = null;
      }
    }
  }

  /// Manual checks take priority and wait for any background I/O to stop.
  Future<void> cancelCurrent() async {
    _token?.cancel();
    await _pending;
  }

  Future<T> whileManual<T>(
    CancellationToken token,
    Future<T> Function() action,
  ) async {
    if (_closed) throw const FormatException('应用正在退出');
    if (checks.books.sourceRisksSuspended) {
      throw const FormatException('书源策略正在恢复，请稍后重试');
    }
    if (_manualOperations != 0) throw const FormatException('书源网页抽查正在进行，请稍后再试');
    _manualOperations++;
    _manualTokens.add(token);
    final done = Completer<void>();
    _manualDone.add(done);
    try {
      await cancelCurrent();
      if (_closed) throw const FormatException('应用正在退出');
      token.check();
      return await action();
    } finally {
      _manualOperations--;
      _manualTokens.remove(token);
      _manualDone.remove(done);
      done.complete();
    }
  }

  Future<void> close() async {
    _closed = true;
    _initial?.cancel();
    _periodic?.cancel();
    if (_started) {
      settings.removeListener(_policyChanged);
      checks.books.policy.removeListener(_policyChanged);
    }
    checks.books.sourceConfigurationChanges.removeListener(_sourceRiskChanged);
    for (final token in _manualTokens.toList()) {
      token.cancel();
    }
    await cancelCurrent();
    await Future.wait(_manualDone.map((done) => done.future).toList());
  }
}
