import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/media_http_client.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_space.dart';
import 'publication_website_markup.dart';
import 'publication_website_target.dart';

typedef TransferProgress = Future<void> Function(int received, int? total);
typedef _Slice = ({int start, int end});

final class PublicationTransfer {
  PublicationTransfer(this.http, this.space);
  final PublicationHttp http;
  final PublicationSpace space;
  static const sliceBytes = 4 << 20;
  static const workers = 3;

  File part(String id) =>
      File(p.join(space.taskDirectory(id).path, 'download.part'));

  Future<File> download(
    String id,
    AcquisitionCandidate candidate,
    PublicationDownload source,
    CancellationToken token,
    TransferProgress progress,
    void Function() authorize, {
    bool allowRanges = true,
  }) async {
    final path = part(id);
    await path.parent.create(recursive: true);
    final retained = source.takeResponse;
    final probeRange =
        allowRanges &&
        (!source.preferWhole ||
            (await space.store.db.rows(
              'SELECT 1 FROM publication_transfer WHERE task=?',
              [id],
            )).isNotEmpty);
    final probe =
        retained?.call(token) ??
        await _open(
          source.uri,
          source,
          token,
          range: probeRange ? 'bytes=0-0' : null,
        );
    try {
      if (retained != null) {
        try {
          token.check();
          validatePublicationAddress(
            probe.uri,
            allowLoopback: http.allowLoopback,
          );
          http.authorize(probe.uri);
          source.scope?.call(probe.uri);
        } catch (_) {
          await discardPublicationResponse(probe);
          rethrow;
        }
      }
      if (source.detectGuestQuota &&
          const {200, 401, 403, 429}.contains(probe.response.statusCode) &&
          publicationSameWebsite(source.uri, probe.uri) &&
          publicationWebsiteHtml(
            probe.response.headers.contentType?.mimeType,
          )) {
        throw await _websiteRefusal(probe, source, token);
      }
      if (source.guest != null &&
          probe.response.headers.contentType?.mimeType == 'text/html') {
        await discardPublicationResponse(probe);
        throw const PublicationFailure(PublicationProblem.challenge);
      }
      int? observedLength;
      final chunkBytes = source.rangeChunkBytes ?? sliceBytes;
      if (retained != null ||
          !allowRanges ||
          probe.response.statusCode == 200) {
        final etag = source.preferWhole && allowRanges && retained == null
            ? _strongEtag(probe)
            : null;
        await _single(
          probe,
          path,
          id,
          candidate,
          token,
          progress,
          authorize,
          reconnect: etag != null && source.rangeTarget?.call(probe.uri) == true
              ? (start, end) => _openSlice(
                  source,
                  probe.uri,
                  start,
                  end,
                  end + 1,
                  etag,
                  token,
                )
              : null,
        );
      } else {
        observedLength = await _readProbe(probe, candidate, token);
        final status = probe.response.statusCode;
        final etag = _strongEtag(probe);
        var complete = false;
        if (observedLength != null &&
            etag != null &&
            observedLength > chunkBytes) {
          if (status == HttpStatus.requestedRangeNotSatisfiable) {
            complete = await _reuseCompleteRanges(
              path,
              id,
              _rangeIdentity(candidate, probe.uri, etag, observedLength),
              observedLength,
              chunkBytes,
              token,
              progress,
              authorize,
            );
          } else {
            try {
              await _ranges(
                path,
                id,
                candidate,
                source,
                probe.uri,
                observedLength,
                etag,
                token,
                progress,
                authorize,
              );
              complete = true;
            } on _BadRange {
              // Wait for all range workers before replacing the partial file.
            }
          }
        }
        if (!complete) {
          final whole = await _openWhole(
            source,
            token,
            candidate,
            probe.uri,
            status == HttpStatus.partialContent && observedLength != null
                ? etag
                : null,
            useProbedAddress: source.rangeChunkBytes != null,
          );
          await _single(whole, path, id, candidate, token, progress, authorize);
        }
      }
      final length = await path.length();
      _validateLength(candidate, length);
      if ((observedLength != null && length != observedLength) ||
          !candidate.format.accepts(await detectPublicationFormat(path))) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      final expected = candidate.digest;
      if (expected != null &&
          await publicationFileDigest(path, token) != expected) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      token.check();
      authorize();
      return path;
    } finally {
      await space.release(
        id,
        used: await path.exists() ? await path.length() : 0,
      );
    }
  }

