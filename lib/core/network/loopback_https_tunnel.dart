import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'network_target_policy.dart';
import 'source_certificate.dart';

/// HTTPS via an explicitly configured local HTTP proxy. The proxy only sees
/// verified public IP literals in CONNECT, never an unrestricted DNS target.
final class LoopbackHttpsTunnel {
  LoopbackHttpsTunnel(this.proxy, this.port, this.policy);

  final InternetAddress proxy;
  final int port;
  final NetworkTargetPolicy policy;
  Socket? _socket;
  ConnectionTask<Socket>? _pending;
  bool _cancelled = false;

  ConnectionTask<Socket> connect(
    Uri uri,
    Future<InternetAddress> address, {
    SourceCertificate? certificate,
  }) {
    final socket = _open(uri, address, certificate).timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        cancel();
        throw const SocketException('系统代理 HTTPS 连接超时');
      },
    );
    socket.ignore();
    return ConnectionTask.fromSocket(socket, cancel);
  }

  Future<Socket> _open(
    Uri uri,
    Future<InternetAddress> address,
    SourceCertificate? certificate,
  ) async {
    NetworkTargetPolicy.validateUri(uri);
    if (!proxy.isLoopback || uri.scheme != 'https' || uri.port != 443) {
      throw const FormatException('代理仅用于已验证的公网 HTTPS 地址');
    }
    final ip = await address;
    if (NetworkTargetPolicy.isPrivate(ip)) {
      throw const FormatException('代理目标必须是公网 IP 地址');
    }
    _check();
    final task = _pending = await Socket.startConnect(proxy, port);
    if (_cancelled) task.cancel();
    try {
      final socket = _socket = await task.socket;
      _check();
      await _negotiate(socket, ip);
      _check();
      final secure = await policy.secureSocket(socket, uri, certificate);
      _socket = secure;
      _check();
      return secure;
    } on Object {
      _socket?.destroy();
      rethrow;
    } finally {
      _pending = null;
    }
  }

  Future<void> _negotiate(Socket socket, InternetAddress ip) {
    final host = ip.type == InternetAddressType.IPv6
        ? '[${ip.address}]'
        : ip.address;
    final response = Completer<void>();
    final bytes = <int>[];
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length > 8192) {
          _reject(response);
          return;
        }
        final header = latin1.decode(bytes);
        final ending = header.indexOf('\r\n\r\n');
        if (ending < 0) return;
        subscription.pause();
        if (ending + 4 == header.length &&
            RegExp(r'^HTTP/1\.[01] 200(?:[ \r]|$)').hasMatch(header)) {
          response.complete();
        } else {
          _reject(response);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!response.isCompleted) response.completeError(error, stack);
      },
      onDone: () => _reject(response),
    );
    socket.write('CONNECT $host:443 HTTP/1.1\r\nHost: $host:443\r\n\r\n');
    return response.future;
  }

  void _reject(Completer<void> response) {
    if (!response.isCompleted) {
      response.completeError(const SocketException('系统代理拒绝 HTTPS 连接'));
    }
  }

  void _check() {
    if (_cancelled) throw const SocketException('系统代理连接已取消');
  }

  void cancel() {
    _cancelled = true;
    _pending?.cancel();
    _socket?.destroy();
  }
}
