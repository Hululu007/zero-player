import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/header_policy.dart';
import '../domain/book.dart';
import 'book_request_guard.dart';
import 'book_resource_limits.dart';

const _sites = {'www.yymanhua.com': 'YYMANHUA', 'www.xmanhua.com': 'XMANHUA'};
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

bool isMangaWebsite(BookSource source) =>
    source.builtin &&
    source.kind == BookKind.comic &&
    _sites.containsKey(source.endpoint.host);

bool isPublicMangaCertificateRequest(Uri uri, Map<String, String> headers) {
  if (!_sites.containsKey(uri.host)) return false;
  final query = uri.queryParametersAll;
  final names = headers.keys.map((key) => key.toLowerCase()).toSet();
  const common = {'accept', 'accept-language', 'user-agent'};
  if (uri.path == '/search') {
    return common.containsAll(names) &&
        query.keys.toSet().difference({'title', 'page'}).isEmpty;
  }
  if (!RegExp(r'^/m\d{1,10}/chapterimage\.ashx$').hasMatch(uri.path) ||
      !{...common, 'referer', 'x-requested-with'}.containsAll(names)) {
    return false;
  }
  final referer = uri
      .replace(
        path: uri.path.replaceFirst('chapterimage.ashx', ''),
        queryParameters: const {},
      )
      .toString()
      .split('?')
      .first;
  if (headers.entries.any(
    (header) => switch (header.key.toLowerCase()) {
      'referer' => header.value != referer,
      'x-requested-with' => header.value != 'XMLHttpRequest',
      _ => false,
    },
  )) {
    return false;
  }
  final numeric = RegExp(r'^\d{1,10}$');
  const keys = {'cid', 'page', 'key', '_cid', '_mid', '_dt', '_sign'};
  return query.length == keys.length &&
      keys.containsAll(query.keys) &&
      query.values.every((values) => values.length == 1) &&
      query['key']?.single == '' &&
      [
        'cid',
        'page',
        '_cid',
        '_mid',
      ].every((key) => numeric.hasMatch(query[key]!.single)) &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(query['_sign']!.single) &&
      RegExp(
        r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$',
      ).hasMatch(query['_dt']!.single);
}

Map<String, String> mangaWebsiteHeaders(
  BookSource source,
  Uri target, {
  required bool media,
}) => isMangaWebsite(source)
    ? {
        'User-Agent': _userAgent,
        if (media) ...HeaderPolicy.publicReferer(source.endpoint, target),
      }
    : const {};

final class MangaWebsite {
  const MangaWebsite(this.network);
  final DocumentClient network;

  Future<List<Uri>> chapterImages(
    BookSource source,
    BookChapter chapter,
    CancellationToken token,
    BookRequestGuard? guard,
  ) async {
    final uri = source.requestTarget(chapter.uri);
    final chapterId = RegExp(r'^/m(\d{1,10})/$').firstMatch(uri.path)?[1];
    if (!isMangaWebsite(source) || chapterId == null || uri.hasQuery) {
      throw const FormatException('漫画章节地址无效');
    }
    void requireTarget(Uri target) {
      source.requestTarget(target);
      guard?.call(target, null);
    }

    final page = await network.get(
      uri,
      headers: mangaWebsiteHeaders(source, uri, media: false),
      cancellation: token,
      networkTimeout: const Duration(seconds: 12),
      validateTarget: requireTarget,
    );
    if (page.uri != uri ||
        !RegExp(
          r'''var\s+isVip\s*=\s*["']False["']\s*;''',
        ).hasMatch(page.text)) {
      throw const FormatException('渠道未提供公开漫画章节');
    }
    final prefix = _sites[source.endpoint.host]!;
    String field(String name, String pattern) {
      final value = RegExp(
        'var\\s+${prefix}_$name\\s*=\\s*$pattern\\s*;',
      ).firstMatch(page.text)?[1];
      if (value == null) throw const FormatException('漫画章节数据不完整');
      return value;
    }

    final id = field('CID', r'(\d{1,10})');
    final comic = field('MID', r'(\d{1,10})');
    final count = int.parse(field('IMAGE_COUNT', r'(\d{1,4})'));
    final signature = field('VIEWSIGN', r'''["']([a-f0-9]{32})["']''');
    final date = field(
      'VIEWSIGN_DT',
      r'''["'](\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)["']''',
    );
    if (chapterId != id ||
        count < 1 ||
        count > BookResourceLimits.chapterImages) {
      throw const FormatException('漫画章节页数或编号无效');
    }
    final endpoint = uri.resolve('chapterimage.ashx');
    Future<Uri> loadPage(int index) async {
      token.check();
      final target = endpoint.replace(
        queryParameters: {
          'cid': id,
          'page': '$index',
          'key': '',
          '_cid': id,
          '_mid': comic,
          '_dt': date,
          '_sign': signature,
        },
      );
      final response = await network.get(
        target,
        headers: {
          ...mangaWebsiteHeaders(source, target, media: false),
          ...HeaderPolicy.publicReferer(uri, target),
          'X-Requested-With': 'XMLHttpRequest',
        },
        cancellation: token,
        maxBytes: 8192,
        networkTimeout: const Duration(seconds: 12),
        validateTarget: requireTarget,
        mapRedirect: (_) => throw const FormatException('漫画图片查询发生重定向'),
      );
      final image = parseMangaWebsiteImage(
        source,
        response.text,
        id,
        comic,
        index,
      );
      guard?.call(image, null);
      return image;
    }

    final images = <Uri>[];
    for (var index = 1; index <= count; index += 4) {
      images.addAll(
        await Future.wait([
          for (var page = index; page < index + 4 && page <= count; page++)
            loadPage(page),
        ]),
      );
    }
    return images;
  }
}

