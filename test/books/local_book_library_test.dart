import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/data/local_book_library.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/supervision/application/content_policy.dart';
import 'package:zero_player/features/supervision/application/supervision_controller.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/local_book_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _importTests();
  _authorizationTest();
}

void _importTests() {
  test('TXT imports without app services and keeps content identity', () async {
    final fixture = await _Fixture.create();
    final first = await fixture.library.importLocal(
      await File('${fixture.root.path}/first.txt').writeAsString('第一章\n普通正文'),
    );
    final second = await fixture.library.importLocal(
      await File('${fixture.root.path}/renamed.txt').writeAsString('第一章\n普通正文'),
    );
    expect(first.id, second.id);
    final entry = await fixture.store.entry(second);
    expect(entry!.favorite, isTrue);
    expect(
      await fixture.store.text(second, entry.chapters.single),
      contains('普通正文'),
    );
    expect(await fixture.library.documents.exists(), isFalse);
  });

  test(
    'EPUB owns its document, cleans staging and removes local data',
    () async {
      final fixture = await _Fixture.create();
      final bytes = sampleEpub();
      final input = await File(
        '${fixture.root.path}/sample.epub',
      ).writeAsBytes(bytes);
      final book = await fixture.library.importLocal(input);
      final document = fixture.library.documentFile(book, 'epub');
      expect(await document.readAsBytes(), bytes);
      expect(
        await fixture.library.documents
            .list()
            .map((file) => file.path)
            .toList(),
        [document.path],
      );
      await fixture.library.removeLocalBook(book);
      expect(await fixture.store.entry(book), isNull);
      expect(await fixture.store.savedText(book), isEmpty);
      expect(await document.exists(), isFalse);
      expect(await input.exists(), isTrue);
    },
  );

  test(
    'content filtering remains enforced with an accepting work predicate',
    () async {
      final fixture = await _Fixture.create();
      final file = await File(
        '${fixture.root.path}/sample.txt',
      ).writeAsString('第一章\n含有色情标记的测试正文');
      await expectLater(
        fixture.library.importLocal(file),
        throwsA(isA<ContentBlocked>()),
      );
      expect(await fixture.store.shelf(), isEmpty);
    },
  );
}

void _authorizationTest() {
  test(
    'authorization revoked while awaiting the transaction leaves no data',
    () async {
      final fixture = await _Fixture.create();
      final entered = Completer<void>();
      final release = Completer<void>();
      final hold = fixture.db.atomic(() async {
        entered.complete();
        await release.future;
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await hold;
      });
      await entered.future;
      final checked = Completer<void>();
      var allowed = true;
      fixture.library = LocalBookLibrary(
        store: fixture.store,
        documents: fixture.library.documents,
        policy: fixture.policy,
        bookAllowed: (_) {
          if (!checked.isCompleted) checked.complete();
          return allowed;
        },
      );
      final file = await File(
        '${fixture.root.path}/sample.txt',
      ).writeAsString('普通正文');
      final importing = expectLater(
        fixture.library.importLocal(file),
        throwsA(isA<ContentBlocked>()),
      );
      await checked.future;
      allowed = false;
      release.complete();
      await hold;
      await importing;
      expect(await fixture.store.shelf(), isEmpty);
      expect(
        await fixture.db.rows(
          "SELECT * FROM app_meta WHERE key GLOB 'books_text:*'",
        ),
        isEmpty,
      );
    },
  );
}

final class _Fixture {
  _Fixture(this.root, this.db, this.settings, this.supervision, this.policy)
    : store = BookStore(db) {
    library = LocalBookLibrary(
      store: store,
      documents: Directory('${root.path}/documents'),
      policy: policy,
      bookAllowed: (_) => true,
    );
  }

  final Directory root;
  final AppDatabase db;
  final SettingsController settings;
  final SupervisionController supervision;
  final ContentPolicy policy;
  final BookStore store;
  late LocalBookLibrary library;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('local-book-library-');
    final db = AppDatabase.memory();
    final settings = SettingsController(db);
    final supervision = SupervisionController(db);
    final policy = ContentPolicy(settings, supervision);
    final fixture = _Fixture(root, db, settings, supervision, policy);
    addTearDown(() async {
      policy.dispose();
      supervision.dispose();
      settings.dispose();
      await db.close();
      await root.delete(recursive: true);
    });
    await settings.load();
    await supervision.load();
    return fixture;
  }
}