  Future<PublicationFailure> _websiteRefusal(
    HttpPayload payload,
    PublicationDownload download,
    CancellationToken token,
  ) async {
    final fallback = publicationHttpFailure(payload);
    if (payload.response.headers.value('cf-mitigated') == 'challenge') {
      await discardPublicationResponse(payload);
      return fallback.problem == PublicationProblem.invalid
          ? const PublicationFailure(PublicationProblem.challenge)
          : fallback;
    }
    final String html;
    try {
      html = await http.readText(
        payload,
        token,
        maxBytes: 384 << 10,
        allowGzip: true,
        scope: download.scope,
        acceptedStatuses: const {200, 401, 403, 429},
      );
    } on FormatException {
      return fallback;
    } on PublicationFailure catch (error) {
      if (error.problem != PublicationProblem.invalid) rethrow;
      return fallback;
    }
    if (download.preferWhole &&
        payload.response.statusCode == HttpStatus.ok &&
        html.trim().isEmpty) {
      return const PublicationFailure(PublicationProblem.emptyResponse);
    }
    final page = parsePublicationWebsitePage(
      html,
      payload.uri,
      (uri) => publicationSameWebsite(download.uri, uri),
    );
    return page.guestLimited
        ? PublicationFailure(
            PublicationProblem.guestLimit,
            retryAt: fallback.retryAt,
          )
        : fallback;
  }

  Future<HttpPayload> _openWhole(
    PublicationDownload source,
    CancellationToken token,
    AcquisitionCandidate candidate,
    Uri probed,
    String? expectedEtag, {
    required bool useProbedAddress,
  }) async {
    // The first request can consume an anonymous download allowance. Reuse the
    // scoped file URL for the remaining requests and the full-file fallback.
    final response = await _open(
      useProbedAddress ? probed : source.uri,
      source,
      token,
    );
    if (response.response.statusCode == 200 && expectedEtag != null) {
      final actual = _strongEtag(response);
      if (response.uri.origin != probed.origin ||
          response.uri.path != probed.path ||
          (actual != expectedEtag &&
              (actual != null || candidate.digest == null))) {
        await discardPublicationResponse(response);
        throw const PublicationFailure(PublicationProblem.invalid);
      }
    }
    return response;
  }

  Future<HttpPayload> _open(
    Uri uri,
    PublicationDownload source,
    CancellationToken token, {
    String? range,
    String? etag,
  }) async {
    final response = await http.open(
      uri,
      token,
      scope: source.scope,
      guest: source.guest,
      referer: source.referer,
      range: range,
      ifRange: etag,
      rangeTarget: source.rangeTarget,
      mapRedirect: source.mapRedirect,
    );
    if (source.guest != null && response.response.statusCode == 412) {
      await discardPublicationResponse(response);
      throw const PublicationFailure(PublicationProblem.missing);
    }
    return response;
  }

