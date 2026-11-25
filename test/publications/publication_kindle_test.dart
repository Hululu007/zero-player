import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/publications/data/publication_documents.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/data/publication_zip.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

import '../../test_support/local_book_fixtures.dart';

void main() {
  test('MOBI, AZW and AZW3 enter the same content checks as EPUB', () async {
    final directory = await Directory.systemTemp.createTemp('zero-kindle-');
    addTearDown(() => directory.delete(recursive: true));
    for (final fileFormat in [
      PublicationFormat.mobi,
      PublicationFormat.azw,
      PublicationFormat.azw3,
    ]) {
      final file = File('${directory.path}/example.${fileFormat.name}');
      await file.writeAsBytes(
        sampleKindle(kf8: fileFormat == PublicationFormat.azw3),
      );
      final detected = await detectPublicationFormat(file);
      expect(fileFormat.accepts(detected), isTrue);
      expect(PublicationFormat.pdf.accepts(detected), isFalse);
      final scanned = <String>[];
      final result = await admitPublication(
        file,
        fileFormat,
        'example.${fileFormat.name}',
        CancellationToken(),
        authorize: scanned.add,
        prepareReader: true,
      );
      expect(result.title, 'Kindle 格式示例');
      expect(result.hasText, isTrue);
      expect(
        result.richSections!.map((part) => part.text).join(),
        contains('续读位置示例'),
      );
      expect(scanned.any((text) => text.contains('电子书格式测试正文')), isTrue);
    }
  });

  test(
    'ZIP can extract a Kindle file and DRM admission reports its cause',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zero-kindle-zip-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final kindle = sampleKindle(protected: true);
      final archive = Archive()
        ..addFile(ArchiveFile('book.azw', kindle.length, kindle));
      final zip = await File(
        '${directory.path}/book.zip',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final entry = (await PublicationZip.inspect(zip)).single;
      expect(entry.format, PublicationFormat.azw);
      final target = File('${directory.path}/book.azw');
      await PublicationZip.extract(zip, entry, target, CancellationToken());
      expect(await target.readAsBytes(), kindle);
      await expectLater(
        admitPublication(
          target,
          entry.format,
          entry.path,
          CancellationToken(),
          authorize: (_) => fail('protected content was offered for admission'),
        ),
        throwsA(
          isA<PublicationFailure>().having(
            (failure) => failure.problem,
            'problem',
            PublicationProblem.ebookProtection,
          ),
        ),
      );
    },
  );
}
