import 'book.dart';
import 'legado_source_fingerprint.dart';

// Two time-separated registry/DNS observations concern these archived rules
// only. They do not establish a host-wide, permanent or malicious condition.
const _unavailable = <String, (String, String)>{
  '2c42e8be93e8d9a0cba17e082bb31665d2dc717c98054dcc596a318b81775211': (
    'https://www.shenxianfaka.top/',
    '70961df18d8d9eacd34a07a5d9944a0bebfe87196ab98fc25fbfe25aa39be010',
  ),
  '2fa11264c96f40e2d97174ab5dc0393039f3235dad0d0c71b49fdbcee5d788c9': (
    'https://stxt.top',
    'b8efdaed3bfc90cfdbd4b69a28b7b7d00685883b0a079b794ee121e3f8e46312',
  ),
};

bool unavailableTopRdapLegacySource(BookSource source) {
  final expected = _unavailable[source.id];
  final legado = source.legado;
  return expected != null &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == expected.$1 &&
      legado != null &&
      legadoSourceFingerprint(legado) == expected.$2;
}
