import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/app/product_app.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/platform/platform_services.dart';
import 'package:zero_player/features/books/application/book_site_checks.dart';
import 'package:zero_player/features/books/data/book_site_inspection.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';

import '../../test_support/fake_player_engine.dart';
import '../../test_support/verified_temp_directory.dart';

const _verifiedAsset = 'assets/catalogs/books/verified.json';

void main() {
  for (final hasSavedSample in [false, true]) {
    testWidgets(
      'full app starts and closes promptly ${hasSavedSample ? 'with a saved sample' : 'without saved samples'}',
      (tester) async {
        late VerifiedTempDirectory temp;
        late AppServices services;
        late BookSource source;
        String? priorRevision;
        Object? observedDuringClose;
        String? revisionDuringClose;
        await tester.runAsync(() async {
          temp = await VerifiedTempDirectory.create('book-site-startup-ui-');
          services = AppServices.scoped(
            temp.directory,
            AppDatabase.memory(),
            radioEngine: FakePlayerEngine.new,
            platform: PlatformServices(applyFullscreen: (_, _) async {}),
          );
          await services.supervision.load();
          await services.settings.load();
          await services.settings.update({
            'navigationGuideSeen': true,
            'recommendation': 'off',
            'backgroundProbe': false,
          });
          if (hasSavedSample) {
            source = BookSource.fromJson({
              'name': '启动样本',
              'kind': 'text',
              'format': 'feed',
              'url': 'https://startup-sample.example/feed',
              'sourceKey': 'fixture:startup-sample',
            });
            final store = services.books.store;
            await store.writeImported([(source: source, previous: null)]);
            priorRevision = await store.siteRevisions.get(source.id);
            await store.write(
              'books_site_check:${source.id}',
              BookSiteCheck.after(
                const BookSiteInspection(BookSiteFinding.sampled),
                DateTime.now(),
                source,
                null,
                siteRevision: priorRevision,
              ).toJson(),
            );
            services.addCloseHook(() async {
              observedDuringClose = await store.read(
                'books_site_observed_fingerprint:${source.id}',
              );
              revisionDuringClose = await store.siteRevisions.get(source.id);
            });
          }
        });
        var assetReads = 0;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        rootBundle.evict(_verifiedAsset);
        messenger.setMockMessageHandler('flutter/assets', (message) {
          if (message != null &&
              utf8.decode(Uint8List.sublistView(message)) == _verifiedAsset) {
            assetReads++;
          }
          return messenger.delegate.send('flutter/assets', message) ??
              Future.value(null);
        });
        addTearDown(() {
          messenger.setMockMessageHandler('flutter/assets', null);
          rootBundle.evict(_verifiedAsset);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: const ProductApp(),
          ),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        Object? closeFailure;
        StackTrace? closeStack;
        final closing = services.close().then<void>(
          (_) => closed = true,
          onError: (Object error, StackTrace stack) {
            closeFailure = error;
            closeStack = stack;
            closed = true;
          },
        );
        addTearDown(() async {
          if (closed) await tester.runAsync(temp.delete);
        });
        for (var i = 0; i < 400 && !closed; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(closed, isTrue, reason: 'application resources must close');
        await closing;
        if (closeFailure != null) {
          Error.throwWithStackTrace(closeFailure!, closeStack!);
        }
        if (hasSavedSample) {
          expect(assetReads, 1);
          expect(observedDuringClose, {
            'fingerprint': bookSourceCheckFingerprint(source),
            'inspectionRevision': bookSiteInspectionRevision,
          });
          expect(revisionDuringClose, isNot(priorRevision));
        } else {
          expect(assetReads, 0);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
