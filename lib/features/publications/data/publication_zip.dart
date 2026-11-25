import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_transfer.dart';

typedef PublicationZipEntry = ({
  String path,
  PublicationFormat format,
  int bytes,
  bool encrypted,
});

final class PublicationZip {
  static const maxEntries = 1024;
  static const maxOutput = 640 << 20;

  static Future<List<PublicationZipEntry>> inspect(File file) => Isolate.run(
    () => _withZip(
      file.path,
      null,
      (_, entries) => [for (final (_, entry) in entries) ?entry],
    ),
  );

  static Future<void> extract(
    File file,
    PublicationZipEntry entry,
    File target,
    CancellationToken token, {
    String? password,
  }) async {
    token.check();
    if (entry.encrypted &&
        (password == null || password.isEmpty || password.length > 256)) {
      throw const PublicationFailure(PublicationProblem.zipPassword);
    }
    var success = false;
    try {
      await _extractOffThread((file.path, entry, target.path, password), token);
      token.check();
      if (!entry.format.accepts(await detectPublicationFormat(target))) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      success = true;
    } finally {
      if (!success && await target.exists()) await target.delete();
    }
  }
}

typedef _Extraction = (String, PublicationZipEntry, String, String?);
typedef _ZipRows = List<(ZipFileHeader, PublicationZipEntry?)>;

Future<void> _extractOffThread(
  _Extraction args,
  CancellationToken token,
) async {
  final events = ReceivePort();
  final exited = Completer<void>();
  PublicationProblem? failure;
  final listener = events.listen((message) {
    if (message == null) {
      if (!exited.isCompleted) exited.complete();
    } else if (message is String) {
      failure = PublicationProblem.values.byName(message);
    } else {
      failure = PublicationProblem.invalid;
    }
  });
  void Function()? unlink;
  try {
    final worker = await Isolate.spawn(
      _writeZipEntry,
      (args, events.sendPort),
      onExit: events.sendPort,
      onError: events.sendPort,
      errorsAreFatal: true,
    );
    unlink = token.listen(() => worker.kill(priority: Isolate.immediate));
    await exited.future;
    token.check();
    if (failure != null) throw PublicationFailure(failure!);
  } finally {
    unlink?.call();
    await listener.cancel();
    events.close();
  }
}

void _writeZipEntry((_Extraction, SendPort) request) {
  final ((source, entry, target, password), result) = request;
  try {
    // archive consumes the low byte of each code unit. Supply the UTF-8
    // password bytes explicitly so ZIP writers using UTF-8 interoperate.
    final encoded = password == null
        ? null
        : String.fromCharCodes(utf8.encode(password));
    _withZip(source, encoded, (input, rows) {
      final row = rows.where((row) => row.$2 == entry).firstOrNull;
      if (row == null) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      final header = row.$1;
      final member = header.file!;
      if (header.compressionMethod == 99) {
        _verifyZipAes(input, header, encoded!);
      }
      final output = OutputFileStream(target, bufferSize: 64 << 10);
      try {
        member.decompress(output);
        if (output.length != entry.bytes) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        // AE-2 relies on authentication rather than CRC. AE-1 includes both.
        if ((header.compressionMethod != 99 || header.crc32 != 0) &&
            _outputCrc(output) != header.crc32) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
      } finally {
        output.closeSync();
      }
    });
  } on PublicationFailure catch (error) {
    result.send(error.problem.name);
  } on ArchiveException catch (error) {
    result.send(
      (error.toString().toLowerCase().contains('password')
              ? PublicationProblem.zipPassword
              : PublicationProblem.invalid)
          .name,
    );
  } on FileSystemException {
    result.send(PublicationProblem.storage.name);
  }
}

int _outputCrc(OutputFileStream output) {
  var crc = 0;
  const window = 128 << 10;
  for (var offset = 0; offset < output.length; offset += window) {
    final end = (offset + window).clamp(0, output.length);
    crc = getCrc32(output.subset(offset, end), crc);
  }
  return crc;
}