// The public reader returns a packed token dictionary. Unpack its literal
// payload as data, then accept only the observed image address declaration.
const _packedImagePrefix =
    r"""eval(function(p,a,c,k,e,d){e=function(c){return(c<a?"":e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};if(!''.replace(/^/,String)){while(c--)d[e(c)]=k[c]||e(c);k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1;};while(c--)if(k[c])p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c]);return p;}(""";
final _packedImageData = RegExp(
  r"""^'((?:\\['\\]|[^'\\])*)',(\d{1,2}),(\d{1,2}),'([A-Za-z0-9_|]+)'\.split\('\|'\),0,\{\}\)\)\s*;?$""",
);
final _imageDeclaration = RegExp(
  r"""^function dm5imagefun\(\)\{var cid=(\d{1,10});var key='([a-f0-9]{32})';var pix="(https://[a-z0-9.]+/\d{1,10}/(\d{1,10})/\d{1,10})";var pvalue=\["/(\d{1,4}_[a-z0-9]{1,20}\.(?:jpg|png|webp))"(?:,"/\d{1,4}_[a-z0-9]{1,20}\.(?:jpg|png|webp)")?\];for\(var i=0;i<pvalue\.length;i\+\+\)\{pvalue\[i\]=pix\+pvalue\[i\]\+'\?cid=\d{1,10}&key=[a-f0-9]{32}&uk='\}return pvalue\}var d;d=dm5imagefun\(\);?$""",
);

Uri parseMangaWebsiteImage(
  BookSource source,
  String payload,
  String chapter,
  String comic,
  int page,
) {
  const invalid = FormatException('漫画图片响应无效');
  if (payload.length > 8192 || !isMangaWebsite(source)) throw invalid;
  final textPayload = payload.trim();
  if (!textPayload.startsWith(_packedImagePrefix)) throw invalid;
  final packed = _packedImageData.firstMatch(
    textPayload.substring(_packedImagePrefix.length),
  );
  if (packed == null) throw invalid;
  final radix = int.parse(packed[2]!);
  final dictionary = packed[4]!.split('|');
  if (radix < 2 || radix > 36 || dictionary.length != int.parse(packed[3]!)) {
    throw invalid;
  }
  final text = packed[1]!
      .replaceAllMapped(RegExp(r"\\(['\\])"), (match) => match[1]!)
      .replaceAllMapped(RegExp(r'\b[a-z0-9]+\b'), (match) {
        final key = match[0]!;
        final ordinal = int.tryParse(key, radix: radix);
        return ordinal != null &&
                ordinal < dictionary.length &&
                dictionary[ordinal].isNotEmpty
            ? dictionary[ordinal]
            : key;
      });
  final fields = _imageDeclaration.firstMatch(text);
  if (fields == null ||
      fields[1] != chapter ||
      fields[4] != comic ||
      !fields[3]!.endsWith('/$chapter') ||
      !fields[5]!.startsWith('${page}_')) {
    throw invalid;
  }
  final uri = Uri.parse('${fields[3]}/${fields[5]}');
  final expectedHost = source.endpoint.host.replaceFirst('www.', 'image.');
  if (uri.host != expectedHost) throw invalid;
  return source.requestTarget(
    uri.replace(queryParameters: {'cid': chapter, 'key': fields[2]!, 'uk': ''}),
    media: true,
  );
}
