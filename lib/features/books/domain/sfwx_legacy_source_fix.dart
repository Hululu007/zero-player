import 'legado_source.dart';
import 'legado_source_fingerprint.dart';

// Full normalized Legado configuration of the audited bundled record 4760.
const _oldLegadoDigest =
    'b91ea60260f819a4d31198672593d844caaaee381918419a46888814190ad411';

/// Repair only the observed version, including previously saved copies.
Map repairSfwxLegadoSource(Map data, Map legado) {
  if (data['kind'] != 'text' ||
      data['format'] != 'html' ||
      Uri.tryParse('${data['url']}') != Uri.parse('https://www.sfwx.com') ||
      (data['sourceKey'] ?? '') != 'sfwx.com#%F0%9F%8E%83' ||
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
          _oldLegadoDigest) {
    return legado;
  }
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
