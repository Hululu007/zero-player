import 'legado_source.dart';
import 'legado_source_fingerprint.dart';

// Full normalized Legado request configuration from bundled record 168.
const _oldRulesDigest =
    '831e0cc10732d8493f297e45d6df8edf132f4b4eb4c14a03b2234de9e21d73f1';

/// The old discovery entry performs a forum check-in rather than listing books.
/// Remove it only from the audited version, including previously saved copies.
Map repairFanfanuLegadoSource(Map data, Map legado) {
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      Uri.tryParse('${data['url']}') != Uri.parse('https://bbs.fanfanu.com/') ||
      (data['sourceKey'] ?? '') != '' ||
      (data['search'] ?? '') != '' ||
      (data['discover'] ?? '') != '' ||
      (data['searchCharset'] ?? 'utf-8') != 'utf-8' ||
      !_emptyMap(data['searchForm']) ||
      !_emptyMap(data['rules']) ||
      !_emptyList(data['discoveryCategories']) ||
      !_emptyList(data['mediaHosts']) ||
      !_emptyList(data['featured']) ||
      data['directAudio'] == true ||
      legadoSourceFingerprint(LegadoSource.fromJson(legado)) !=
          _oldRulesDigest) {
    return legado;
  }
  return {...legado, 'explore': const []};
}

bool _emptyMap(Object? value) => value == null || value is Map && value.isEmpty;
bool _emptyList(Object? value) =>
    value == null || value is List && value.isEmpty;
