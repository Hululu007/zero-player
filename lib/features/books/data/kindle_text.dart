import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart' as kindle;

const _maxText = 16 << 20;
const _maxCompressedRecord = 64 << 10;
const invalidKindle = FormatException('Kindle 电子书的记录损坏或超过大小限制');

Uint8List decodeKindleText(kindle.PdbFile file, kindle.KindleSection section) {
  final header = section.palmDoc;
  final recordSize = header.maxRecordSize;
  final count = header.textRecordCount;
  if (count <= 0 ||
      count >= file.records.length ||
      count > 8192 ||
      recordSize < 1 ||
      recordSize > 32768 ||
      header.textLength < 1 ||
      header.textLength > _maxText) {
    throw invalidKindle;
  }
  final huffman = header.compression == kindle.CompressionType.huffCdic
      ? _KindleHuffman.read(file.records, section.mobi, recordSize)
      : null;
  final output = BytesBuilder(copy: false);
  final limit = math.min(_maxText, header.textLength + recordSize);
  for (final record in file.records.skip(1).take(count)) {
    if (record.length > _maxCompressedRecord) throw invalidKindle;
    final payload = kindle.stripTrailingDataEntries(
      record.data,
      section.mobi.extraDataFlags,
    );
    final bytes = switch (header.compression) {
      kindle.CompressionType.none => payload,
      kindle.CompressionType.palmDoc => kindle.decompressPalmDoc(payload),
      kindle.CompressionType.huffCdic => huffman!.expand(payload),
    };
    if (bytes.length > recordSize || output.length + bytes.length > limit) {
      throw invalidKindle;
    }
    output.add(bytes);
  }
  if (output.length < header.textLength) throw invalidKindle;
  return output.takeBytes();
}

/// Decode with limits on each expansion and on retained dictionary phrases.
final class _KindleHuffman {
  _KindleHuffman(this.codes, this.dictionary, this.recordSize);

  factory _KindleHuffman.read(
    List<kindle.PdbRecord> records,
    kindle.MobiHeader header,
    int recordSize,
  ) {
    final offset = header.huffmanRecordOffset;
    final count = header.huffmanRecordCount;
    if (offset < 1 ||
        count < 2 ||
        count > 128 ||
        offset + count > records.length) {
      throw invalidKindle;
    }
    final dictionaryRecords = [
      for (var i = offset + 1; i < offset + count; i++) records[i].data,
    ];
    for (final data in dictionaryRecords) {
      if (data.length < 16 || data.length > 256 << 10) throw invalidKindle;
      final header = ByteData.sublistView(data);
      if (header.getUint32(8) > 65536 || header.getUint32(12) > 16) {
        throw invalidKindle;
      }
    }
    return _KindleHuffman(
      kindle.HuffTable.parse(records[offset].data),
      kindle.CdicTable.parse(dictionaryRecords),
      recordSize,
    );
  }

  final kindle.HuffTable codes;
  final kindle.CdicTable dictionary;
  final int recordSize;
  final _expanding = <int>{};
  int _expandedBytes = 0;

  Uint8List expand(Uint8List data) {
    final output = BytesBuilder(copy: false);
    final end = data.length * 8;
    for (var offset = 0; offset < end;) {
      final code = _peekCode(data, offset);
      final prefix = codes.cache[code >>> 24];
      var width = prefix.codeLen;
      if (!prefix.terminal) {
        while (width < 32 && code < codes.minCode[width]) {
          width++;
        }
      }
      offset += width;
      if (offset > end) break;
      final ceiling = prefix.terminal
          ? prefix.maxCode
          : codes.maxCodeByLen[width];
      if (code > ceiling) throw invalidKindle;
      final index = (ceiling - code) >>> (32 - width);
      final bytes = _phrase(index);
      if (output.length + bytes.length > recordSize) throw invalidKindle;
      output.add(bytes);
    }
    return output.takeBytes();
  }

  Uint8List _phrase(int index) {
    if (index >= dictionary.entries.length) throw invalidKindle;
    final phrase = dictionary.entries[index];
    if (!phrase.precoded) {
      if (_expanding.length >= 32 || !_expanding.add(index)) {
        throw invalidKindle;
      }
      final bytes = expand(phrase.bytes);
      _expanding.remove(index);
      _expandedBytes += bytes.length;
      if (_expandedBytes > _maxText) throw invalidKindle;
      phrase.bytes = bytes;
      phrase.precoded = true;
    }
    return phrase.bytes;
  }

  int _peekCode(Uint8List bytes, int offset) {
    final start = offset ~/ 8;
    var window = 0;
    for (var index = start; index < start + 5; index++) {
      window = (window << 8) | (index < bytes.length ? bytes[index] : 0);
    }
    return (window >>> (8 - offset % 8)) & 0xffffffff;
  }
}
