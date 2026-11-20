import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/header_policy.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/network/source_certificate.dart';

void main() {
  test(
    'an exact-origin certificate exception cannot follow sensitive requests',
    () async {
      var allowed = true;
      final origin = Uri.parse('https://example.test:8443');
      final certificate = SourceCertificate(
        HeaderPolicy.origin(origin),
        'fingerprint',
        () => allowed,
      );
      expect(SourceCertificate.current, isNull);
      await certificate.run(() async {
        expect(SourceCertificate.current, same(certificate));
        expect(certificate.permits(origin.resolve('/list?page=2'), {}), isTrue);
        expect(
          certificate.permits(Uri.parse('https://example.test/'), {}),
          isFalse,
        );
        expect(
          certificate.permits(origin.resolve('/list?token=secret'), {}),
          isFalse,
        );
        expect(
          certificate.permits(origin, {'Authorization': 'secret'}),
          isFalse,
        );
        allowed = false;
        expect(certificate.permits(origin, {}), isFalse);
      });
      expect(SourceCertificate.current, isNull);
    },
  );

  test('HTTPS sends a TLS handshake, never plaintext HTTP', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = MediaHttpClient(allowPrivateNetworks: true);
    addTearDown(() async {
      client.close();
      await server.close();
    });
    final firstByte = server.first.then((socket) async {
      try {
        return (await socket.first).first;
      } finally {
        socket.destroy();
      }
    });
    await expectLater(
      client.open(
        Uri.parse('https://127.0.0.1:${server.port}/'),
        policy: HeaderPolicy({}),
      ),
      throwsA(isA<HandshakeException>()),
    );
    expect(await firstByte, 0x16);
  });
}
