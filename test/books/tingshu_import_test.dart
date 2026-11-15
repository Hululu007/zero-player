import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_import.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  test('TingShu plugin manifests are rejected with a clear format error', () {
    expect(
      () => parseBookSources(
        jsonEncode({
          'version': 2,
          'entry_package': 'sources_by_ting29',
          'download_url': 'https://example.test/sources.jar',
        }),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('JAR 插件订阅'),
        ),
      ),
    );
  });

  test('TingShu DEX jars are rejected with a clear format error', () {
    final archive = Archive()
      ..addFile(ArchiveFile('classes.dex', 3, [0x64, 0x65, 0x78]));
    expect(
      () => parseBookSourceBytes(ZipEncoder().encode(archive)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('JAR 插件'),
        ),
      ),
    );
  });

  test('ShuYin API adapter is bound to its reviewed HTTPS endpoint', () {
    Map<String, Object> source(String url) => {
      'name': '书音FM',
      'kind': 'audio',
      'format': 'shuyin',
      'url': url,
    };
    expect(
      BookSource.fromJson(
        source('https://m.mekui.com/ecmsapi/index.php'),
      ).format,
      BookFormat.shuyin,
    );
    expect(
      () =>
          BookSource.fromJson(source('https://example.test/ecmsapi/index.php')),
      throwsFormatException,
    );
  });

  test('BoKan adapter is bound to the reviewed publisher endpoint', () {
    Map<String, Object> source(String url) => {
      'name': '博看有声',
      'kind': 'audio',
      'format': 'bookan',
      'url': url,
      'mediaHosts': ['audio.bookan.com.cn'],
    };
    expect(
      BookSource.fromJson(
        source('https://api.bookan.com.cn/voice/book/list'),
      ).format,
      BookFormat.bookan,
    );
    expect(
      () => BookSource.fromJson(source('https://example.test/voice/book/list')),
      throwsFormatException,
    );
  });

  test('Ximalaya adapter is bound to the reviewed publisher endpoint', () {
    Map<String, Object> source(String url) => {
      'name': '喜马拉雅 · 免费有声',
      'kind': 'audio',
      'format': 'ximalaya',
      'url': url,
      'mediaHosts': ['aod.cos.tx.xmcdn.com'],
    };
    expect(
      BookSource.fromJson(
        source('https://mobile.ximalaya.com/mobile/v1/album/track'),
      ).format,
      BookFormat.ximalaya,
    );
    expect(
      () => BookSource.fromJson(
        source('https://example.test/mobile/v1/album/track'),
      ),
      throwsFormatException,
    );
  });

  test('Lit2Go adapter is bound to the reviewed publisher endpoint', () {
    Map<String, Object> source(String url) => {
      'name': 'Lit2Go 公版有声书',
      'kind': 'audio',
      'format': 'lit2go',
      'url': url,
    };
    expect(
      BookSource.fromJson(source('https://etc.usf.edu/lit2go/books/')).format,
      BookFormat.lit2go,
    );
    expect(
      () => BookSource.fromJson(source('https://example.test/lit2go/books/')),
      throwsFormatException,
    );
  });
}
