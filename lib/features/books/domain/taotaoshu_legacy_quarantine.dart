import 'book.dart';
import 'legado_source_fingerprint.dart';

const _sourceId =
    '827f2fea6fcae97d0fde45d48abffc4ffd50afd13f6bc8b6b721041ddeb95dc4';
const _legacyFingerprint =
    'c58f2700582d62767afd6fec65ffe4e9f48cb8de847879895a725501ee04be27';
final _endpoint = Uri.parse('https://www.taotaoshu8.com/');

// On 2026-11-15 this exact endpoint had no DNS answer. Registry and DNS
// observations indicate unavailability in the tested environment and period,
// not maliciousness or permanent closure. Do not generalize to the host,
// other rules, or orphan IDs.
bool unavailableTaotaoshuLegacySource(BookSource source) {
  final legacy = source.legado;
  return source.id == _sourceId &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint == _endpoint &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == _legacyFingerprint;
}
