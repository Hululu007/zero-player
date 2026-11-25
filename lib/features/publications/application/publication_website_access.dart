import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/media_http_client.dart';
import '../data/publication_http.dart';
import '../data/publication_share.dart';
import '../data/publication_store.dart';
import '../data/publication_website_markup.dart';
import '../data/publication_website_target.dart';
import '../domain/publication.dart';
import 'publication_discovery.dart';
import 'publication_library.dart';

typedef PublicationWebsiteAccount = ({
  String id,
  String source,
  String origin,
  String name,
});

/// Only account labels are persisted. Each named account gets its own cookie
/// jar for the lifetime of the application. The temporary option owns a jar
/// that is dropped with the panel.
final class PublicationWebsiteAccess {
  PublicationWebsiteAccess(
    this.discovery,
    this.library,
    this.store,
    this.resolver,
  ) {
    _changes = store.db
        .changesFor(const {'publication_source_settings'})
        .listen((_) => unawaited(_recheck().catchError((Object _) {})));
  }

  final PublicationDiscovery discovery;
  final PublicationLibrary library;
  final PublicationStore store;
  final PublicationShareResolver resolver;
  late final StreamSubscription<void> _changes;
  final _active = <PublicationWebsiteSession>{};
  final _accounts =
      <
        String,
        ({PublicationWebsiteTarget target, GuestShareSession cookies})
      >{};
  bool _closed = false;
  int _revision = 0;

