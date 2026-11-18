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
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final raw = await store.read('books_comic_approvals:v1');
    if (raw is Map) _approved.addAll(Map<String, String>.from(raw));
    loaded = true;
  }

  bool allowed(BookSource source) =>
      source.kind != BookKind.comic ||
      (source.name.trim() == '新人漫画' &&
          source.endpoint.scheme == 'https' &&
          source.endpoint.host == 'xapi.xinmanhua.net' &&
          source.mediaHosts.every(
            (host) =>
                host == 'works.xinmanhua.net' || host == 'xapi.xinmanhua.net',
          )) ||
      _approved[source.id] == bookDownloadSourceFingerprint(source);

  Future<void> approve(BookSource source) async {
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
    final next = {
      ..._approved,
      source.id: bookDownloadSourceFingerprint(source),
    };
    await store.db.atomic(() async {
      authorize();
      await store.write('books_comic_approvals:v1', next);
      authorize();
    }, tables: {'app_meta'});
    _approved
      ..clear()
      ..addAll(next);
    policy.refresh();
  }
}
