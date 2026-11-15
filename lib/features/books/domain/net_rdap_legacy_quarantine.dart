import 'book.dart';
import 'legado_source_fingerprint.dart';

// Repeated registry 404 and earlier DNS failures support a temporary review of
// these exact bundled versions only. They do not establish maliciousness,
// historical deletion, or permanent unavailability of the registered domains.
const _unavailable = <String, (String, String)>{
  'b269ecd1a1c9ce6693119d5e20fc3ae82998662478c507ba7b4a1604be981ff8': (
    'https://m.dushuapp.net/',
    'f45eb9e161496525811883e848ab49a5a191486b4786a264191396aad2cc008d',
  ),
  'ca828313e6ceaa40c92460bc887e80428500586838f387e9dee325a104768804': (
    'https://www.feiyuefw.net',
    'ae15c4095ae919b8fd53da14f1ce45c51b8f2de3b46cc758bedfabc8bf9e6d9a',
  ),
  'd572a214fd5921004a53bee151be495ec9a6419b911e6f3fcb792fc05de1491e': (
    'https://www.zhijiandoukou.net/',
    'afc6d6407f26f9bcaf33c2d908589fe2d7bae7d843e631695b51ac487329e89e',
  ),
  'ebf204ebcbb379cd42b4e3e8ed69b9b648152bca96be6dbd6501b89db12300a5': (
    'https://www.zhijiandoukou.net/',
    'afc6d6407f26f9bcaf33c2d908589fe2d7bae7d843e631695b51ac487329e89e',
  ),
};

bool unavailableNetRdapLegacySource(BookSource source) {
  final expected = _unavailable[source.id];
  final legacy = source.legado;
  return expected != null &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == expected.$1 &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == expected.$2;
}
