import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/publications/application/publication_collections.dart';
import 'package:zero_player/features/publications/data/publication_http.dart';
import 'package:zero_player/features/publications/data/publication_list_import.dart';
import 'package:zero_player/features/publications/data/publication_store.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/domain/publication_library.dart';

import '../../test_support/publication_catalogue_fixture.dart';

const _douban = '''
<div id="content"><h1>技术阅读</h1>
  <div class="doulist-item"><div class="doulist-subject">
    <div class="title"><a href="https://book.douban.com/subject/123/?ref=share">编程</a></div>
    <div class="abstract">作者: 李明
    <br>出版社: 示例</div>
  </div></div>
</div>
''';

const _weRead = '''
<h1 class="booklist_header_title">微信书单</h1>
<ul class="booklist_books"><li><div class="booklist_book">
  <div class="booklist_book_title">设计</div>
  <div class="booklist_book_author">王明</div>
</div></li></ul>
''';

void main() {
  _importTests();
  _persistenceTests();
}

void _importTests() {
  if (const bool.fromEnvironment('RUN_PUBLICATION_LISTS_ONLINE')) {
    for (final address in const [
      'https://www.douban.com/doulist/125233805/',
      'https://weread.qq.com/misc/booklist/341281594_831M3grZg',
    ]) {
      test(
        'reads a public list via the application transport: $address',
        () async {
          final client = MediaHttpClient();
          addTearDown(client.close);
          final imported = await importPublicationList(
            PublicationHttp(client, authorize: (_) {}),
            address,
            CancellationToken(),
          );
          expect(imported.books, hasLength(12));
          expect(
            imported.books.every((book) => book.candidates.isEmpty),
            isTrue,
          );
          expect(
            imported.books.every((book) => book.author.isNotEmpty),
            isTrue,
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
  test(
    'imports public Douban pages in order and drops duplicate entries',
    () async {
      await withPublicationCatalogue(
        host: 'www.douban.com',
        respond: (request) async {
          final first = !request.uri.queryParameters.containsKey('start');
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            first
                ? '$_douban<div class="paginator"><span class="next"><a href="?start=25">后页</a></span></div>'
                : _douban,
          );
          await request.response.close();
        },
        (fixture) async {
          final client = MediaHttpClient();
          addTearDown(client.close);
          final imported = await importPublicationList(
            PublicationHttp(client, authorize: (_) {}),
            '分享书单 https://book.douban.com/doulist/456/?ref=share',
            CancellationToken(),
          );
          expect(imported.name, '技术阅读');
          expect(imported.books.single.author, '李明');
          expect(
            imported.books.single.page.toString(),
            'https://book.douban.com/subject/123/',
          );
          expect(imported.books.single.candidates, isEmpty);
          expect(fixture.requests.map((uri) => uri.queryParameters['start']), [
            null,
            '25',
          ]);
        },
      );
    },
  );

  test('parses WeRead public list without inventing file or book links', () {
    final uri = publicationListAddress(
      '【分享】https://weread.qq.com/misc/booklist/789_aBc。 ',
    );
    final parsed = parsePublicationListPage(uri, _weRead);
    expect(parsed.name, '微信书单');
    expect(parsed.books.single.title, '设计');
    expect(parsed.books.single.author, '王明');
    expect(parsed.books.single.page, isNull);
    expect(parsed.books.single.candidates, isEmpty);
    expect(
      () => publicationListAddress(
        'https://weread.qq.com.example.com/misc/booklist/789',
      ),
      throwsFormatException,
    );
  });
}

void _persistenceTests() {
  test(
    'book lists persist metadata and respect policy on reads and writes',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      var blocked = false;
      final store = PublicationStore(db);
      final collections = PublicationCollections(
        store,
        (text) => !blocked || !text.contains('编程'),
      );
      final book = parsePublicationListPage(
        publicationListAddress('https://www.douban.com/doulist/1234/'),
        _douban,
      ).books.single;
      await collections.createList('初始书单', books: [book]);
      final list = (await collections.lists()).single;
      expect(list.source, isNull);
      await collections.renameList(list, '阅读书单');
      await collections.add(list, book);
      expect(
        (await PublicationCollections(store, (_) => true).lists()).single.name,
        '阅读书单',
      );
      expect((await collections.items(list)).single.id, book.id);
      blocked = true;
      expect(await collections.items(list), isEmpty);
      await expectLater(
        collections.add(list, book),
        throwsA(isA<PublicationFailure>()),
      );
      await collections.deleteList(list);
      expect(await collections.lists(), isEmpty);
      expect(await db.rows('SELECT * FROM publication_list_items'), isEmpty);
    },
  );

  test('deleting a shelf group keeps the book and its reading status', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = PublicationStore(db);
    final collections = PublicationCollections(store, (_) => true);
    await collections.saveGroup('技术');
    final group = (await collections.groups()).single;
    await db.write(
      "INSERT INTO publication_files(digest,format,bytes) VALUES('digest','pdf',1)",
    );
    await db.write(
      "INSERT INTO publication_shelf(id,digest,added) VALUES('holding','digest',0)",
    );
    const holding = PublicationHolding(
      id: 'holding',
      edition: PublicationEdition(id: 'book', title: '编程'),
      digest: 'digest',
      format: PublicationFormat.pdf,
      bytes: 1,
      resident: false,
      kept: false,
      added: 0,
    );
    await collections.setFinished(holding, true);
    await collections.move(holding, group);
    await collections.saveGroup('专业', id: group.id);
    expect((await collections.groups()).single.name, '专业');
    await collections.deleteGroup(group);
    expect(await collections.groups(), isEmpty);
    final details = (await db.rows(
      'SELECT * FROM publication_shelf_details',
    )).single;
    expect(details['group_id'], isNull);
    expect(details['finished'], 1);
    expect(await db.rows('SELECT * FROM publication_shelf'), hasLength(1));
  });
}
