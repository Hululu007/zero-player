import 'book.dart';
import 'legado_source_fingerprint.dart';

/// Temporarily mark only the two individually sampled archived versions.
/// Their old search and discovery paths returned a domain-sale page; this is
/// not a host-wide, orphan-history, malware or permanent-closure verdict.
bool unavailableSanyouLegacySource(BookSource source) {
  final legado = source.legado;
  if (source.kind != BookKind.text ||
      source.format != BookFormat.html ||
      source.endpoint.toString() != 'https://www.3uxiaoshuo.com/' ||
      legado == null) {
    return false;
  }
  final expected = switch (source.id) {
    'bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d'
        when source.sourceKey.isEmpty =>
      '719bcc073e57846c8fa64d94d46537f5fc764f7588af24e29c6fffdf8b210834',
    '6a45e0819c4f731d5a6edffd650e0b22eb49c8e2eccd5de320e0ae2c701c67e9'
        when source.sourceKey == '3uxiaoshuo.com#%23@%E9%81%87%E7%9F%A5' =>
      'c7ccae8b1f6031b071e57473cb987969c6a075bdd65b6767d6d1375d4d7c9e58',
    _ => null,
  };
  return expected != null && legadoSourceFingerprint(legado) == expected;
}