  Future<int?> _readProbe(
    HttpPayload probe,
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) async {
    final status = probe.response.statusCode;
    if (status != 206) {
      await discardPublicationResponse(probe);
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        final length = _unsatisfiedLength(probe);
        if (length != null) _validateLength(candidate, length);
        return length;
      }
      throw publicationHttpFailure(probe);
    }
    final result = _responseRange(probe);
    if (result == null ||
        result.$1 != 0 ||
        result.$2 != 0 ||
        probe.response.contentLength != 1 ||
        !_binary(probe)) {
      await discardPublicationResponse(probe);
      return null;
    }
    var actual = 0;
    await for (final data in probe.body) {
      token.check();
      actual += data.length;
      if (actual > 1) return null;
    }
    if (actual != 1) return null;
    _validateLength(candidate, result.$3);
    return result.$3;
  }

  Future<void> _single(
    HttpPayload response,
    File path,
    String id,
    AcquisitionCandidate candidate,
    CancellationToken token,
    TransferProgress progress,
    void Function() authorize, {
    Future<HttpPayload> Function(int start, int end)? reconnect,
  }) async {
    RandomAccessFile? file;
    var subscribed = false;
    try {
      final receivedLength = response.response.contentLength;
      final total = receivedLength < 0 ? null : receivedLength;
      if (response.response.statusCode != 200) {
        throw publicationHttpFailure(response);
      }
      if (!_binary(response)) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      if (total != null) _validateLength(candidate, total);
      final maxBytes = candidate.format.maxBytes;
      final previous = await path.exists() ? await path.length() : 0;
      var allocation = max(
        previous,
        total ?? min(maxBytes, PublicationSpace.growthWindow),
      );
      await space.reserve(id, allocation, used: previous, authorize: authorize);
      authorize();
      file = await path.open(mode: FileMode.write);
      await _forget(id);
      await space.checkpoint(id, 0);
      await progress(0, total);
      var received = 0;
      final notice = Stopwatch()..start();
      subscribed = true;
      var retries = 0;
      while (true) {
        try {
          final payload = retries == 0
              ? response
              : await reconnect!(received, total! - 1);
          await for (final chunk in payload.body) {
            token.check();
            authorize();
            http.authorize(payload.uri);
            final next = received + chunk.length;
            if (next > maxBytes || (total != null && next > total)) {
              throw const PublicationFailure(PublicationProblem.invalid);
            }
            if (next > allocation) {
              await file.flush();
              await progress(received, total);
              allocation = min(
                maxBytes,
                max(next, allocation + PublicationSpace.growthWindow),
              );
              await space.reserve(
                id,
                allocation,
                used: received,
                authorize: authorize,
              );
            }
            await file.writeFrom(chunk);
            received = next;
            if (notice.elapsedMilliseconds >= 350) {
              notice.reset();
              await space.checkpoint(id, received);
              await progress(received, total);
            }
          }
          if (total != null && received != total) {
            throw PublicationFailure(
              reconnect == null
                  ? PublicationProblem.invalid
                  : PublicationProblem.network,
            );
          }
          break;
        } on Exception catch (error) {
          token.check();
          if (reconnect == null ||
              total == null ||
              received >= total ||
              error is FileSystemException ||
              !isPublicationNetworkFailure(error) ||
              retries >= 2) {
            rethrow;
          }
          retries++;
        }
      }
      await file.flush();
      await space.checkpoint(id, received);
      await progress(received, total ?? received);
    } finally {
      if (!subscribed) await discardPublicationResponse(response);
      await file?.close();
    }
  }

  Future<void> _ranges(
    File path,
    String id,
    AcquisitionCandidate candidate,
    PublicationDownload source,
    Uri uri,
    int length,
    String etag,
    CancellationToken token,
    TransferProgress progress,
    void Function() authorize,
  ) async {
    final pending = await _recover(
      path,
      id,
      _rangeIdentity(candidate, uri, etag, length),
      _plannedRanges(length, source.rangeChunkBytes ?? sliceBytes),
      token,
    );
    var received =
        length -
        pending.fold<int>(
          0,
          (total, item) => total + item.end - item.start + 1,
        );
    try {
      await space.reserve(
        id,
        length,
        used: await path.exists() ? await path.length() : 0,
        authorize: authorize,
      );
    } on PublicationFailure catch (error) {
      if (error.problem == PublicationProblem.space) {
        await progress(received, length);
      }
      rethrow;
    }
    await progress(received, length);
    final file = await path.open(mode: FileMode.append);
    final writer = _RangeWriter(file);
    final run = CancellationToken();
    final unlink = token.listen(run.cancel);
    Object? failure;
    var next = 0;
    Future<void> work() async {
      while (!run.isCancelled && next < pending.length) {
        final slice = pending[next++];
        try {
          await _slice(
            source,
            uri,
            id,
            slice,
            length,
            etag,
            writer,
            run,
            authorize,
          );
          received += slice.end - slice.start + 1;
          await space.checkpoint(id, await writer.length());
          await progress(received, length);
        } catch (error) {
          failure ??= error;
          run.cancel();
        }
      }
    }

    try {
      await Future.wait(List.generate(workers, (_) => work()));
      token.check();
      if (failure case final Object error) throw error;
      if (await writer.length() != length || received != length) {
        throw const _BadRange();
      }
    } finally {
      unlink();
      await file.close();
    }
  }

  Future<void> _slice(
    PublicationDownload source,
    Uri uri,
    String id,
    _Slice slice,
    int total,
    String etag,
    _RangeWriter writer,
    CancellationToken token,
    void Function() authorize,
  ) async {
    var position = slice.start;
    Digest? digest;
    final hash = sha256.startChunkedConversion(
      _DigestSink((value) => digest = value),
    );
    var retries = 0;
    while (position <= slice.end) {
      try {
        final response = await _openSlice(
          source,
          uri,
          position,
          slice.end,
          total,
          etag,
          token,
        );
        await for (final chunk in response.body) {
          token.check();
          authorize();
          if (position + chunk.length > slice.end + 1) throw const _BadRange();
          await writer.write(position, chunk, token);
          position += chunk.length;
          hash.add(chunk);
        }
        if (position != slice.end + 1) {
          if (source.rangeChunkBytes == null) throw const _BadRange();
          throw const PublicationFailure(PublicationProblem.network);
        }
      } on Exception catch (error) {
        token.check();
        if (source.rangeChunkBytes == null ||
            retries++ >= 2 ||
            error is FileSystemException ||
            !isPublicationNetworkFailure(error)) {
          rethrow;
        }
      }
    }
    hash.close();
    await writer.flush();
    token.check();
    authorize();
    await space.store.db.write(
      'INSERT OR REPLACE INTO publication_ranges VALUES(?,?,?)',
      [id, slice.start, digest.toString()],
    );
  }

  Future<HttpPayload> _openSlice(
    PublicationDownload source,
    Uri uri,
    int start,
    int end,
    int total,
    String etag,
    CancellationToken token,
  ) async {
    final response = await _open(
      uri,
      source,
      token,
      range: 'bytes=$start-$end',
      etag: etag,
    );
    final size = end - start + 1;
    if (response.response.statusCode != 206 ||
        _responseRange(response) != (start, end, total) ||
        _strongEtag(response) != etag ||
        !_binary(response) ||
        response.response.contentLength != size ||
        response.uri.origin != uri.origin ||
        response.uri.path != uri.path) {
      await discardPublicationResponse(response);
      final status = response.response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        final length = _unsatisfiedLength(response);
        if (length != null && length != total) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
      }
      if (const {200, 206, 405, 416, 501}.contains(status)) {
        throw const _BadRange();
      }
      throw publicationHttpFailure(response);
    }
    return response;
  }

  Future<bool> _reuseCompleteRanges(
    File path,
    String id,
    String identity,
    int length,
    int chunkBytes,
    CancellationToken token,
    TransferProgress progress,
    void Function() authorize,
  ) async {
    final pending = await _recover(
      path,
      id,
      identity,
      _plannedRanges(length, chunkBytes),
      token,
      repair: false,
    );
    if (pending.isNotEmpty) return false;
    await progress(length, length);
    await space.reserve(id, length, used: length, authorize: authorize);
    return true;
  }

  Future<List<_Slice>> _recover(
    File part,
    String id,
    String identity,
    List<_Slice> slices,
    CancellationToken token, {
    bool repair = true,
  }) async {
    final db = space.store.db;
    final known = (await db.rows(
      'SELECT identity FROM publication_transfer WHERE task=?',
      [id],
    )).firstOrNull;
    if (known?['identity'] != identity ||
        !await part.exists() ||
        await part.length() > slices.last.end + 1) {
      if (!repair) return slices;
      await _forget(id);
      if (await part.exists()) await part.delete();
      await db.write('INSERT INTO publication_transfer VALUES(?,?)', [
        id,
        identity,
      ]);
      return slices;
    }
    final checkpoints = {
      for (final row in await db.rows(
        'SELECT start,digest FROM publication_ranges WHERE task=?',
        [id],
      ))
        row['start']: row['digest'],
    };
    final length = await part.length();
    final pending = <_Slice>[];
    for (final slice in slices) {
      token.check();
      final digest = checkpoints[slice.start];
      if (digest == null ||
          length <= slice.end ||
          await publicationFileDigest(
                part,
                token,
                start: slice.start,
                end: slice.end + 1,
              ) !=
              digest) {
        pending.add(slice);
        if (repair) {
          await db.write(
            'DELETE FROM publication_ranges WHERE task=? AND start=?',
            [id, slice.start],
          );
        }
      }
    }
    return pending;
  }

  Future<void> _forget(String id) => space.store.db.write(
    'DELETE FROM publication_transfer WHERE task=?',
    [id],
  );
}

