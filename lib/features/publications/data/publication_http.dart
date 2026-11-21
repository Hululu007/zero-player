import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/network/media_http_client.dart';
import '../../../core/network/network_target_policy.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/publication.dart';

bool hostIn(Uri uri, String domain) =>
    uri.host == domain || uri.host.endsWith('.$domain');

void validatePublicationAddress(Uri uri, {bool allowLoopback = false}) {
  NetworkTargetPolicy.validateUri(uri);
  if (uri.toString().length > 8192 ||
      (!allowLoopback &&
          (uri.host == 'localhost' ||
              InternetAddress.tryParse(uri.host) != null))) {
    throw const PublicationFailure(PublicationProblem.unsupported);
  }
}

typedef PublicationRequestGuard = void Function(Uri target);

final class PublicationDownload {
  const PublicationDownload(this.uri, {this.scope, this.guest, this.referer});
  final Uri uri;
  final PublicationRequestGuard? scope;
  final GuestShareSession? guest;
  final Uri? referer;
}

PublicationDownload bindPublicationGuest(
  Uri address,
  Uri referer,
  String cookieDomain,
  List<Cookie> cookies,
) {
  bool belongsToDownload(Uri target) => target.origin == address.origin;
  final session = GuestShareSession(belongsToDownload);
  session.receive(address, [
    for (final cookie in cookies)
      if (cookie.name == '__pugs' &&
          (cookie.domain == cookieDomain ||
              cookie.domain == '.$cookieDomain') &&
          RegExp(r'^[^\x00-\x20\x7f;,]+$').hasMatch(cookie.value))
        cookie,
  ]);
  if (session.forAddress(address) == null) {
    throw const PublicationFailure(PublicationProblem.login);
  }
  return PublicationDownload(
    address,
    referer: referer,
    guest: session.freeze(),
    scope: (target) {
      if (!belongsToDownload(target)) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    },
  );
}

final class PublicationHttp {
  PublicationHttp(
    this.transport, {
    required this.authorize,
    this.allowLoopback = false,
  });
  final MediaHttpClient transport;
  final PublicationRequestGuard authorize;
  final bool allowLoopback;

  Future<HttpPayload> open(
    Uri address,
    CancellationToken token, {
    PublicationRequestGuard? scope,
    GuestShareSession? guest,
    Uri? referer,
    Map<String, String>? form,
    Map<String, Object?>? json,
    String? range,
    String? ifRange,
    bool redirect = true,
    bool interactive = false,
  }) async {
    assert(form == null || json == null);
    final body = switch ((form, json)) {
      (final fields?, _) => utf8.encode(Uri(queryParameters: fields).query),
      (_, final fields?) => utf8.encode(jsonEncode(fields)),
      _ => null,
    };
    final origin = HeaderPolicy.origin(address);
    var target = address.removeFragment();
    for (var i = 0; i <= 5; i++) {
      token.check();
      validatePublicationAddress(target, allowLoopback: allowLoopback);
      authorize(target);
      scope?.call(target);
      final sameOrigin = HeaderPolicy.origin(target) == origin;
      final cookie = guest?.forAddress(target);
      final response = await transport.open(
        target,
        policy: HeaderPolicy({
          target: {
            if (referer != null) ...HeaderPolicy.publicReferer(referer, target),
            'Cookie': ?cookie,
            if (form != null)
              'Content-Type': 'application/x-www-form-urlencoded',
            if (json != null) 'Content-Type': 'application/json',
            if (body != null && referer != null) 'Origin': referer.origin,
            if (form != null) 'X-Requested-With': 'XMLHttpRequest',
          },
        }),
        method: body == null ? 'GET' : 'POST',
        body: body,
        range: range,
        ifRange: sameOrigin ? ifRange : null,
        followRedirects: false,
        priority: interactive
            ? RequestPriority.interactive
            : RequestPriority.background,
        cancellation: token,
      );
      try {
        token.check();
        authorize(target);
        scope?.call(target);
        guest?.receive(target, response.response.cookies);
        if (!redirect ||
            body != null ||
            !const {
              301,
              302,
              303,
              307,
              308,
            }.contains(response.response.statusCode)) {
          return response;
        }
        final location = response.response.headers.value('location');
        if (location == null || location.length > 8192) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        final next = target.resolve(location).removeFragment();
        if (target.scheme == 'https' && next.scheme != 'https') {
          throw const PublicationFailure(PublicationProblem.unsupported);
        }
        target = next;
      } catch (_) {
        await discardPublicationResponse(response);
        rethrow;
      }
      await discardPublicationResponse(response);
    }
    throw const PublicationFailure(PublicationProblem.invalid);
  }

