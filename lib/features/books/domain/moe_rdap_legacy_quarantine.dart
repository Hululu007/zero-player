import 'book.dart';
import 'legado_source_fingerprint.dart';

// These exact bundled versions have repeated registry and DNS evidence of
// present unavailability. This is not a host-wide or permanent-closure claim.
const _unavailable = <String, (String, String)>{
  '17ee3b392858318a4354a4be959522d20aacc994f62ef212f6c106ece1120c61': (
    'https://book.zri.moe',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
  '3abb61dc94096774b7f9236f0195456acb2e75d05478cd1e407ca5734c1fa14f': (
    'https://book.zri.moe',
    '1fe969cc7e2d0d5a3f9b5efd2aecedebbcc376b5b15c3fdada001f640e563365',
  ),
  '42cc09c78ea74e2db2fc2e71f767ccb5381dbed4543f198b4e0f33546631f378': (
    'https://book.zri.moe/',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
  '9a7596d1ca9b5957561a744dff5f87f688183a10550e803baeee903ec04e1b1d': (
    'https://book.zri.moe/zhbyjm',
    '9c1334fa8f94c82bf4cd918caddb4079e6f35083c77c880581274b7d6a922535',
  ),
};

bool unavailableMoeRdapLegacySource(BookSource source) {
  final expected = _unavailable[source.id];
  final legacy = source.legado;
  return expected != null &&
      source.kind == BookKind.text &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == expected.$1 &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == expected.$2;
}
