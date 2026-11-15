import 'book.dart';
import 'legado_source_fingerprint.dart';

/// Repeated checks found the old novel search and category paths unavailable.
/// Limit only this exact archived version; other versions require fresh review.
bool unavailable242NovelLegacySource(BookSource source) {
  final legado = source.legado;
  return source.id ==
          '67a2a1f1f3cb1fe0abba50885d93798631ac0776df9eaba887ebb6f5c0f55870' &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == 'https://www.242xs.info/' &&
      legado != null &&
      legadoSourceFingerprint(legado) ==
          '20ee8d7bb248e4657460b7b95eb51da6810e7a4d83ccc4e55992d899696642d5';
}
