import 'book.dart';
import 'legado_source_fingerprint.dart';

const _unavailable = <String, (String, BookKind, String)>{
  '3ea1299b20ba9e4cad740893944b9717f315f10aa3e9ca1eb972174ea415772f': (
    'https://www.aslwx.com/',
    BookKind.text,
    '310116cd3aba678fdece2a014720d550d35c73b07880d21effc5a62bb6f85045',
  ),
  '74c6719633e7baf3719840878666e428727b0679d7d79d72833443228cbaeb13': (
    'https://open.bxzwapp.com',
    BookKind.comic,
    'bb10adc2c55354161b811cb00b1a917bb613a28ed85cd8c16e8163e4e5e7efee',
  ),
  '11a8812a1ceaac805c31c4e30befd21f90bc597e6fe6a2ccf7ce0a99d16146e2': (
    'https://www.iswsk.com',
    BookKind.text,
    '049d7b8649ec6ead8748c0e258969db8edcc2089f98fc3964d3c69987a99a696',
  ),
  'ab389794201d206745ffd96ed9dad49cae0ac2908390aa8eb4af643d6df5a439': (
    'https://api.kuduwxw.com/',
    BookKind.text,
    '685feb62d8918f6e77f8e11c6a25a898986d624a76122b62af03ac2b25d05d3a',
  ),
  'e0747de2a83fbf4a88e0525909fbb3dfaecf6af4b449c571e02e7aa57c3b95de': (
    'https://api.kuduwxw.com/',
    BookKind.text,
    'e2e35e9ca83046a84d5af983cd13d5aeaa4043acff7c61bc979ef8642db97d99',
  ),
  'b011c359cb7052cbad501935630e7b78b6b574e31e526771505022da8b7adef7': (
    'https://api.meiguixsapp.com/',
    BookKind.text,
    '976b186a4cf7345f0da849bb85aae6a2e118f9eb9d1bee09488bfe6cd08b3e3b',
  ),
  '09ab5c51cd9ae2d950ca405915a0531c580ddaf24c9363159e4cbc33ca44dcb0': (
    'https://www.uuhanman.com',
    BookKind.comic,
    '26d69123c17c0745d24025a3d195e4885aadea3f62cfe218e4d44507190336f0',
  ),
  'a149908f17a173f78f4ccd72d4487345831cb1e37ed4935f0b3e4a97ddaaf560': (
    'https://m.yjzhy.com',
    BookKind.text,
    '00adb73b6015d56efe64f2f2dc32bfb5a0c6719e9824b2ae69da8b4b605272c9',
  ),
  'e2693c7e336bccb184165046d837782c1573099afb264ba6bed38eedfd9f4b0a': (
    'https://book.yuntuxs.com/',
    BookKind.text,
    '030f6f801ab5edbadddcd187370db83395c82ff313509eb237e5ee7a938d0929',
  ),
  '496c33059ab2a13f4d3962393458b3e69423df00c14cd40342605ec8943aec8c': (
    'https://get.aoyekanshu.com',
    BookKind.text,
    '6f923b60d82cf28829ab61a8864feaf7c73f01affc70d96922337144cbef8621',
  ),
  '2aca3269bc95693ff09dd4daf52a30924628935f0d7f76070e8a49af90b56444': (
    'https://www.hanmandq.com/',
    BookKind.comic,
    'ff8cf322b697f97d8841d3083463bdd3529b41fb9f9da7e7a85a5437ba682038',
  ),
  '007c637e232cbc6c7f43b91853f7efd265e3bd22ced3e5a50ee54072f78c90fa': (
    'https://www.xichubao.com/',
    BookKind.text,
    'e434994bb437993079d8c48cb6d18b986c84d74731102be76707ed3c9055236b',
  ),
  'd8e028d511f6bd397a19776fc7c74a47122fdd2c5a05deb6d25a2234e359bc00': (
    'https://www.xichubao.com',
    BookKind.text,
    '620650cc0fe360be0b53b5766f1e103324bd985147234190551f0bf1989c93fa',
  ),
};

// Repeated registry 404 and DNS failures justify temporarily excluding only
// these exact legacy versions, not a host-wide or permanent-closure claim.
bool unavailableComRdapLegacySource(BookSource source) {
  final expected = _unavailable[source.id];
  final legacy = source.legado;
  return expected != null &&
      source.kind == expected.$2 &&
      source.format == BookFormat.html &&
      source.endpoint.toString() == expected.$1 &&
      legacy != null &&
      legadoSourceFingerprint(legacy) == expected.$3;
}
