import '../../sources/domain/video_source.dart';
import 'legado_source.dart';
import 'legado_source_fingerprint.dart';

const _sourceId =
    '3ea17136a0ff8e7ece79d304346edb613c2230e4c0ce806a0003e4a9b102dcc5';
const _oldDigest =
    '022794ec9f9953e5468daf7c04e4cec7797bc49d50c28e7fe17f473272a193a3';

/// Recover the detail category for the sampled bundled version only.
Map repairJhsssdLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final sourceKey = data['sourceKey'] ?? '';
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint != Uri.parse('https://m.jhsssd.com') ||
      sourceKey != '' ||
      (data['search'] ?? '') != '' ||
      (data['discover'] ?? '') != '' ||
      (data['searchCharset'] ?? 'utf-8') != 'utf-8' ||
      !_emptyMap(data['searchForm']) ||
      !_emptyMap(data['rules']) ||
      !_emptyList(data['discoveryCategories']) ||
      !_emptyList(data['mediaHosts']) ||
      !_emptyList(data['featured']) ||
      data['directAudio'] == true) {
    return legado;
  }
  if (stableId('text:html:${endpoint!.host}') != _sourceId ||
      legadoSourceFingerprint(LegadoSource.fromJson(legado)) != _oldDigest) {
    return legado;
  }
  return {
    ...legado,
    'rules': {
      ...legado['rules'] as Map,
      'infoCategory': r'[property="og:novel:category"]@content',
    },
  };
}

bool _emptyMap(Object? value) => value == null || value is Map && value.isEmpty;
bool _emptyList(Object? value) =>
    value == null || value is List && value.isEmpty;
