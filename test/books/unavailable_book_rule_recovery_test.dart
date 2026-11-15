import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an unavailable old novel rule can be manually replaced while disabled',
    () async {
      final archive = await File(
        'assets/catalogs/books/legado/catalog.json.bz2',
      ).readAsBytes();
      final records =
          (jsonDecode(utf8.decode(BZip2Decoder().decodeBytes(archive)))
                  as Map)['records']
              as List;
      final old = parseBookSourceRecord(records[2451]);
      expect(
        old.id,
        'be6ee767dad9892aa5a286ba08866f11c2b8e6b04f580878f753daaea048f61c',
      );
      expect(knownUnavailableBookRule(old), isTrue);
      expect(quarantinedBookSource(old), isTrue);
      expect(quarantinedBookSourceId(old.id), isTrue);
      expect(quarantinedBookHost(old.endpoint.host), isFalse);
      final revised = BookSource.fromJson({
        ...old.toJson(),
        'legado': {...old.legado!.toJson(), 'search': '/search?q={{key}}'},
      });
      expect(revised.id, old.id);
      expect(knownUnavailableBookRule(revised), isFalse);
      expect(quarantinedBookSource(revised), isFalse);

      final root = await Directory.systemTemp.createTemp('unavailable-rule-');
      final services = AppServices.scoped(root, AppDatabase.memory());
      addTearDown(() async {
        await services.close();
        await root.delete(recursive: true);
      });
      await services.settings.load();
      await services.supervision.load();
      expect((await services.books.importSources([old])).skipped, 1);
      await services.books.store.write('books_source:${old.id}', {
        'source': old.toJson(),
        'enabled': true,
        'favorite': true,
        'group': '珍藏',
      });
      await services.books.refreshSourceRisks();
      final changes = await services.books.importSources([revised]);
      expect(changes.updated, 1);
      final saved = (await services.books.store.source(null, old.id))!;
      expect(saved.enabled, isFalse);
      expect(saved.favorite, isTrue);
      expect(saved.group, '珍藏');
      expect(knownUnavailableBookRule(saved.source), isFalse);
    },
  );
}
