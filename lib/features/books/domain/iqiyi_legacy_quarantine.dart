import 'book.dart';
import 'legado_source_fingerprint.dart';

// The 2026-11-15 review observed the old comic search and discovery paths
// redirecting to the video homepage. These fingerprints identify only the
// bundled old rules; they do not classify the host or newer rules as harmful.
const _common =
    'b21c15180550a1d09096d352b3404fb2585adba84ef080ea75cbd86560563ff9';
const _haxcText =
    '097a53966c88a155746f025d95452f5074b563c038778ca1fce844284edbd91f';
const _rootComic =
    'b1f4b579c22c9e8079cd3a6cfc3b46bd9f1c39a1880246f3191a9af5ac6b24ab';

const _oldRules = <String, (String, String)>{
  '66013fbe61a22b463af0e4f026901e3d9edde413f5985f8b309393ede0b2b764': (
    _common,
    '/manhua',
  ),
  'c3728b14bdf623a3d93a4db8814ce6d121e3b498d33cd3d9d212484663fbb1dc': (
    _haxcText,
    '/manhua',
  ),
  '5de6055cefc4b0beb12832c615e1063bff07c5abce9ce7d9afd37ccd8a48dd0d': (
    _common,
    '/manhua',
  ),
  '4d7296a10b257ff1b57d4933083198fb8b9a638868afbfb88aa7d5bbff2884e5': (
    _common,
    '/manhua',
  ),
  '21ad5d2f3e7c66fdaa4b31008cd46b52e2b32228961459c135ae866206b40ddf': (
    _rootComic,
    '',
  ),
  '290bf6f2ed83af236dd136be2509c0c2ab48a34716ce9bbeb8e08b820afa8fb3': (
    _common,
    '/manhua',
  ),
  '021caeaebf0bbdbe1b647c58c66214fbb5d723987a9880b4a13baafceeef033a': (
    _common,
    '/manhua',
  ),
  'aafb8d8470d14758abdd08865f28bbd68c896706e666d429263fd3698d3fbe2f': (
    _common,
    '/manhua',
  ),
  '0a344963c3d4c7bf1f047281708bbe01e76a1681b0a32f430fcfd4375a67eae9': (
    _common,
    '/manhua',
  ),
};

bool unavailableIqiyiLegacySource(BookSource source) {
  final expected = _oldRules[source.id];
  final legacy = source.legado;
  if (expected == null ||
      legacy == null ||
      source.format != BookFormat.html ||
      (source.kind != BookKind.text && source.kind != BookKind.comic) ||
      source.endpoint.host != 'www.iqiyi.com' ||
      source.endpoint.hasQuery ||
      (source.endpoint.path != expected.$2 &&
          !(expected.$2.isEmpty && source.endpoint.path == '/')) ||
      legacy.search !=
          'https://www.iqiyi.com/manhua/search-keyword={{key}}_{{page}}' ||
      legacy.rules['searchList'] !=
          'class.stacksList@tag.li||class.cartoon-hot-ul@tag.li') {
    return false;
  }
  return legadoSourceFingerprint(legacy) == expected.$1;
}
