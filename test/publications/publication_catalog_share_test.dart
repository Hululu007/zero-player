import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_rule_examples.dart';
import 'package:zero_player/features/publications/data/publication_share.dart';
import 'package:zero_player/features/publications/data/publication_sources.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/domain/acquisition_task.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

PublicationSource _source({
  List<String> hosts = const ['pan.quark.cn', 'drive.uc.cn'],
  bool html = false,
}) => PublicationSource.configure({
  'version': 1,
  'kind': html ? 'htmlSearch' : 'snapshot',
  'name': 'Fixture Catalogue',
  'endpoint': 'https://catalog.example/books',
  'hosts': hosts,
  if (html) 'rows': '.edition',
  'field': html
      ? {'title': 'h2', 'pdf': '.download', 'epub': 'a@href'}
      : {'title': 'title', 'pdf': 'pdf', 'epub': 'epub'},
});

PublicationEdition _book(String url, {PublicationSource? source}) =>
    configuredPublicationRows(
      source ?? _source(),
      jsonEncode([
        {'title': 'Field Manual', 'pdf': url},
      ]),
    ).single;

void main() {
  test(
    'version 2 HTML supports row attributes and Kindle downloads in detail',
    () {
      final source = PublicationSource.configure({
        'name': 'Kindle catalogue',
        'version': 2,
        'kind': 'htmlSearch',
        'endpoint': 'https://catalog.example/books',
        'rows': 'a.book',
        'field': {'title': 'a', 'page': 'a@href', 'cover': 'img@data-src'},
        'detail': {'azw3': 'p.download'},
      });
      final book = configuredPublicationRows(
        source,
        '<a class="book" href="/detail?id=42">Reading example'
        '<img data-src="/cover.jpg"></a>',
      ).single;
      expect(book.title, 'Reading example');
      expect(book.page?.queryParameters['id'], '42');
      expect(book.cover?.path, '/cover.jpg');
      final copy = configuredDetailCandidates(
        source,
        '<p class="download"><a href="/books/reading.azw3">AZW3</a></p>',
        book.page!,
      ).single;
      expect(copy.format, PublicationFormat.azw3);
      expect(copy.link.path, '/books/reading.azw3');
    },
  );

  test(
    'Open Logic Project uses the same rules for catalogue and PDF details',
    () {
      final source = PublicationSource.configure(openLogicProjectRule);
      final rows = configuredPublicationRows(
        source,
        '<h3><a href="https://slc.openlogicproject.org/">Sets, Logic, Computation</a></h3>'
        '<h3><a href="courses/what-if/">What If?</a></h3>'
        '<h3>Sample Texts</h3>',
      );
      expect(rows.length, 2);
      final page = rows.first.page!;
      expect(page.host, 'slc.openlogicproject.org');
      final files = configuredDetailCandidates(
        source,
        '<a href="sets-print.pdf">Print</a><a href="slc-screen.pdf">Screen</a>',
        page,
      );
      expect(files.single.link, page.resolve('slc-screen.pdf'));
      expect(
        configuredDetailCandidates(
          source,
          '<a href="https://elsewhere.example/false-screen.pdf">PDF</a>',
          page,
        ),
        isEmpty,
      );
    },
  );

  test(
    'a directory-only source cannot resolve an injected file candidate',
    () async {
      final source = builtinPublicationSources.singleWhere(
        (item) => item.id == 'alltool-public-catalogue',
      );
      final transport = MediaHttpClient();
      addTearDown(transport.close);
      final resolver = PublicationShareResolver(
        PublicationHttp(transport, authorize: (_) {}),
      );
      final candidate = AcquisitionCandidate(
        source: source.id,
        format: PublicationFormat.pdf,
        link: Uri.https('alltool.top', '/book/example.pdf'),
      );
      await expectLater(
        resolver.resolve(candidate, source, null, CancellationToken()),
        throwsA(
          isA<PublicationFailure>().having(
            (error) => error.problem,
            'problem',
            PublicationProblem.unsupported,
          ),
        ),
      );
    },
  );

  test('an opt-in HTTPS upgrade applies only to the configured source origin', () {
    final source = PublicationSource.configure({
      'version': 2,
      'kind': 'htmlSearch',
      'name': 'Publisher',
      'endpoint': 'https://books.example.org/index',
      'hosts': ['cdn.example.org'],
      'upgradeSameHostHttp': true,
      'rows': 'li',
      'field': {'title': 'b', 'pdf': 'a@href'},
    });
    final rows = configuredPublicationRows(
      source,
      '<li><b>Policy</b><a href="http://books.example.org/work.pdf">Download</a></li>'
      '<li><b>Other origin</b><a href="http://cdn.example.org/other.pdf">Download</a></li>'
      '<li><b>Other port</b><a href="http://books.example.org:81/a.pdf">Download</a></li>',
    );
    expect(
      rows.first.candidates.single.link.toString(),
      'https://books.example.org/work.pdf',
    );
    expect(rows[1].candidates, isEmpty);
    expect(rows[2].candidates, isEmpty);
  });

  test(
    'version 2 JSON rules parse nested paths, details, next links and codes',
    () {
      final source = PublicationSource.configure({
        'version': 2,
        'kind': 'jsonSearch',
        'name': 'Nested',
        'endpoint': 'https://catalog.example.org/api/search',
        'listEndpoint': '/api/books',
        'hosts': ['pan.quark.cn'],
        'rows': '/data/books',
        'next': '/links/next',
        'field': {
          'title': 'name',
          'author': '/contributors/0/name',
          'page': 'details',
        },
        'detail': {
          'epub': '/files/application~1epub+zip',
          'pdf': '/share/link',
          'pdfCode': '/share/code',
        },
      });
      expect(
        PublicationSource.configure(source.toSpec()).sameConfiguration(source),
        isTrue,
      );
      const page =
          '{"data":{"books":[{"name":"Public work","contributors":[{"name":"Author"}],"details":"/book/one"}]},"links":{"next":"?cursor=two"}}';
      final base = source.endpoint.resolve('/api/books');
      final row = configuredPublicationRows(source, page, base: base).single;
      expect(row.author, 'Author');
      expect(
        configuredNextPage(source, page, base)?.queryParameters['cursor'],
        'two',
      );
      expect(
        configuredNextPage(
          source,
          '{"links":{"next":"https://elsewhere.test/next"}}',
          base,
        ),
        isNull,
      );
      final candidates = configuredDetailCandidates(
        source,
        '{"files":{"application/epub+zip":"edition.epub"},"share":{"link":"https://pan.quark.cn/s/0123456789ab","code":"aB12"}}',
        row.page!,
      );
      expect(candidates.first.link.path, '/book/edition.epub');
      expect(candidates.last.publishedAccess?.code, 'aB12');
    },
  );

  test(
    'version 2 HTML selectors parse a detail page without widening origins',
    () {
      final source = PublicationSource.configure({
        'version': 2,
        'kind': 'htmlSearch',
        'name': 'HTML',
        'endpoint': 'https://catalog.example.org/ebooks',
        'rows': 'li[typeof="schema:Book"]',
        'field': {'title': 'p span[property="schema:name"]', 'page': 'a@href'},
        'next': 'a[rel="next"]@href',
        'detail': {'epub': 'a.epub@href'},
      });
      const data =
          '<li typeof="schema:Book"><a href="/book/abc"></a>'
          '<p><span property="schema:name">Open Edition</span></p></li>'
          '<a rel="next" href="?page=2">Next</a>';
      final row = configuredPublicationRows(source, data).single;
      expect(row.title, 'Open Edition');
      expect(
        configuredNextPage(source, data, source.endpoint)?.query,
        'page=2',
      );
      expect(
        configuredDetailCandidates(
          source,
          '<a class="epub" href="https://outside.example.org/file.epub">Download</a>',
          row.page!,
        ),
        isEmpty,
      );
      expect(
        configuredDetailCandidates(
          source,
          '<a class="epub" href="file.epub">Download</a>',
          row.page!,
        ).single.link.path,
        '/book/file.epub',
      );
    },
  );

  _catalogueFieldTests();
  _htmlAnchorTests();
  _credentialScopeTests();
  _taskBindingTests();
}

