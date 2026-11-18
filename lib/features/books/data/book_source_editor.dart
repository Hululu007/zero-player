import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import '../domain/book_source_risk.dart';
import 'book_source_import_plan.dart' show bookSourceBlacklistAlias;
import 'book_source_risk_store.dart';
import 'book_store.dart';

/// Executes source configuration transactions. The repository owns mutation
/// leases, snapshot invalidation and publication after a successful commit.
final class BookSourceEditor {
  const BookSourceEditor({
    required this.store,
    required this.risks,
    required this.policy,
    required this.sourceAllowed,
    required this.comicAllowed,
  });

  final BookStore store;
  final BookSourceRiskStore risks;
  final ContentPolicy policy;
  final bool Function(BookSource) sourceAllowed;
  final bool Function(BookSource) comicAllowed;

  static bool changesConfiguration(Map<String, Object?> updates) =>
      updates.keys.any(
        (key) => const {'group', 'source', 'removed', 'enabled'}.contains(key),
      );

  void _requireAccess() =>
      policy.supervision.require(SensitiveOperation.channels);

  void _requireSource(BookSource source) {
    _requireAccess();
    if (!sourceAllowed(source)) throw const ContentBlocked();
  }

  void _requireComic(BookSource source, bool enabling) {
    if (enabling && !comicAllowed(source)) {
      throw const ContentBlocked('请先验证监管密码授权此漫画渠道');
    }
  }

  Future<BookSourceAssessment?> _retainAdult(BookSourceEntry? current) async {
    if (current == null ||
        !(adultBookSource(current.source) ||
            adultBookLabels(current.source.name, current.group))) {
      return null;
    }
    return risks.addEvidence(
      current.source,
      adult: true,
      quarantine: false,
      rootPageEvidence: false,
    );
  }

  Future<BookSourceAssessment?> save(
    BookSource source,
    Map<String, Object?> updates, {
    BookSource? builtin,
    void Function()? validate,
  }) async {
    validate?.call();
    _requireSource(source);
    _requireComic(source, updates['enabled'] == true);
    return store.db.atomic(() async {
      validate?.call();
      _requireAccess();
      if ((await store.blockedSources()).containsKey(source.id)) {
        throw const ContentBlocked();
      }
      _requireSource(source);
      final retained = updates.containsKey('group')
          ? await _retainAdult(await store.source(builtin, source.id))
          : null;
      _requireSource(source);
      _requireComic(source, updates['enabled'] == true);
      await store.saveSource(source, updates);
      _requireAccess();
      validate?.call();
      return retained;
    }, tables: {'app_meta'});
  }

  Future<BookSourceAssessment?> remove(
    BookSource source, {
    BookSource? builtin,
  }) async {
    _requireSource(source);
    return store.db.atomic(() async {
      _requireAccess();
      final current = await store.source(builtin, source.id);
      _requireSource(current?.source ?? source);
      final retained = await _retainAdult(current);
      _requireSource(current?.source ?? source);
      await store.deleteSource(source);
      _requireAccess();
      return retained;
    }, tables: {'app_meta'});
  }

  Future<void> restoreDefaults(BookKind kind, List<BookSource> builtins) =>
      store.db.atomic(() async {
        _requireAccess();
        final blocked = await store.blockedSources();
        final existing = await store.sources(builtins);
        for (final entry in existing.where((e) => e.source.kind == kind)) {
          _requireAccess();
          await store.saveSource(entry.source, {'enabled': false});
        }
        for (final source in builtins.where((s) => s.kind == kind)) {
          _requireAccess();
          if (!source.defaultEnabled ||
              blocked.containsKey(source.id) ||
              !sourceAllowed(source)) {
            continue;
          }
          _requireAccess();
          await store.restoreBuiltinSource(source);
        }
        _requireAccess();
      }, tables: {'app_meta'});

  Future<bool> setEnabled(
    Future<List<BookSourceEntry>> Function() visibleEntries,
    Set<String> ids,
    bool enabled,
  ) async {
    _requireAccess();
    return store.db.atomic(() async {
      final eligible = (await visibleEntries()).where(
        (entry) => ids.contains(entry.source.id) && entry.enabled != enabled,
      );
      _requireAccess();
      if (enabled && eligible.any((entry) => !comicAllowed(entry.source))) {
        throw const ContentBlocked('部分漫画渠道尚未通过监管授权，请先逐个验证');
      }
      final eligibleIds = eligible.map((entry) => entry.source.id).toSet();
      if (eligibleIds.isEmpty) return false;
      await store.setSourcesEnabled(eligibleIds, enabled);
      _requireAccess();
      return true;
    }, tables: {'app_meta'});
  }

  Future<void> block(BookSource source) => store.db.atomic(() async {
    _requireSource(source);
    final blocked = await store.blockedSources();
    _requireSource(source);
    await store.write('books_source_blacklist', {
      ...blocked,
      source.id: '${source.name} · ${source.endpoint.host}',
    });
    final aliases = await store.read('books_source_blacklist_aliases');
    _requireAccess();
    await store.write('books_source_blacklist_aliases', {
      if (aliases is Map) ...aliases,
      bookSourceBlacklistAlias(source): source.id,
    });
    _requireAccess();
    await store.saveSource(source, {'enabled': false});
    _requireAccess();
  }, tables: {'app_meta'});

  Future<void> unblock(String id) => store.db.atomic(() async {
    _requireAccess();
    final blocked = await store.blockedSources()
      ..remove(id);
    _requireAccess();
    await store.write('books_source_blacklist', blocked);
    final aliases = await store.read('books_source_blacklist_aliases');
    _requireAccess();
    if (aliases is Map) {
      await store.write(
        'books_source_blacklist_aliases',
        {...aliases}..removeWhere((_, sourceId) => sourceId == id),
      );
    }
    _requireAccess();
  }, tables: {'app_meta'});
}
