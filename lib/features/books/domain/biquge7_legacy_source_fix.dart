import '../../sources/domain/video_source.dart';
import 'legado_source.dart';
import 'legado_source_fingerprint.dart';

const _taggedId =
    '03ce53f0b6632695058a7553e513b103e5aae06c34979992769d32e06af05fa8';
const _untaggedId =
    'ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3';
const _taggedDigest =
    '0a48023c241f6f1f78c6864403ae3fa68db2f8b877be0fa3981b3fd5cd1f8914';
const _untaggedDigest =
    'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf';

/// Keep the category as a separate policy input for the two observed versions.
Map repairBiquge7LegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final sourceKey = data['sourceKey'] ?? '';
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint != Uri.parse('https://www.biquge7.xyz/') ||
      sourceKey is! String ||
      !(sourceKey.isEmpty ||
          sourceKey == 'biquge7.xyz#%23@%E9%81%87%E7%9F%A5') ||
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
  final sourceId = sourceKey.isEmpty
      ? stableId(
          'text:html:${endpoint!.host.replaceFirst(RegExp(r'^www\.'), '')}',
        )
      : stableId('legado:text:html:$sourceKey');
  if (sourceId != _taggedId && sourceId != _untaggedId) return legado;
  final digest = legadoSourceFingerprint(LegadoSource.fromJson(legado));
  final tagged =
      sourceId == _taggedId &&
      sourceKey == 'biquge7.xyz#%23@%E9%81%87%E7%9F%A5' &&
      digest == _taggedDigest;
  final untagged =
      sourceId == _untaggedId && sourceKey.isEmpty && digest == _untaggedDigest;
  if (!tagged && !untagged) return legado;
  return {
    ...legado,
    'rules': {
      ...legado['rules'] as Map,
      'infoCategory': r'[property$=category]@content',
    },
  };
}

bool _emptyMap(Object? value) => value == null || value is Map && value.isEmpty;
bool _emptyList(Object? value) =>
    value == null || value is List && value.isEmpty;
