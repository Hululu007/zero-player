import 'book.dart';
import 'legado_source_fingerprint.dart';

const _sourceId =
    '3ea1299b20ba9e4cad740893944b9717f315f10aa3e9ca1eb972174ea415772f';
const _endpoint = 'https://www.aslwx.com/';
const _legacyFingerprint =
    '310116cd3aba678fdece2a014720d550d35c73b07880d21effc5a62bb6f85045';

// Repeated registry 404 and DNS failures justify temporarily excluding only
// this exact legacy version, not a host-wide or permanent-closure claim.
bool unavailableComRdapLegacySource(BookSource source) {
  final legacy = source.legado;
  return source.id == _sourceId &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == _endpoint &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == _legacyFingerprint;
}
