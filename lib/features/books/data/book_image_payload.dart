import 'dart:typed_data';
import 'dart:ui' as ui;

/// Some Xinmanhua JPEG responses prepend an 80-byte publisher header.
/// Only unwrap the observed signature on the declared image host.
List<int> readableBookImageBytes(Uri uri, List<int> bytes) {
  if (uri.host != 'works.xinmanhua.net' || bytes.length < 84) return bytes;
  const prefix = 'http://www.xinmanhua.net';
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix.codeUnitAt(i)) return bytes;
  }
  if (bytes[80] != 0xff || bytes[81] != 0xd8 || bytes[82] != 0xff) {
    throw const FormatException('新漫画图片编码格式未知');
  }
  return bytes.sublist(80);
}

/// Decodes a source probe image so a mislabeled or corrupt payload is not
/// reported as a readable comic chapter.
Future<void> validateReadableBookImage(Uri uri, List<int> payload) async {
  final bytes = readableBookImageBytes(uri, payload);
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    Uint8List.fromList(bytes),
  );
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height > 24000000) {
        throw const FormatException('章节图片像素超过限制');
      }
      final codec = await descriptor.instantiateCodec(targetWidth: 256);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('章节图片格式无法解码');
  } finally {
    buffer.dispose();
  }
}
