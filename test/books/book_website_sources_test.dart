import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/data/book_builtin_domain_updates.dart';
import 'package:zero_player/features/books/data/book_client.dart';
import 'package:zero_player/features/books/data/book_manga_website.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<BookSource>> sourceRules() async =>
      (jsonDecode(
                await rootBundle.loadString(
                  'assets/catalogs/books/website-sources.json',
                ),
              )
              as List)
          .cast<Map>()
          .map((row) => BookSource.fromJson(row, builtin: true))
          .toList();

  test('website sources use unique identities and audited defaults', () async {
    final sources = await sourceRules();
    expect(sources.map((source) => source.id).toSet(), hasLength(6));
    expect(
      sources.any((source) => source.endpoint.host == 'm.bixiazw.net'),
      isFalse,
    );
    expect(
      sources.where((source) => source.kind == BookKind.comic),
      hasLength(2),
    );
    expect(sources.where((source) => source.defaultEnabled), isEmpty);
    expect(
      sources.every((source) => source.hasSearch && source.hasDiscovery),
      isTrue,
    );
  });

  test('only reviewed duplicate bundled profiles are consolidated', () async {
    final catalog = await AoaoStarBookCatalog.load();
    final rules = (await catalog.read()).sources;
    final duplicates = rules.where(
      (source) => supersededBundledBookSource(
        BookSourceEntry(source, true, false, '', '', null, fromCatalog: true),
      ),
    );
    expect(
      duplicates.map((source) => source.endpoint.host),
      unorderedEquals([
        '69shuba.cx',
        'm.aixdzs.com',
        'm.aixdzs.com',
        'm.aixdzs.com',
      ]),
    );
    for (final source in duplicates) {
      expect(
        supersededBundledBookSource(
          BookSourceEntry(source, true, false, '', '', null),
        ),
        isFalse,
      );
    }
  });

  test('manga temporary TLS permission accepts only public request fields', () {
    final search = Uri.https('www.yymanhua.com', '/search', {'title': '示例'});
    expect(isPublicMangaCertificateRequest(search, {}), isTrue);
    expect(
      isPublicMangaCertificateRequest(search, {'Cookie': 'private'}),
      isFalse,
    );
    final signed = Uri.https('www.xmanhua.com', '/m1/chapterimage.ashx', {
      'cid': '1',
      '_cid': '1',
      '_mid': '2',
      'page': '1',
      'key': '',
      '_dt': '2026-11-23 10:00:00',
      '_sign': 'a' * 32,
    });
    expect(
      isPublicMangaCertificateRequest(signed, {
        'Referer': 'https://www.xmanhua.com/m1/',
        'X-Requested-With': 'XMLHttpRequest',
      }),
      isTrue,
    );
    expect(
      isPublicMangaCertificateRequest(signed, {'Authorization': 'private'}),
      isFalse,
    );
    expect(
      isPublicMangaCertificateRequest(
        signed.replace(
          queryParameters: {...signed.queryParameters, 'key': 'private'},
        ),
        {},
      ),
      isFalse,
    );
  });

  test(
    'comic reader uses all signed pages in order and rejects invalid data',
    () async {
      final sources = (await sourceRules()).where(
        (source) => source.kind == BookKind.comic,
      );
      for (final source in sources) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final client = createFixtureClient(server.port);
        final prefix = source.endpoint.host.startsWith('www.yy')
            ? 'YYMANHUA'
            : 'XMANHUA';
        final host = prefix.toLowerCase();
        final requests = <String>[];
        final requested = <Uri>[];
        var vip = false;
        var invalid = false;
        server.listen((req) async {
          switch (req.uri.path) {
            case '/search':
              req.response.write(
                '<div class="mh-item"><h2 class="title"><a href="/38test/">示例漫画</a></h2></div>',
              );
            case '/38test/':
              req.response.write(
                '<div id="chapterlistload"><a class="detail-list-form-item" href="/m536967/">示例章<span>（2P）</span></a></div>',
              );
            case '/m536967/':
              req.response.write('''<script>
var isVip = "${vip ? 'True' : 'False'}";
var ${prefix}_MID = 38;
var ${prefix}_CID = 536967;
var ${prefix}_IMAGE_COUNT = 2;
var ${prefix}_VIEWSIGN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
var ${prefix}_VIEWSIGN_DT = "2026-11-23 18:50:20";
</script>''');
            case '/m536967/chapterimage.ashx':
              final page = req.uri.queryParameters['page']!;
              requests.add(page);
              expect(req.uri.queryParameters['_cid'], '536967');
              expect(req.uri.queryParameters['_mid'], '38');
              expect(
                req.uri.queryParameters['_sign'],
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              );
              expect(
                req.headers.value('referer'),
                'https://www.$host.com/m536967/',
              );
              final payload = _imagePayload(host, page);
              req.response.write(
                invalid && page == '2'
                    ? payload.replaceFirst('image|', 'invalid|')
                    : payload,
              );
            default:
              req.response.statusCode = 404;
          }
          await req.response.close();
        });
        final token = CancellationToken();
        final book = (await client.books(source, '示例漫画', token)).single;
        final chapter = (await client.chapters(source, book, token)).single;
        expect(chapter.title, '示例章');
        final images = await client.chapterImages(
          source,
          chapter,
          token,
          requestGuard: (uri, _) => requested.add(uri),
        );
        expect(requests, unorderedEquals(['1', '2']));
        expect(images.map((uri) => uri.pathSegments.last), [
          '1_2816.jpg',
          '2_2816.jpg',
        ]);
        expect(images.every((uri) => uri.host == 'image.$host.com'), isTrue);
        expect(requested, containsAll(images));

        invalid = true;
        await expectLater(
          client.chapterImages(source, chapter, token),
          throwsFormatException,
        );
        requests.clear();
        vip = true;
        await expectLater(
          client.chapterImages(source, chapter, token),
          throwsFormatException,
        );
        expect(requests, isEmpty);
      }
    },
  );
}

String _imagePayload(String host, String index) =>
    r"""eval(function(p,a,c,k,e,d){e=function(c){return(c<a?"":e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};if(!''.replace(/^/,String)){while(c--)d[e(c)]=k[c]||e(c);k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1;};while(c--)if(k[c])p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c]);return p;}('e 9(){2 6=4;2 5=\'a\';2 7="g://j.h.f/1/b/4";2 3=["/c.8","/k.8"];o(2 i=0;i<3.l;i++){3[i]=7+3[i]+\'?6=4&5=a&m=\'}n 3}2 d;d=9();',25,25,'||var|pvalue|536967|key|cid|pix|jpg|dm5imagefun|454e45cd12b0aec54af22fc57cf24244|38|"""
    '${index}_2816||function|com|https|$host||image|3_7718|length|uk|return|for'
    r"""'.split('|'),0,{}))""";

BookClient createFixtureClient(int port) {
  final http = HttpOverrides.runZoned(
    MediaHttpClient.new,
    createHttpClient: (context) =>
        _FixtureHttp(_SystemHttpOverrides().createHttpClient(context), port),
  );
  addTearDown(http.close);
  return BookClient(DocumentClient(http));
}

final class _SystemHttpOverrides extends HttpOverrides {}

final class _FixtureHttp implements HttpClient {
  _FixtureHttp(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) => client.openUrl(
    method,
    uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isSetter ? null : super.noSuchMethod(invocation);
}
