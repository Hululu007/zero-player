import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/aoaostar_book_catalog.dart';
import 'package:zero_player/features/books/domain/book_source_risk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every audited adult-labelled source remains classified after deduplication',
    () async {
      final evidence =
          jsonDecode(
                await File(
                  'test_support/book_source_audit/legado-adult-label-evidence-20261115.json',
                ).readAsString(),
              )
              as Map;
      final catalog = await AoaoStarBookCatalog.load();
      expect(catalog.revision, evidence['archive_sha256']);
      final parsed = await catalog.read();
      final sources = {for (final source in parsed.sources) source.id: source};
      final audited = evidence['sources'] as List;
      expect(audited, hasLength(76));
      for (final row in audited.cast<Map>()) {
        final source = sources[row['id']];
        expect(source, isNotNull, reason: 'missing audited ID ${row['id']}');
        expect(
          adultBookSource(source!),
          isTrue,
          reason: 'adult evidence lost for ID ${row['id']}',
        );
      }
    },
  );

  test(
    'adult homepages classify bundled sources without banning sibling hosts',
    () async {
      final catalog = await AoaoStarBookCatalog.load();
      final parsed = await catalog.read();
      final sources = {for (final source in parsed.sources) source.id: source};
      for (final id in [
        '8a50f3982968b6a4b1e1ef2be0887fd3f8da48d4405e6eb3d8ef019e1b7b4258',
        '0ba76fbf6c748adc69294457359db55320e2e6581a5fe0ef9a0814861e5f0118',
        'e136532d94328ec5666e422ef5074e20bd113ec540ec38ebe69c2f36042e52c4',
        '0f3f868f7933380bf52be58f4c7ed6b9692e55a8b48879ecfa48bc6f5824b562',
        '957611a166cbbb4351a77adc7474254329395e36f12d0d77c92c6b800971dab5',
        '8e393bdd08d04c9d2279a2275d985e902475d146e5d254c93849e1763d082a42',
        '319d40fca269b5ccc0d58b1d8869adc14d5c3c37166cce3e5d640c424d642de3',
        '128b51bdb267603d3b4bf9ddf4868e202548c1715e55afeca08951bb15807327',
        'b1803f3ab397cb24f36e65c2721cec2355ba5c0e239a4cf07aced32fc494c55f',
        'a0daa89eb8643ac8fb769df48e53392f56071fac6777dfb4ca8b9499fcbfbdc9',
      ]) {
        expect(sources[id], isNotNull, reason: id);
        expect(adultBookSource(sources[id]!), isTrue, reason: id);
      }
      expect(adultBookHost('www.sesebooks.com'), isFalse);
      expect(adultBookHost('po18wen.xyz'), isFalse);
      expect(adultBookHost('www.po18wen.xyz'), isFalse);
      expect(adultBookHost('xyuzhaiwu.xyz'), isFalse);
      expect(adultBookHost('www.rousewu.cc'), isFalse);
      expect(adultBookHost('m.aaread.club'), isTrue);
      expect(adultBookHost('www.aaread.club'), isFalse);
      for (final host in [
        'm.biquge.one',
        'm.ibbxs.com',
        'm.po18xs.com',
        'm.popofree.com',
        'm.qingrenyouxi.com',
        'm.wmp8.com',
        'm.xyuzhaiwu3.com',
        'www.aabook.cyou',
        'www.po18xs.com',
        'www.roushuwu.com',
        'www.rouwenwu12.com',
      ]) {
        expect(adultBookHost(host), isTrue, reason: host);
      }
      expect(adultBookHost('aabook.cyou'), isFalse);
      expect(adultBookHost('ibbxs.com'), isFalse);
      expect(adultBookHost('biquge.one'), isFalse);
    },
  );
}
