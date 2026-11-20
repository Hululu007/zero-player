import '../../supervision/application/content_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import '../domain/book.dart';
import 'book_download_evidence.dart';
import 'book_store.dart';

/// Approval follows exact source rules, so later subscription updates revoke it.
final class BookComicAccess {
  BookComicAccess(this.store, this.policy);
  final BookStore store;
  final ContentPolicy policy;
  final Map<String, String> _approved = {};
  Future<void>? _loading;
  bool loaded = false;
  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });
  Future<void> _load() async {
    final raw = await store.read('books_comic_approvals:v1');
    _approved.clear();
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.key is String && entry.value is String) {
          _approved[entry.key as String] = entry.value as String;
        }
      }
    }
    loaded = true;
  }

  bool allowed(BookSource source) =>
      source.kind != BookKind.comic ||
      (source.builtin &&
          source.name.trim() == '新人漫画' &&
          source.endpoint.scheme == 'https' &&
          source.endpoint.host == 'xapi.xinmanhua.net' &&
          source.mediaHosts.every(
            (host) =>
                host == 'works.xinmanhua.net' || host == 'xapi.xinmanhua.net',
          )) ||
      _approved[source.id] == bookDownloadSourceFingerprint(source);

  Future<void> approve(BookSource source) => approveAll([source]);

  Future<void> approveAll(
    Iterable<BookSource> sources, {
    Future<Set<String>> Function()? validateEnablement,
  }) async {
    await load();
    void authorize() {
      if (!policy.supervision.configured) {
        throw const FormatException('请先设置监管密码，再授权其他漫画渠道');
      }
      policy.supervision.require(SensitiveOperation.supervision);
      if (policy.supervision.enabled) {
        throw const ContentBlocked('监管模式开启期间禁止启用漫画渠道');
      }
    }

    authorize();
    await store.db.atomic(() async {
      final ids = await validateEnablement?.call();
      authorize();
      final raw = await store.read('books_comic_approvals:v1');
      final next = {
        if (raw is Map)
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        for (final source in sources)
          source.id: bookDownloadSourceFingerprint(source),
      };
      await store.write('books_comic_approvals:v1', next);
      if (ids != null) await store.setSourcesEnabled(ids, true);
      authorize();
    }, tables: {'app_meta'});
    await _load();
    policy.refresh();
  }
}
