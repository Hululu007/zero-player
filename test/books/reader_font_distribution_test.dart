import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/document_client.dart';
import 'package:zero_player/core/network/media_http_client.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/reader_fonts.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';
import 'package:zero_player/features/settings/application/settings_controller.dart';
import 'package:zero_player/features/settings/data/backup_service.dart';
import 'package:zero_player/features/settings/domain/app_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _savedPreferences();
  _deviceFamilies();
}

void _savedPreferences() {
  test(
    'removed reader faces fall back without changing layout preferences',
    () {
      for (final family in ['NotoSansSC', 'NotoSerifSC']) {
        final saved = ReaderPreferences.fromJson({
          ...const ReaderPreferences(fontSize: 27, margin: 30).toJson(),
          'family': family,
        });
        expect(saved.family, 'system');
        expect(saved.fontSize, 27);
        expect(saved.margin, 30);
        expect(saved.bodyStyle.fontFamily, isNull);
        expect(
          const TextStyle(
            fontFamily: 'Xiaolai',
          ).merge(saved.bodyStyle).fontFamily,
          isNull,
        );
        expect(readerFontFamily(family), isNull);
      }
      expect(
        ReaderPreferences.fromJson({'family': 'Xiaolai'}).bodyStyle.fontFamily,
        'Xiaolai',
      );
    },
  );

  test(
    'existing font selections and backups restore using the system font',
    () async {
      final db = AppDatabase.memory();
      final settings = SettingsController(db);
      addTearDown(() async {
        settings.dispose();
        await db.close();
      });
      for (final font in ['notoSans', 'notoSerif']) {
        await db.write('INSERT OR REPLACE INTO settings VALUES(?,?)', [
          'font',
          jsonEncode(font),
        ]);
        await settings.load();
        expect(settings.value.font, 'system');
        expect(appFontFamily(settings.value.font), isNull);
        final backup = BackupService(db);
        final saved = await backup.preview(await backup.export());
        await settings.update({'font': 'xiaolai'});
        await backup.restore(saved);
        await settings.load();
        expect(settings.value.font, 'system');
      }
      await expectLater(
        settings.update({'font': 'unknown'}),
        throwsFormatException,
      );
    },
  );
}

void _deviceFamilies() {
  const channel = MethodChannel('zero_player/reader_fonts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MediaHttpClient http;
  late ReaderFontStore store;
  setUp(() {
    http = MediaHttpClient();
    store = ReaderFontStore(Directory.systemTemp, DocumentClient(http));
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    http.close();
  });
  test(
    'concurrent enumeration and selection share one device font snapshot',
    () async {
      var calls = 0;
      final available = Completer<List<String>>();
      messenger.setMockMethodCallHandler(channel, (_) {
        calls++;
        return available.future;
      });
      final first = store.systemFamilies();
      final second = store.systemFamilies();
      available.complete(['Device Serif', '', 'Device Sans', 'Device Serif']);
      final expected = ['Device Sans', 'Device Serif'];
      expect(await first, expected);
      expect(await second, expected);
      expect(await store.ensure('system:Device Serif'), isTrue);
      expect(await store.ensure('system:Missing'), isFalse);
      expect(calls, 1);
    },
  );
  test(
    'failed enumeration can retry and system default remains usable',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (++calls == 1) {
          throw PlatformException(code: 'temporarily-unavailable');
        }
        return ['Device Sans'];
      });
      expect(await store.systemFamilies(), isEmpty);
      expect(await store.ensure('system'), isTrue);
      expect(await store.ensure('system:Device Sans'), isTrue);
      expect(calls, 2);
    },
  );
}