AcquisitionCandidate? _htmlPdf(String field) =>
    configuredPublicationRows(
          _source(html: true),
          '<article class="edition"><h2>Field Manual</h2>$field</article>',
        ).single.candidates
        .where((item) => item.format == PublicationFormat.pdf)
        .firstOrNull;

void _htmlAnchorTests() {
  test('HTML uses the full href when the site abbreviates the share label', () {
    final file = _htmlPdf('''
<div class="download">
  <p><a href="https://catalog.example/books#previous">@previous</a></p>
  <a href="https://pan.quark.cn/s/abcd1234?pwd=ABCD">pan.quark.cn/s/ab...34?pwd=ABCD</a>
  <p>提取码：ABCD<br>PDF 密码：book-key</p>
</div>
''')!;
    expect(file.link, Uri.https('pan.quark.cn', '/s/abcd1234'));
    expect(file.publishedAccess?.code, 'ABCD');
    expect(file.publishedAccess?.pdfPassword, 'book-key');
  });

  test('a labelled anchor gets the code in its configured format field', () {
    final file = _htmlPdf('''
<div class="download"><a href="//pan.quark.cn/s/field">网盘下载</a>
<br>提取码：ABCD</div><p>提取码：WXYZ</p>
''')!;
    expect(file.link, Uri.https('pan.quark.cn', '/s/field'));
    expect(file.publishedAccess?.code, 'ABCD');
  });

  test('an identical visible label does not hide a conflicting code', () {
    final file = _htmlPdf('''
<div class="download"><a href="https://pan.quark.cn/s/field?pwd=ABCD">
https://pan.quark.cn/s/field</a><br>提取码：WXYZ</div>
''')!;
    expect(file.link, Uri.https('pan.quark.cn', '/s/field'));
    expect(file.publishedAccess?.code, isNull);
    expect(file.publishedAccess?.needsConfirmation, isTrue);
  });

  test('direct downloads can select a relative anchor itself', () {
    final file = _htmlPdf(
      '<a class="download" href="/series/Field%20Manual.pdf">下载 PDF</a>',
    )!;
    expect(
      file.link,
      Uri.parse('https://catalog.example/series/Field%20Manual.pdf'),
    );
    expect(file.publishedAccess, isNull);
  });

  test('ambiguous or unapproved anchor destinations never receive a code', () {
    for (final data in [
      '<a href="https://pan.quark.cn/s/one">下载</a>'
          '<a href="https://drive.uc.cn/s/other">备用</a>',
      '<a href="https://pan.quark.cn/s/one">https://drive.uc.cn/s/other</a>',
      '<a href="https://unknown.example/field.pdf">下载</a>',
      '<a href="https://pan.quark.cn/s/one?access_token=opaque">下载</a>',
    ]) {
      expect(_htmlPdf('<div class="download">$data<br>提取码：ABCD</div>'), isNull);
    }
  });
}

