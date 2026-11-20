part of 'books_repository.dart';

const _certificatePinsKey = 'reading_source_certificate_pins:v1';

extension BookRepositoryCertificates on BooksRepository {
  bool get certificateExceptionsAvailable =>
      !closing && !policy.supervision.enabled && !policy.supervision.corrupted;

  bool canConfirmCertificate(
    String sourceId,
    SourceCertificateFailure failure,
  ) {
    final entry = _sourceAccess.entry(sourceId);
    return certificateExceptionsAvailable &&
        entry != null &&
        entry.enabled &&
        sourceEntryAllowed(entry) &&
        failure.origin == HeaderPolicy.origin(entry.source.endpoint);
  }

  Future<void> rememberSourceCertificate(
    String sourceId,
    SourceCertificateFailure failure,
  ) async {
    void requireAccess() {
      policy.supervision.require(SensitiveOperation.settings);
      if (!canConfirmCertificate(sourceId, failure)) {
        throw const ContentBlocked('此证书不能用于当前渠道');
      }
    }

    requireAccess();
    await store.db.atomic(() async {
      final pins = await _certificatePins();
      requireAccess();
      pins[sourceId] = [failure.origin, failure.fingerprint];
      await store.write(_certificatePinsKey, pins);
      requireAccess();
    }, tables: {'app_meta'});
  }

  Future<Map<String, List<String>>> _certificatePins() async {
    final raw = await store.read(_certificatePinsKey);
    return {
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.key is String)
            if (entry.value case [String origin, String pin])
              entry.key as String: [origin, pin],
    };
  }

  Future<T> _certificateRequest<T>(
    String sourceId,
    SourceCertificateFailure? certificate,
    Future<T> Function() request,
  ) => certificate == null || !canConfirmCertificate(sourceId, certificate)
      ? request()
      : SourceCertificate(
          certificate.origin,
          certificate.fingerprint,
          () => canConfirmCertificate(sourceId, certificate),
        ).run(request);

  SourceCertificate? _aggregateCertificate(
    BookSource source,
    Map<String, List<String>> pins,
  ) {
    final pin = pins[source.id];
    if (pin == null || pin[0] != HeaderPolicy.origin(source.endpoint)) {
      return null;
    }
    return SourceCertificate(pin[0], pin[1], () {
      final entry = _sourceAccess.entry(source.id);
      return certificateExceptionsAvailable &&
          allowAggregateCertificateExceptions?.call() == true &&
          entry != null &&
          entry.enabled &&
          _currentSearchEntry(entry) &&
          _searchFingerprint(entry.source) == _searchFingerprint(source);
    });
  }
}
