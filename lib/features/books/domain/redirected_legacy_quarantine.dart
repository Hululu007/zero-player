import 'book.dart';
import 'legado_source_fingerprint.dart';

const _redirected = <String, (String, String)>{
  '579f77abbbbe0d480ebcf75b9aca291c573954fac9496263f2747ac0dd2e0156': (
    'https://m.newbiquge.org',
    'c9fdc25ee7e1a4cabee2d83860b0d38b5d92bbdeb0a5627490ee8c9613cbf181',
  ),
  'd4b04ca5fb5f99ec4197fa67c2555cbac933b04534fd16f41eefec29c21d3d29': (
    'https://www.3ubook.com',
    '384f712065d76ffc451e03883e1b56bb1f76f427d29f3f9cce3363d7c55af81c',
  ),
};

/// These exact old search/discovery rules repeatedly redirected outside the
/// permitted source host. This is not a host-wide or malware classification.
bool unavailableRedirectedLegacySource(BookSource source) {
  final expected = _redirected[source.id];
  final legacy = source.legado;
  return expected != null &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == expected.$1 &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == expected.$2;
}