  Future<String> text(
    Uri address,
    CancellationToken token, {
    int maxBytes = 2 << 20,
    PublicationRequestGuard? scope,
    GuestShareSession? guest,
    Uri? referer,
    Map<String, String>? form,
  }) async {
    final response = await open(
      address,
      token,
      scope: scope,
      guest: guest,
      referer: referer,
      form: form,
      interactive: true,
    );
    return readText(response, token, maxBytes: maxBytes, scope: scope);
  }

  Future<String> readText(
    HttpPayload response,
    CancellationToken token, {
    required int maxBytes,
    PublicationRequestGuard? scope,
    Set<int> acceptedStatuses = const {HttpStatus.ok},
  }) async {
    final accepted = acceptedStatuses.contains(response.response.statusCode);
    if (!accepted ||
        response.response.contentLength > maxBytes ||
        !identityPublicationEncoding(response)) {
      await discardPublicationResponse(response);
      if (!accepted) throw publicationHttpFailure(response);
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    var length = 0;
    return utf8.decoder
        .bind(
          response.body.map((chunk) {
            token.check();
            authorize(response.uri);
            scope?.call(response.uri);
            length += chunk.length;
            if (length > maxBytes) {
              throw const PublicationFailure(PublicationProblem.invalid);
            }
            return chunk;
          }),
        )
        .join();
  }
}

Future<void> discardPublicationResponse(HttpPayload payload) async {
  final subscription = payload.body.listen((_) {}, onError: (Object _) {});
  await subscription.cancel();
}

bool identityPublicationEncoding(HttpPayload payload) {
  final value = payload.response.headers.value('content-encoding');
  return value == null || value.trim().toLowerCase() == 'identity';
}

PublicationFailure publicationHttpFailure(HttpPayload payload) {
  final code = payload.response.statusCode;
  if (code == 429 || code == 503) {
    return PublicationFailure(
      PublicationProblem.rateLimit,
      retryAt: _retryAt(payload.response.headers.value('retry-after')),
    );
  }
  return PublicationFailure(switch (code) {
    401 => PublicationProblem.login,
    403 => PublicationProblem.challenge,
    404 || 410 => PublicationProblem.missing,
    200 || 206 || 416 => PublicationProblem.invalid,
    _ => PublicationProblem.network,
  });
}

DateTime _retryAt(String? value) {
  final now = DateTime.now();
  if (value != null) {
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0 && seconds <= 31536000) {
      return now.add(Duration(seconds: seconds));
    }
    try {
      final date = HttpDate.parse(value);
      if (date.isAfter(now)) return date;
    } on HttpException {
      // A malformed header uses the ordinary backoff.
    }
  }
  return now.add(const Duration(seconds: 30));
}

/// One share inspection owns this jar. Session cookies are deliberately host
/// only, including cookies whose Domain would normally cover sibling hosts.
final class GuestShareSession {
  GuestShareSession(this.permittedHost);
  final bool Function(Uri) permittedHost;
  final _values = <(String, String, String), (Cookie, DateTime?)>{};
  bool _sealed = false;

  GuestShareSession freeze() => GuestShareSession(permittedHost)
    .._values.addAll(_values)
    .._sealed = true;

  void receive(Uri origin, List<Cookie> cookies) {
    if (_sealed || !permittedHost(origin)) return;
    final now = DateTime.now();
    for (final cookie in cookies.take(32)) {
      var domain = cookie.domain?.toLowerCase();
      if (domain != null && domain.startsWith('.')) {
        domain = domain.substring(1);
      }
      if (domain != null && !hostIn(origin, domain)) continue;
      if (cookie.value.length > 4096 ||
          (cookie.secure && origin.scheme != 'https')) {
        continue;
      }
      final cutoff = origin.path.lastIndexOf('/');
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : (cutoff < 1 ? '/' : origin.path.substring(0, cutoff));
      final key = (HeaderPolicy.origin(origin), path, cookie.name);
      final age = cookie.maxAge;
      if (age != null && age > 31536000) continue;
      final expires = age == null
          ? cookie.expires
          : now.add(Duration(seconds: age));
      if (expires != null && !expires.isAfter(now)) {
        _values.remove(key);
      } else if (_values.containsKey(key) || _values.length < 64) {
        _values[key] = (cookie, expires);
      }
    }
  }

  String? forAddress(Uri target) {
    if (!permittedHost(target)) return null;
    final now = DateTime.now();
    final path = target.path.isEmpty ? '/' : target.path;
    _values.removeWhere((_, value) => value.$2?.isAfter(now) == false);
    final values = _values.entries.where((entry) {
      final (origin, base, _) = entry.key;
      return origin == HeaderPolicy.origin(target) &&
          (!entry.value.$1.secure || target.scheme == 'https') &&
          (path == base ||
              path.startsWith(base.endsWith('/') ? base : '$base/'));
    }).toList()..sort((a, b) => b.key.$2.length.compareTo(a.key.$2.length));
    if (values.isEmpty) return null;
    return values
        .map((item) => '${item.value.$1.name}=${item.value.$1.value}')
        .join('; ');
  }
}