T _withZip<T>(
  String path,
  String? password,
  T Function(InputFileStream, _ZipRows) action,
) {
  final input = InputFileStream(path);
  try {
    _checkZipEnd(input);
    final directory = ZipDirectory()..read(input, password: password);
    final headers = directory.fileHeaders;
    if (headers.isEmpty ||
        headers.length > PublicationZip.maxEntries ||
        headers.length != directory.totalCentralDirectoryEntries ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    var output = 0;
    final names = <String>{};
    final spans = <(int, int)>[];
    final rows = <(ZipFileHeader, PublicationZipEntry?)>[];
    for (final header in headers) {
      final path = header.filename;
      final file = header.file;
      final bytes = header.uncompressedSize;
      final format = PublicationFormat.fromName(path);
      final mode = (header.externalFileAttributes >> 16) & 0xf000;
      final key = path.toLowerCase().replaceFirst(RegExp(r'/$'), '');
      if (!_validPath(path) ||
          file == null ||
          path != file.filename ||
          !names.add(key) ||
          !const {0, 0x4000, 0x8000}.contains(mode) ||
          (header.externalFileAttributes & 0x400) != 0 ||
          bytes < 0 ||
          bytes > (format?.maxBytes ?? PublicationZip.maxOutput) ||
          header.diskNumberStart != 0 ||
          header.generalPurposeBitFlag != file.flags ||
          header.compressedSize < 0 ||
          (header.generalPurposeBitFlag & 0x2040) != 0 ||
          !const {0, 8, 99}.contains(header.compressionMethod)) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      final dataStart = _dataStart(input, header.localHeaderOffset, file);
      final end = dataStart + header.compressedSize;
      if (end > directory.centralDirectoryOffset) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      spans.add((header.localHeaderOffset, end));
      output += bytes;
      if (output > PublicationZip.maxOutput) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      rows.add((
        header,
        format == null ||
                format == PublicationFormat.zip ||
                bytes == 0 ||
                mode == 0x4000
            ? null
            : (
                path: path,
                format: format,
                bytes: bytes,
                encrypted: (file.flags & 1) != 0,
              ),
      ));
    }
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i - 1].$2 > spans[i].$1) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
    }
    return action(input, rows);
  } on RangeError {
    throw const PublicationFailure(PublicationProblem.invalid);
  } finally {
    input.closeSync();
  }
}

bool _validPath(String path) =>
    path.length <= 1024 &&
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !RegExp(r'[:\\\x00-\x1f\x7f]').hasMatch(path) &&
    !path
        .replaceFirst(RegExp(r'/$'), '')
        .split('/')
        .any(
          (segment) =>
              segment.isEmpty ||
              segment == '.' ||
              segment == '..' ||
              segment.endsWith('.') ||
              segment.endsWith(' '),
        );

void _checkZipEnd(InputFileStream input) {
  final total = input.length;
  final start = (total - 65557).clamp(0, total);
  final tail = input.subset(position: start).toUint8List();
  final data = ByteData.sublistView(tail);
  for (var i = tail.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) != 0x06054b50 ||
        data.getUint16(i + 20, Endian.little) != tail.length - i - 22) {
      continue;
    }
    final count = data.getUint16(i + 10, Endian.little);
    final size = data.getUint32(i + 12, Endian.little);
    final offset = data.getUint32(i + 16, Endian.little);
    if (count > 0 &&
        count <= PublicationZip.maxEntries &&
        size <= 8 << 20 &&
        offset + size == start + i &&
        total <= PublicationFormat.zip.maxBytes) {
      return;
    }
    break;
  }
  throw const PublicationFailure(PublicationProblem.invalid);
}

int _dataStart(InputFileStream input, int offset, ZipFile file) {
  if (offset < 0 || offset + 30 > input.totalLength) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  final header = input.subset(position: offset, length: 30)..skip(26);
  final nameLength = header.readUint16();
  final extraLength = header.readUint16();
  if (nameLength == 0 || (file.extraField?.length ?? 0) != extraLength) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
  return offset + 30 + nameLength + extraLength;
}

/// Authenticate the full ciphertext before extraction. A deflate decoder can
/// finish at its end marker without requesting the final AES decoder chunk.
void _verifyZipAes(
  InputFileStream input,
  ZipFileHeader header,
  String password,
) {
  final stream = InputMemoryStream(header.file!.extraField ?? Uint8List(0));
  while (stream.length >= 4) {
    final kind = stream.readUint16();
    final length = stream.readUint16();
    if (length > stream.length) break;
    final record = stream.readBytes(length);
    if (kind != 0x9901 || length != 7) continue;
    final version = record.readUint16();
    final vendor = record.readString(size: 2);
    final strength = record.readByte();
    final method = record.readUint16();
    if (!const {1, 2}.contains(version) ||
        vendor != 'AE' ||
        !const {1, 2, 3}.contains(strength) ||
        !const {0, 8}.contains(method)) {
      break;
    }
    final saltSize = 4 * (strength + 1);
    final keySize = saltSize * 2;
    final raw = input.subset(
      position: _dataStart(input, header.localHeaderOffset, header.file!),
      length: header.compressedSize,
    );
    if (raw.length < saltSize + 12) break;
    final salt = raw.readBytes(saltSize).toUint8List();
    final verify = raw.readBytes(2).toUint8List();
    final key = ZipFile.deriveKey(password, salt, derivedKeyLength: keySize);
    if (!_same(verify, key.sublist(keySize * 2))) {
      throw const PublicationFailure(PublicationProblem.zipPassword);
    }
    final output = _Mac();
    final sink = Hmac(
      sha1,
      key.sublist(keySize, keySize * 2),
    ).startChunkedConversion(output);
    while (raw.length > 10) {
      sink.add(
        raw.readBytes((raw.length - 10).clamp(0, 64 << 10)).toUint8List(),
      );
    }
    sink.close();
    if (!_same(raw.toUint8List(), output.digest!.bytes.take(10).toList())) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return;
  }
  throw const PublicationFailure(PublicationProblem.unsupported);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var bits = 0;
  for (var i = 0; i < a.length; i++) {
    bits |= a[i] ^ b[i];
  }
  return bits == 0;
}

final class _Mac implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}
