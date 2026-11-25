import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'loopback_https_tunnel.dart';
import 'network_target_policy.dart';
import 'source_certificate.dart';

/// Uses the Windows loopback proxy only for explicitly listed HTTPS hosts.
final class WindowsPublicHttpsRoute {
  WindowsPublicHttpsRoute(Set<String> hosts) : _hosts = Set.unmodifiable(hosts);

  final Set<String> _hosts;
  static const _policy = NetworkTargetPolicy();
  final _addresses = <String, ({DateTime until, InternetAddress address})>{};
  final _pending = <String, Future<InternetAddress>>{};

  Future<ConnectionTask<Socket>?> connect(
    Uri uri,
    SourceCertificate? certificate,
  ) async {
    if (!Platform.isWindows ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        !_hosts.contains(uri.host)) {
      return null;
    }
    final proxyUri = _localProxy();
    if (proxyUri == null) return null;
    final proxy = InternetAddress.tryParse(proxyUri.host);
    if (proxy == null || !proxy.isLoopback) return null;
    final tunnel = LoopbackHttpsTunnel(proxy, proxyUri.port, _policy);
    final address = _pending.putIfAbsent(uri.host, () async {
      try {
        return await _resolve(uri.host, proxy, proxyUri.port);
      } finally {
        _pending.remove(uri.host);
      }
    });
    var active = tunnel.connect(uri, address, certificate: certificate);
    var cancelled = false;
    Future<Socket> open() async {
      try {
        return await active.socket;
      } on SocketException {
        if (cancelled) rethrow;
        active = await _policy.connect(
          uri,
          null,
          null,
          certificate: certificate,
        );
        if (cancelled) active.cancel();
        return active.socket;
      }
    }

    final socket = open();
    socket.ignore();
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      active.cancel();
    });
  }

  Future<InternetAddress> _resolve(
    String host,
    InternetAddress proxy,
    int port,
  ) async {
    if (_addresses[host] case final cached?
        when cached.until.isAfter(DateTime.now())) {
      return cached.address;
    }
    final dns = Uri.https('cloudflare-dns.com', '/dns-query', {
      'name': host,
      'type': 'A',
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, _, _) async {
        if (uri != dns) throw const FormatException('DNS 查询地址无效');
        return LoopbackHttpsTunnel(
          proxy,
          port,
          _policy,
        ).connect(dns, Future.value(InternetAddress('1.1.1.1')));
      };
    try {
      final request = await client.getUrl(dns);
      request.followRedirects = false;
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) {
        throw const SocketException('系统代理无法解析来源域名');
      }
      final bytes = <int>[];
      await for (final part in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(part);
        if (bytes.length > 32768) throw const FormatException('DNS 响应过大');
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value case {'Status': 0, 'Answer': final List records}) {
        for (final record in records) {
          if (record case {'type': 1, 'data': final String data}) {
            final ip = InternetAddress.tryParse(data);
            if (ip == null || NetworkTargetPolicy.isPrivate(ip)) continue;
            _addresses[host] = (
              until: DateTime.now().add(const Duration(minutes: 2)),
              address: ip,
            );
            return ip;
          }
        }
      }
      throw const SocketException('系统代理未返回来源的公网地址');
    } finally {
      client.close(force: true);
    }
  }
}

Uri? _localProxy() {
  const settings =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  final read = DynamicLibrary.open('advapi32.dll')
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        )
      >('RegGetValueW');
  return using((arena) {
    final path = settings.toNativeUtf16(allocator: arena);
    final enabled = arena<Uint32>(), size = arena<Uint32>()..value = 4;
    const currentUser = -2147483647;
    if (read(
              currentUser,
              path,
              'ProxyEnable'.toNativeUtf16(allocator: arena),
              0x10,
              nullptr,
              enabled.cast(),
              size,
            ) !=
            0 ||
        enabled.value != 1) {
      return null;
    }
    final address = arena<Uint16>(1024);
    size.value = 2048;
    if (read(
          currentUser,
          path,
          'ProxyServer'.toNativeUtf16(allocator: arena),
          0x02,
          nullptr,
          address.cast(),
          size,
        ) !=
        0) {
      return null;
    }
    final raw = address.cast<Utf16>().toDartString().trim();
    final entry = raw.contains('=')
        ? raw
              .split(';')
              .where((item) => item.startsWith('https='))
              .firstOrNull
              ?.substring(6)
        : raw;
    final uri = entry == null ? null : Uri.tryParse('http://$entry');
    if (uri == null ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      return null;
    }
    return uri;
  });
}