void _catalogueFieldTests() {
  test(
    'catalog format fields bind published codes and preserve clean references',
    () {
      final book = configuredPublicationRows(
        _source(),
        jsonEncode([
          {
            'title': 'Field Manual',
            'pdf': 'https://pan.quark.cn/s/field?pwd=abcd#list/share',
            'epub': 'drive.uc.cn/s/companion\n提取码: ef34',
          },
        ]),
      ).single;
      expect(book.candidates.map((item) => item.publishedAccess?.code), [
        'ef34',
        'abcd',
      ]);
      expect(
        book.candidates.every(
          (item) => !item.link.hasQuery && !item.link.hasFragment,
        ),
        isTrue,
      );
      expect(jsonEncode(book.toJson()), isNot(contains('abcd')));
      final restored = PublicationEdition.fromJson(
        jsonDecode(jsonEncode(book.toJson(includePublishedAccess: true)))
            as Map,
        includePublishedAccess: true,
      );
      expect(restored.id, book.id);
      expect(restored.candidates.map((item) => item.publishedAccess?.code), [
        'ef34',
        'abcd',
      ]);
      final changed = _book('https://pan.quark.cn/s/field?pwd=other');
      expect(changed.id, _book('https://pan.quark.cn/s/field').id);
    },
  );

  test('HTML fields keep link labels and document passwords separate', () {
    final book = configuredPublicationRows(_source(html: true), '''
<article class="edition"><h2>Field Manual</h2>
<div class="download">https://pan.quark.cn/s/field<br>提取码: B234<br>PDF 密码: document</div>
<a href="https://drive.uc.cn/s/companion?pwd=Q345">EPUB</a></article>
''').single;
    final pdf = book.candidates.singleWhere(
      (item) => item.format == PublicationFormat.pdf,
    );
    final epub = book.candidates.singleWhere(
      (item) => item.format == PublicationFormat.epub,
    );
    expect(pdf.link, Uri.https('pan.quark.cn', '/s/field'));
    expect(pdf.publishedAccess?.code, 'B234');
    expect(pdf.publishedAccess?.pdfPassword, 'document');
    expect(epub.publishedAccess?.code, 'Q345');
    expect(epub.publishedAccess?.pdfPassword, isNull);
  });
}