  Future<void> check(PublicationWebsiteTarget target) async {
    guard(target, target.address);
    final source = await discovery.enabledSource(target.source.id);
    if (source == null || !source.sameConfiguration(target.source)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    guard(target, target.address);
  }

  void guard(PublicationWebsiteTarget target, Uri uri) {
    if (_closed) throw const PublicationFailure(PublicationProblem.blocked);
    target.restrict(uri);
    library.requireImport(target.titleForPolicy);
    discovery.http.authorize(uri);
  }

  Future<List<PublicationWebsiteAccount>> accounts([
    PublicationWebsiteTarget? target,
  ]) async {
    library.requireImport(target?.titleForPolicy ?? '');
    await store.initialize();
    final rows = await store.db.rows(
      'SELECT id,source,origin,name FROM publication_website_accounts '
      '${target == null ? '' : 'WHERE source=? AND origin=? '}ORDER BY origin,name,id',
      [
        if (target != null) ...[target.source.id, target.origin],
      ],
    );
    library.requireImport(target?.titleForPolicy ?? '');
    final accounts = <PublicationWebsiteAccount>[
      for (final row in rows)
        (
          id: row['id'] as String,
          source: row['source'] as String,
          origin: row['origin'] as String,
          name: row['name'] as String,
        ),
    ];
    return accounts.where(_accountVisible).toList();
  }

  Future<void> addAccount(PublicationWebsiteTarget target, String name) async {
    await check(target);
    await store.initialize();
    final label = _accountLabel(name);
    library.requireImport(label);
    await store.db.atomic(() async {
      final rows = await store.db.rows(
        'SELECT count(*) AS n FROM publication_website_accounts',
      );
      if ((rows.single['n'] as int) >= 32) {
        throw const FormatException('站点账号数量已达上限');
      }
      await check(target);
      store.db.beforeCommit(() => guard(target, target.address));
      await store.db.write(
        'INSERT INTO publication_website_accounts(id,source,origin,name) VALUES(?,?,?,?)',
        [newPublicationId(), target.source.id, target.origin, label],
      );
    }, tables: {'publication_website_accounts'});
  }

  Future<void> renameAccount(
    PublicationWebsiteAccount account,
    String name,
  ) async {
    final label = _accountLabel(name);
    library.requireImport(label);
    discovery.http.authorize(Uri.parse(account.origin));
    await store.initialize();
    await store.db.write(
      'UPDATE publication_website_accounts SET name=? WHERE id=? AND source=? AND origin=?',
      [label, account.id, account.source, account.origin],
    );
  }

  bool _accountVisible(PublicationWebsiteAccount account) {
    try {
      final origin = Uri.parse(account.origin);
      if (!publicationSameWebsite(origin, origin)) return false;
      library.requireImport(account.name);
      discovery.http.authorize(origin);
      return true;
    } on Exception {
      return false;
    }
  }

  Future<void> removeAccount(PublicationWebsiteAccount account) async {
    await store.initialize();
    await store.db.write(
      'DELETE FROM publication_website_accounts WHERE id=? AND source=? AND origin=?',
      [account.id, account.source, account.origin],
    );
    clearAccount(account.id);
  }

  bool hasSession(String account) =>
      _accounts[account]?.cookies.hasCookies == true;

  void clearAccount(String id) {
    _revision++;
    _accounts.remove(id);
    for (final session in _active.toList()) {
      if (session.account == id) session.close();
    }
  }

  Future<PublicationWebsiteSession> open(
    PublicationWebsiteTarget target, {
    String? account,
  }) async {
    final revision = _revision;
    await check(target);
    final task = await store.task(target.task.id);
    if (task == null ||
        task.generation != target.task.generation ||
        task.selected != target.task.selected ||
        PublicationWebsiteTarget.forTask(target.source, task) == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (account != null &&
        !(await accounts(target)).any((item) => item.id == account)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    await check(target);
    if (revision != _revision) throw const RequestCancelled();
    if (_active.any(
      (session) => account != null && session.account == account,
    )) {
      throw const PublicationFailure(PublicationProblem.inUse);
    }
    final previous = _accounts[account];
    if (previous != null &&
        (!target.source.sameConfiguration(previous.target.source) ||
            target.origin != previous.target.origin)) {
      clearAccount(account!);
    }
    final cookies = account == null
        ? GuestShareSession(target.allows)
        : _accounts
              .putIfAbsent(
                account,
                () =>
                    (target: target, cookies: GuestShareSession(target.allows)),
              )
              .cookies;
    final session = PublicationWebsiteSession._(this, target, account, cookies);
    _active.add(session);
    return session;
  }

  Future<void> _recheck() async {
    // Source changes also invalidate retained sessions for closed panels.
    for (final session in _active.toList()) {
      try {
        await check(session.target);
      } on Exception {
        session.close();
      }
    }
    for (final entry in _accounts.entries.toList()) {
      try {
        await check(entry.value.target);
      } on Exception {
        if (_accounts[entry.key] == entry.value) clearAccount(entry.key);
      }
    }
  }

  void revoke() {
    _revision++;
    for (final session in _active.toList()) {
      session.close();
    }
    _accounts.clear();
  }

  Future<void> close() async {
    _closed = true;
    await _changes.cancel();
    revoke();
  }
}

String _accountLabel(String text) {
  final label = publicationWebsiteLabel(text, max: 64);
  if (label.isEmpty) throw const FormatException('请输入账号备注');
  return label;
}

final class PublicationWebsiteSession {
  PublicationWebsiteSession._(
    this._access,
    this.target,
    this.account,
    this._cookies,
  );

  final PublicationWebsiteAccess _access;
  final PublicationWebsiteTarget target;
  final String? account;
  final GuestShareSession _cookies;
  final lifetime = CancellationToken();
  PublicationWebsitePage? _page;
  _WebsiteFileReceipt? _receipt;
  Uri Function(Uri target)? _mapRedirect;
  bool _busy = false;

  PublicationHttp get _http => _access.discovery.http;

  Future<void> check() async {
    lifetime.check();
    await _access.check(target);
    lifetime.check();
  }

  void close() {
    _access._active.remove(this);
    lifetime.cancel();
    _receipt?.discard();
    _receipt = null;
    _page = null;
  }

  Future<PublicationWebsitePage> open() async {
    await check();
    final download = await _access.resolver.resolve(
      target.task.candidate,
      target.source,
      null,
      lifetime,
    );
    _mapRedirect = download.mapRedirect;
    return _visit(download.uri, referer: download.referer);
  }

  Future<PublicationWebsitePage> openBookPage() => _visit(target.address);

  Future<PublicationWebsitePage> follow(PublicationWebsiteLink link) {
    final current = _page;
    if (current == null || !current.links.contains(link)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return _visit(link.uri, referer: current.uri);
  }

  Future<PublicationWebsitePage> submit(
    PublicationWebsiteForm form,
    Map<String, String> values,
  ) async {
    final current = _page;
    if (current == null || !current.forms.contains(form)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final encoded = form.encode(values);
    _page = null;
    return _visit(form.action, referer: current.uri, form: encoded);
  }

  Future<PublicationWebsitePage> _visit(
    Uri uri, {
    Uri? referer,
    Map<String, String>? form,
  }) => _request((token) async {
    _receipt?.discard();
    _receipt = null;
    final payload = await _open(uri, token, referer: referer, form: form);
    final status = payload.response.statusCode;
    final mime = payload.response.headers.contentType?.mimeType ?? '';
    if (publicationWebsiteHtml(mime)) {
      final html = await _http.readText(
        payload,
        token,
        maxBytes: 384 << 10,
        scope: _restrict,
        acceptedStatuses: const {200, 400, 401, 403, 422, 429},
        allowGzip: true,
      );
      return _page = parsePublicationWebsitePage(
        html,
        payload.uri,
        target.allows,
      );
    }

    final type = _fileFormat(payload, mime);
    if (status == HttpStatus.ok &&
        (form == null || payload.uri != uri) &&
        target.format.accepts(type)) {
      if (payload.response.contentLength > target.format.maxBytes ||
          !identityPublicationEncoding(payload)) {
        await discardPublicationResponse(payload);
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      _receipt = _WebsiteFileReceipt(uri, payload, token);
      return _page = PublicationWebsitePage(uri: payload.uri, file: type);
    }
    await discardPublicationResponse(payload);
    if (status != HttpStatus.ok) throw publicationHttpFailure(payload);
    throw const PublicationFailure(PublicationProblem.unsupported);
  });

  Future<Uint8List> captcha(PublicationWebsiteForm form) async {
    final page = _page;
    final uri = form.captcha;
    if (page == null || !page.forms.contains(form) || uri == null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    return _request((token) async {
      final payload = await _open(uri, token, referer: page.uri);
      return _captchaBytes(payload, token, _restrict);
    });
  }

  Future<HttpPayload> _open(
    Uri uri,
    CancellationToken token, {
    Uri? referer,
    Map<String, String>? form,
  }) async {
    final payload = await _http.open(
      uri,
      token,
      scope: _restrict,
      guest: _cookies,
      referer: referer,
      form: form,
      plainForm: form != null,
      interactive: true,
      acceptGzip: true,
      mapRedirect: _mapRedirect,
    );
    // A form can redirect with a GET. Never replay the entered values.
    if (form == null ||
        !const {
          301,
          302,
          303,
          307,
          308,
        }.contains(payload.response.statusCode)) {
      return payload;
    }
    final location = payload.response.headers.value(HttpHeaders.locationHeader);
    await discardPublicationResponse(payload);
    if (location == null ||
        location.length > 2048 ||
        const {307, 308}.contains(payload.response.statusCode)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final raw = payload.uri.resolve(location).removeFragment();
    final destination = _mapRedirect?.call(raw) ?? raw;
    _restrict(destination);
    return _open(destination, token, referer: payload.uri);
  }

  PublicationDownload bind(PublicationDownload original) {
    final receipt = _receipt;
    return _bind(
      original,
      receipt?.matches(original.uri) == true ? receipt : null,
    );
  }

  PublicationDownload _bind(
    PublicationDownload original,
    _WebsiteFileReceipt? receipt,
  ) {
    _restrict(original.uri);
    if (original.guest != null || original.takeResponse != null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    final referer = original.referer;
    return PublicationDownload(
      original.uri,
      referer: referer != null && target.allows(referer)
          ? referer
          : target.address,
      guest: _cookies.freeze(),
      detectGuestQuota: original.detectGuestQuota,
      allowRanges: original.allowRanges,
      mapRedirect: original.mapRedirect,
      takeResponse: receipt?.take,
      scope: (uri) {
        _restrict(uri);
        original.scope?.call(uri);
      },
    );
  }

  void _restrict(Uri uri) {
    lifetime.check();
    _access.guard(target, uri);
  }

  Future<T> _request<T>(Future<T> Function(CancellationToken) work) async {
    lifetime.check();
    if (_busy) throw const PublicationFailure(PublicationProblem.inUse);
    _busy = true;
    try {
      await _access.check(target);
      final result = await withPublicationRequestDeadline(
        lifetime,
        publicationCatalogueDeadline,
        work,
      );
      await _access.check(target);
      lifetime.check();
      return result;
    } finally {
      _busy = false;
    }
  }
}

/// Downloads that have already returned headers are consumed once. Sending
/// the request again could spend the visitor's remaining quota or reuse a
/// single-use link. The receipt is never persisted in the task.
final class _WebsiteFileReceipt {
  _WebsiteFileReceipt(this.request, this._payload, this._requestToken) {
    _timer = Timer(const Duration(seconds: 45), discard);
  }
  final Uri request;
  final HttpPayload _payload;
  final CancellationToken _requestToken;
  late final Timer _timer;
  bool _unavailable = false;

  bool matches(Uri uri) => request == uri || _payload.uri == uri;

  HttpPayload take(CancellationToken token) {
    token.check();
    if (_unavailable) {
      throw const PublicationFailure(PublicationProblem.timeout);
    }
    _unavailable = true;
    _timer.cancel();
    token.listen(_requestToken.cancel);
    return _payload;
  }

  void discard() {
    if (_unavailable) return;
    _unavailable = true;
    _timer.cancel();
    _requestToken.cancel();
    unawaited(discardPublicationResponse(_payload).catchError((Object _) {}));
  }
}

PublicationFormat? _fileFormat(HttpPayload payload, String mime) {
  final declared = PublicationFormat.values
      .where((format) => format.mimeType == mime)
      .firstOrNull;
  if (declared != null) return declared;
  if (mime != 'application/octet-stream') return null;
  final disposition =
      payload.response.headers.value('content-disposition') ?? '';
  final name = RegExp(
    r'(?:^|;)\s*filename\s*=\s*(?:"([^"]+)"|([^;\s]+))',
    caseSensitive: false,
  ).firstMatch(disposition);
  return PublicationFormat.fromName(name?[1] ?? name?[2] ?? payload.uri.path);
}

Future<Uint8List> _captchaBytes(
  HttpPayload payload,
  CancellationToken token,
  void Function(Uri) restrict,
) async {
  const limit = 128 << 10;
  final response = payload.response;
  final mime = response.headers.contentType?.mimeType;
  if (response.statusCode != HttpStatus.ok ||
      !const {'image/png', 'image/jpeg'}.contains(mime) ||
      !identityPublicationEncoding(payload) ||
      response.contentLength > limit) {
    await discardPublicationResponse(payload);
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in payload.body) {
    token.check();
    restrict(payload.uri);
    if (bytes.length + chunk.length > limit) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    bytes.add(chunk);
  }
  final image = bytes.takeBytes();
  final png = mime == 'image/png';
  final magic = png
      ? const [137, 80, 78, 71, 13, 10, 26, 10]
      : const [255, 216, 255];
  if (image.length < 12 ||
      !magic.indexed.every((entry) => image[entry.$1] == entry.$2)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(image);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > 1024 ||
          descriptor.height > 512) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return image;
}
