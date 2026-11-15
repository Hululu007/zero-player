import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

const _sourceId =
    '9671fd3cfe8189b9abdcb097cbff01609ff14c7ab43dcf7aa10d48a34a526a05';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled record 1803 is blocked without blocking real Lofter sources',
    () async {
      final source = await _source1803();
      expect(source.id, _sourceId);
      expect(source.endpoint.host, 'newsmiss.lofter.com1');
      expect(quarantinedBookSource(source), isTrue);
      expect(quarantinedBookSourceId(source.id), isTrue);
      expect(quarantinedBookHost(source.endpoint.host), isFalse);
      for (final host in [
        'api.lofter.com',
        'newsmiss.lofter.com',
        'www.lofter.com',
      ]) {
        final other = BookSource.fromJson({
          ...source.toJson(),
          'url': 'https://$host/',
        });
        expect(other.id, isNot(source.id));
        expect(quarantinedBookHost(host), isFalse);
        expect(quarantinedBookSource(other), isFalse, reason: host);
      }
      final separateId = BookSource.fromJson({
        ...source.toJson(),
        'sourceKey': 'another-source',
      });
      expect(separateId.id, isNot(source.id));
      expect(quarantinedBookSource(separateId), isFalse);
      final separateKind = BookSource.fromJson({
        ...source.toJson(),
        'kind': 'comic',
      });
      expect(separateKind.id, isNot(source.id));
      expect(quarantinedBookSource(separateKind), isFalse);
      final alternate = _sameIdDifferentEndpoint(source);
      expect(alternate.id, source.id);
      expect(alternate.endpoint, isNot(source.endpoint));
      expect(quarantinedBookSource(alternate), isFalse);
    },
  );

  test(
    'import and existing or orphaned history are blocked without deleting offline data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'book-unavailable-source-',
      );
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.db.write('INSERT OR REPLACE INTO app_meta VALUES(?,?)', [
        installationAccessKey,
        upgradedInstallationAccess,
      ]);
      await services.settings.load();
      await services.supervision.load();
      await services.settings.update({'filterAdult': false});
      final source = await _source1803();
      final changes = await services.books.importSources([source]);
      expect(changes.added, 0);
      expect(changes.skipped, 1);

      final book = Book(
        source.id,
        BookKind.text,
        '历史作品',
        '',
        Uri.parse('https://newsmiss.lofter.com/post/1'),
      );
      final chapter = BookChapter(
        '第一章',
        Uri.parse('https://newsmiss.lofter.com/post/1'),
      );
      await services.books.store.write('books_source:${source.id}', {
        'source': source.toJson(),
        'enabled': true,
      });
      await services.books.store.saveText(book, chapter, '原有离线正文');
      await services.books.refreshSourceRisks();
      expect(
        await services.books.sourceEntry(BookKind.text, source.id),
        isNull,
      );
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '原有离线正文');

      // Simulate an old shelf record after the corresponding source was removed.
      await services.books.store.deleteSource(source);
      await services.books.refreshSourceRisks();
      expect(services.books.bookAllowed(book), isFalse);
      await expectLater(
        services.books.readText(book, chapter, CancellationToken()),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await services.books.store.text(book, chapter), '原有离线正文');

      // A distinct endpoint with the same legacy ID is not a host-wide ban.
      final alternate = _sameIdDifferentEndpoint(source);
      await services.books.store.write('books_source:${alternate.id}', {
        'source': alternate.toJson(),
        'enabled': true,
      });
      await services.books.refreshSourceRisks();
      expect(services.books.sourceAllowed(alternate), isTrue);
      expect(services.books.bookAllowed(book), isTrue);
    },
  );
}

Future<BookSource> _source1803() async {
  final compressed = await File(
    'assets/catalogs/books/legado/catalog.json.bz2',
  ).readAsBytes();
  final data =
      jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(compressed))) as Map;
  return parseBookSourceRecord((data['records'] as List)[1803]);
}

BookSource _sameIdDifferentEndpoint(BookSource source) => BookSource.fromJson({
  ...source.toJson(),
  'url': source.endpoint
      .replace(host: 'www.${source.endpoint.host}')
      .toString(),
});