void _credentialScopeTests() {
  test(
    'a repeated share with different public codes requires confirmation',
    () {
      final book = configuredPublicationRows(
        _source(),
        jsonEncode([
          {
            'title': 'Field Manual',
            'pdf': 'https://pan.quark.cn/s/manual?pwd=ABCD',
          },
          {
            'title': 'Field Manual',
            'pdf': 'https://pan.quark.cn/s/manual?pwd=EFGH',
          },
        ]),
      ).single;
      expect(book.candidates.single.publishedAccess?.code, isNull);
      expect(book.candidates.single.publishedAccess?.needsConfirmation, isTrue);
    },
  );

  test(
    'catalog code parsing never widens the configured hosts or query types',
    () {
      for (final field in [
        'https://pan.quark.cn/s/field?pwd=ABCD',
        'pan.quark.cn/s/field',
      ]) {
        expect(
          _book(field, source: _source(hosts: const [])).candidates,
          isEmpty,
        );
      }
      expect(
        _book(
          'https://pan.quark.cn/s/field?access_token=opaque&pwd=ABCD',
        ).candidates,
        isEmpty,
      );
      expect(
        _book('https://catalog.example/field.pdf?pwd=ABCD').candidates,
        isEmpty,
      );
      final schemeRelative = _book(
        '//pan.quark.cn/s/field?pwd=ABCD',
      ).candidates.single;
      expect(schemeRelative.publishedAccess?.code, 'ABCD');
      final direct = _book('/library/Field Manual.pdf').candidates.single;
      expect(
        direct.link,
        Uri.parse('https://catalog.example/library/Field%20Manual.pdf'),
      );
      expect(direct.publishedAccess, isNull);
    },
  );
}

void _taskBindingTests() {
  test(
    'a configured folder cannot resolve before the chosen file is bound',
    () async {
      final network = MediaHttpClient();
      addTearDown(network.close);
      final candidate = _book(
        'https://pan.quark.cn/s/field?pwd=ABCD',
      ).candidates.single;
      final resolver = PublicationShareResolver(
        PublicationHttp(network, authorize: (_) {}),
      );
      await expectLater(
        resolver.resolve(candidate, _source(), 'ABCD', CancellationToken()),
        throwsA(
          isA<PublicationFailure>().having(
            (error) => error.problem,
            'problem',
            PublicationProblem.shareFile,
          ),
        ),
      );
      final chosen = candidate.withSharedFile((
        name: 'Field Manual.pdf',
        id: '0:manual',
        format: PublicationFormat.pdf,
        bytes: 192,
      ));
      expect(requiresPublicationFileChoice(chosen), isFalse);
      expect(chosen.fileId, '0:manual');
      expect(chosen.sharedFileName, 'Field Manual.pdf');
      expect(chosen.bytes, 192);
      expect(chosen.publishedAccess?.code, 'ABCD');
      expect(
        chosen.matchesSharedFile((
          name: 'Other version.pdf',
          id: '0:manual',
          format: PublicationFormat.pdf,
          bytes: 192,
        )),
        isFalse,
      );
    },
  );

  test('task deduplication ignores a published code rotation', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = PublicationStore(db);
    final a = _book('https://pan.quark.cn/s/field?pwd=AAAA');
    final b = _book('https://pan.quark.cn/s/field?pwd=BBBB');
    final id = await store.addTask(a, a.candidates);
    expect(await store.addTask(b, b.candidates), id);
    final task = (await store.task(id))!;
    expect(task.candidate.publishedAccess?.code, 'AAAA');
    expect(jsonEncode(task.edition.toJson()), isNot(contains('AAAA')));
  });

  test(
    'a failed preflight records the origin and queues the alternate',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = PublicationStore(db);
      final a = _book('https://pan.quark.cn/s/field?pwd=AAAA');
      final b = _book('https://catalog.example/field.pdf');
      final id = await store.addTask(
        a,
        [...a.candidates, ...b.candidates],
        preflightFailure: const PublicationFailure(
          PublicationProblem.challenge,
        ),
      );
      final task = (await store.task(id))!;
      expect(task.state, AcquisitionState.waiting);
      expect(task.candidate.link, b.candidates.single.link);
      final failure = task.failures.single;
      expect(failure.candidate, 0);
      expect(failure.problem, PublicationProblem.challenge);
    },
  );
}