String _rangeIdentity(
  AcquisitionCandidate candidate,
  Uri uri,
  String etag,
  int length,
) => publicationId('${candidate.id}\n${uri.origin}${uri.path}\n$etag\n$length');

List<_Slice> _plannedRanges(int length, int chunkBytes) => [
  for (var start = 0; start < length; start += chunkBytes)
    (start: start, end: min(start + chunkBytes, length) - 1),
];

final class _BadRange implements Exception {
  const _BadRange();
}

final class _DigestSink implements Sink<Digest> {
  const _DigestSink(this.receive);
  final void Function(Digest) receive;
  @override
  void add(Digest data) => receive(data);
  @override
  void close() {}
}

final class _RangeWriter {
  _RangeWriter(this.file);
  final RandomAccessFile file;
  Future<void> _tail = Future.value();
  Future<T> _serialize<T>(Future<T> Function() write) {
    final next = _tail.then((_) => write());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> write(int offset, List<int> bytes, CancellationToken token) =>
      _serialize(() async {
        token.check();
        await file.setPosition(offset);
        token.check();
        await file.writeFrom(bytes);
      });
  Future<void> flush() => _serialize(file.flush);
  Future<int> length() => _serialize(file.length);
}

bool _binary(HttpPayload response) {
  final mime = response.response.headers.contentType?.mimeType;
  return identityPublicationEncoding(response) &&
      mime != 'text/html' &&
      mime != 'text/plain' &&
      mime != 'application/json' &&
      mime != 'application/xhtml+xml' &&
      mime?.startsWith('image/') != true;
}

String? _strongEtag(HttpPayload response) {
  final value = response.response.headers.value('etag')?.trim();
  return value != null &&
          RegExp(r'^"[^"\x00-\x20\x7f]{1,248}"$').hasMatch(value)
      ? value
      : null;
}

(int, int, int)? _responseRange(HttpPayload response) {
  final header = response.response.headers.value('content-range');
  final match = RegExp(
    r'^bytes (\d{1,12})-(\d{1,12})/(\d{1,12})$',
  ).firstMatch(header ?? '');
  return match == null
      ? null
      : (int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
}

int? _unsatisfiedLength(HttpPayload response) {
  final headers = response.response.headers[HttpHeaders.contentRangeHeader];
  if (headers == null || headers.length != 1) return null;
  final match = RegExp(
    r'^bytes \*/(\d{1,12})$',
    caseSensitive: false,
  ).firstMatch(headers.single);
  return match == null ? null : int.parse(match[1]!);
}

void _validateLength(AcquisitionCandidate candidate, int bytes) {
  if (bytes <= 0 ||
      bytes > candidate.format.maxBytes ||
      (candidate.bytes != null && candidate.bytes != bytes)) {
    throw const PublicationFailure(PublicationProblem.invalid);
  }
}

Future<String> publicationFileDigest(
  File file,
  CancellationToken token, {
  int? start,
  int? end,
}) async {
  final digest = await sha256
      .bind(
        file.openRead(start, end).map((bytes) {
          token.check();
          return bytes;
        }),
      )
      .first;
  token.check();
  return digest.toString();
}

Future<PublicationFormat?> detectPublicationFormat(File file) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(128);
    if (bytes.length < 8) return null;
    if (String.fromCharCodes(bytes.take(5)) == '%PDF-') {
      return PublicationFormat.pdf;
    }
    if (bytes.length >= 86 &&
        String.fromCharCodes(bytes.sublist(60, 68)) == 'BOOKMOBI') {
      final header = ByteData.sublistView(bytes);
      final records = header.getUint16(76);
      final offset = header.getUint32(78);
      if (records < 2 ||
          offset < 78 + records * 8 ||
          offset + 40 > await handle.length()) {
        return null;
      }
      await handle.setPosition(offset);
      final record = await handle.read(40);
      if (record.length != 40 ||
          String.fromCharCodes(record.sublist(16, 20)) != 'MOBI') {
        return null;
      }
      return ByteData.sublistView(record).getUint32(36) >= 8
          ? PublicationFormat.azw3
          : PublicationFormat.mobi;
    }
    if (bytes.length < 30 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 3 ||
        bytes[3] != 4) {
      return null;
    }
    // A conforming EPUB has an uncompressed mimetype entry first.
    final nameLength = bytes[26] + 256 * bytes[27];
    final skip = bytes[28] + 256 * bytes[29];
    final end = 30 + nameLength + skip + 20;
    if (bytes.length >= end &&
        nameLength == 8 &&
        bytes[8] == 0 &&
        bytes[9] == 0 &&
        String.fromCharCodes(bytes.sublist(30, 38)) == 'mimetype' &&
        String.fromCharCodes(bytes.sublist(38 + skip, end)) ==
            'application/epub+zip') {
      return await _hasZipDirectory(handle) ? PublicationFormat.epub : null;
    }
    return PublicationFormat.zip;
  } finally {
    await handle.close();
  }
}

Future<bool> _hasZipDirectory(RandomAccessFile handle) async {
  const endRecordLength = 22;
  final length = await handle.length();
  final tailLength = min(length, endRecordLength + 65535);
  await handle.setPosition(length - tailLength);
  final tail = await handle.read(tailLength);
  for (var index = tail.length - endRecordLength; index >= 0; index--) {
    if (tail[index] != 0x50 ||
        tail[index + 1] != 0x4b ||
        tail[index + 2] != 5 ||
        tail[index + 3] != 6) {
      continue;
    }
    final entries = tail[index + 10] + 256 * tail[index + 11];
    final comment = tail[index + 20] + 256 * tail[index + 21];
    if (index + endRecordLength + comment == tail.length) return entries > 0;
  }
  return false;
}
