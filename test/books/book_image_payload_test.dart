import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_image_payload.dart';

void main() {
  final host = Uri.parse('https://works.xinmanhua.net/273042737/1/w/1.jpg');
  final other = Uri.parse('https://images.example.test/1.jpg');
  final jpeg = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9];
  final prefix = List<int>.filled(80, 0xfe)
    ..setRange(
      0,
      'http://www.xinmanhua.net'.length,
      'http://www.xinmanhua.net'.codeUnits,
    );

  test('unwraps the verified Xinmanhua JPEG wrapper', () {
    expect(readableBookImageBytes(host, [...prefix, ...jpeg]), jpeg);
  });

  test('keeps ordinary JPEG and other media hosts unchanged', () {
    expect(readableBookImageBytes(host, jpeg), jpeg);
    expect(readableBookImageBytes(other, [...prefix, ...jpeg]), [
      ...prefix,
      ...jpeg,
    ]);
  });

  test('rejects an unknown wrapped payload', () {
    expect(
      () => readableBookImageBytes(host, [...prefix, ...List.filled(10, 0)]),
      throwsFormatException,
    );
  });

  test(
    'source probe decodes valid image and rejects a mislabeled payload',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
      );
      await validateReadableBookImage(other, png);
      await expectLater(
        validateReadableBookImage(other, 'not an image'.codeUnits),
        throwsFormatException,
      );
    },
  );
}
