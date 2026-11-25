import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'header_policy.dart';

final class SourceCertificateFailure extends HandshakeException {
  SourceCertificateFailure(Uri uri, X509Certificate certificate)
    : origin = HeaderPolicy.origin(uri),
      fingerprint = sha256.convert(certificate.der).toString(),
      super('HTTPS 证书无法验证 · ${HeaderPolicy.origin(uri)}');

  final String origin;
  final String fingerprint;
}

/// Request-local selection. The transport opens a separate client when used.
final class SourceCertificate {
  const SourceCertificate(
    this.origin,
    this.fingerprint,
    this.active, {
    this.publicRequest,
  });

  final String origin, fingerprint;
  final bool Function() active;
  final bool Function(Uri, Map<String, String>)? publicRequest;
  static final _key = Object();
  static SourceCertificate? get current =>
      Zone.current[_key] as SourceCertificate?;

  Future<T> run<T>(Future<T> Function() request) =>
      runZoned(request, zoneValues: {_key: this});

  bool permits(Uri uri, Map<String, String> headers) =>
      active() &&
      uri.scheme == 'https' &&
      HeaderPolicy.origin(uri) == origin &&
      (publicRequest?.call(uri, headers) == true ||
          (headers.keys.every(
                (key) => const {
                  'accept',
                  'accept-language',
                  'user-agent',
                }.contains(key.toLowerCase()),
              ) &&
              uri.queryParametersAll.keys.every(
                (key) => const {
                  'page',
                  'p',
                  'pageNum',
                  'pageSize',
                  'offset',
                  'start',
                  'size',
                  'q',
                  'query',
                  'keyword',
                  'search',
                  'category',
                  'sort',
                  'order',
                }.contains(key),
              )));

  bool accepts(Uri uri, SourceCertificateFailure failure) =>
      active() &&
      origin == failure.origin &&
      origin == HeaderPolicy.origin(uri) &&
      fingerprint == failure.fingerprint;
}
