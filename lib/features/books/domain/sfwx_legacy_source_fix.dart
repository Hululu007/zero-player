import '../../sources/domain/video_source.dart';
import 'legado_source.dart';
import 'legado_source_fingerprint.dart';

// Full normalized Legado configurations of bundled records 4760 and 3984.
const _oldTaggedDigest =
    'b91ea60260f819a4d31198672593d844caaaee381918419a46888814190ad411';
const _oldUntaggedDigest =
    '338b1507f045152f1795bbfb75b95f68bca074ea40f39ccb42cb08cbed5e238a';
const _taggedId =
    '0723af128aa8adacd3e3a9efe03b622fa660d2f78a21b72cbe2bfe7d32ce8b75';
const _untaggedId =
    '9f004a19d12200c68d88fd5bafd4d34615b347d27e26322dbfa26142983cd295';

/// Repair only the observed version, including previously saved copies.
Map repairSfwxLegadoSource(Map data, Map legado) {
  final endpoint = Uri.tryParse('${data['url']}');
  final sourceKey = data['sourceKey'] ?? '';
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      endpoint == null ||
      sourceKey is! String ||
      !((endpoint == Uri.parse('https://www.sfwx.com') &&
              sourceKey == 'sfwx.com#%F0%9F%8E%83') ||
          (endpoint == Uri.parse('https://www.sfwx.com/') &&
              sourceKey.isEmpty)) ||
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
          'text:html:${endpoint.host.replaceFirst(RegExp(r'^www\.'), '')}',
        )
      : stableId('legado:text:html:$sourceKey');
  if (sourceId != _taggedId && sourceId != _untaggedId) return legado;
  final digest = legadoSourceFingerprint(LegadoSource.fromJson(legado));
  final tagged =
      sourceId == _taggedId &&
      sourceKey == 'sfwx.com#%F0%9F%8E%83' &&
      endpoint == Uri.parse('https://www.sfwx.com') &&
      digest == _oldTaggedDigest;
  final untagged =
      sourceId == _untaggedId &&
      sourceKey.isEmpty &&
      endpoint == Uri.parse('https://www.sfwx.com/') &&
      digest == _oldUntaggedDigest;
  if (!tagged && !untagged) return legado;
  return {
    ...legado,
    'rules': {
      ...legado['rules'] as Map,
      'infoInit': '',
      'infoTitle': r'[property$=book_name]@content',
      'infoAuthor': r'[property$=author]@content',
      'infoDescription': r'[property$=description]@content',
      'infoCover': 'img@src',
      // Keep the category label separate from status and timestamps so the
      // supervision policy can still recognise exact restricted labels.
      'infoCategory': r'[property$=category]@content',
      'infoLatest': r'[property$=latest_chapter_name]@content',
      // This link means the next chapter, not a continuation of this one.
      'nextContent': '',
    },
  };
}

bool _emptyMap(Object? value) => value == null || value is Map && value.isEmpty;
bool _emptyList(Object? value) =>
    value == null || value is List && value.isEmpty;
