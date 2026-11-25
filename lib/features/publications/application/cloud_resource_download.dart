import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/publish_file.dart';
import '../../../core/platform/video_files.dart';
import '../data/cloud_shared_file.dart';
import '../data/publication_http.dart';
import '../data/publication_share.dart';
import '../data/publication_space.dart';
import '../domain/publication.dart';

typedef CloudBatchProgress = ({
  int index,
  int count,
  String name,
  int received,
  int total,
});

typedef CloudBatchResult = ({
  String destination,
  List<CloudShareItem> saved,
  List<String> savedPaths,
  Object? failure,
});

final class CloudResourceDownload {
  CloudResourceDownload(this.shares, this.authorize, {this.checkDownload});

  final PublicationShareResolver shares;
  final void Function(String) authorize;
  final Future<void> Function()? checkDownload;
  CancellationToken? _current;
  static const _reserve = 16 << 20;
  static const _unknownLengthLimit = 512 << 20;
  static const _spaceCheckInterval = 4 << 20;

  void cancel() => _current?.cancel();

  Future<List<CloudSharedFile>> inspect(Uri link, String? code) async =>
      (await inspectTree(link, code)).files.map((item) => item.file).toList();

  Future<CloudShareListing> inspectTree(Uri link, String? code) =>
      _run((token) async {
        authorize(link.toString());
        final listing = await shares.inspectTree(link, code, token);
        token.check();
        final files = listing.files.where((item) {
          try {
            for (final folder in item.folders) {
              authorize(folder);
            }
            authorize(item.file.name);
            return true;
          } on PublicationFailure {
            return false;
          }
        }).toList();
        return (files: files, truncated: listing.truncated);
      });

  Future<String?> save(
    Uri link,
    String? code,
    CloudSharedFile file,
    void Function(int saved, int total) onProgress, {
    String? baiduAccessToken,
  }) => _run((token) async {
    authorize('$link ${file.name}');
    await checkDownload?.call();
    final destination = await VideoFiles.chooseDirectory();
    token.check();
    if (destination == null) return null;
    return _saveFile(
      link,
      code,
      CloudShareItem(file, const []),
      destination,
      token,
      onProgress,
      baiduAccessToken: baiduAccessToken,
    );
  });

  Future<CloudBatchResult?> saveBatch(
    Uri link,
    String? code,
    List<CloudShareItem> items,
    void Function(CloudBatchProgress) onProgress, {
    String? baiduAccessToken,
  }) => _run((token) async {
    if (items.isEmpty) return null;
    authorize(link.toString());
    await checkDownload?.call();
    final destination = await VideoFiles.chooseDirectory();
    token.check();
    if (destination == null) return null;
    final saved = <CloudShareItem>[];
    final savedPaths = <String>[];
    Object? failure;
    try {
      for (final (index, item) in items.indexed) {
        token.check();
        onProgress((
          index: index,
          count: items.length,
          name: item.file.name,
          received: 0,
          total: -1,
        ));
        final savedPath = await _saveFile(
          link,
          code,
          item,
          destination,
          token,
          (received, total) => onProgress((
            index: index,
            count: items.length,
            name: item.file.name,
            received: received,
            total: total,
          )),
          baiduAccessToken: baiduAccessToken,
        );
        saved.add(item);
        savedPaths.add(savedPath);
      }
    } on Exception catch (error) {
      failure = error;
    }
    return (
      destination: destination,
      saved: saved,
      savedPaths: savedPaths,
      failure: failure,
    );
  });

  Future<String> _saveFile(
    Uri link,
    String? code,
    CloudShareItem item,
    String destination,
    CancellationToken token,
    void Function(int, int) onProgress, {
    String? baiduAccessToken,
  }) async {
    final file = item.file;
    void check() {
      token.check();
      authorize('$link ${file.name}');
      for (final folder in item.folders) {
        authorize(folder);
      }
    }

    await checkDownload?.call();
    check();
    final name = _filename(file.name);
    final folders = item.folders.map(_filename).toList(growable: false);
    if (folders.length > 20) throw const FormatException('文件夹层级超出限制');
    final android = Platform.isAndroid;
    final parent = android
        ? await getTemporaryDirectory()
        : await _desktopFolder(destination, folders, check);
    check();
    final staging = await parent.createTemp('.zero-cloud-');
    try {
      final target = File(p.join(parent.path, name));
      Future<void> checkDestination(int bytes, {bool copying = false}) async {
        if (android) {
          final limit = await VideoFiles.channel
              .invokeMethod<int>('cloudResourceCapacity', {
                'directory': destination,
                'name': name,
                'copying': copying,
                'folders': folders,
              });
          if (limit == null) {
            throw const FormatException('无法确认此目录的可用空间，请选择设备本地目录');
          }
          _requireSpace(bytes, limit);
        } else {
          if (await FileSystemEntity.type(target.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const PublicationFailure(
              PublicationProblem.destinationConflict,
            );
          }
        }
      }

      await checkDestination(file.bytes ?? 0);
      if (file.bytes case final int bytes) {
        _requireSpace(bytes, await publicationDiskFree(staging));
      }
      check();
      final temporary = File(p.join(staging.path, 'download.part'));
      final total = await _download(
        link,
        code,
        file,
        staging,
        temporary,
        token,
        check,
        checkDestination,
        onProgress,
        baiduAccessToken,
      );
      check();
      if (android) {
        await checkDestination(total, copying: true);
        check();
        try {
          return await VideoFiles.saveCloudResource(
            temporary,
            destination,
            name,
            token,
            folders: folders,
          );
        } on PlatformException {
          token.check();
          rethrow;
        }
      }
      await publishFile(temporary, target);
      return target.path;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<int> _download(
    Uri link,
    String? code,
    CloudSharedFile file,
    Directory staging,
    File temporary,
    CancellationToken token,
    void Function() check,
    Future<void> Function(int bytes) checkDestination,
    void Function(int, int) onProgress,
    String? baiduAccessToken,
  ) async {
    final source = await shares.resolveResource(
      link,
      file,
      code,
      token,
      baiduAccessToken: baiduAccessToken,
    );
    final response = await shares.http.open(
      source.uri,
      token,
      scope: source.scope,
      guest: source.guest,
      referer: source.referer,
    );
    var reading = false;
    var total = 0;
    try {
      final headers = response.response.headers;
      if (response.response.statusCode != HttpStatus.ok) {
        throw publicationHttpFailure(response);
      }
      if (headers.contentType?.mimeType == 'text/html') {
        throw const PublicationFailure(PublicationProblem.challenge);
      }
      final encoding = headers.value(HttpHeaders.contentEncodingHeader);
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      final size = response.response.contentLength;
      if (size >= 0 && file.bytes != null && size != file.bytes) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      total = size >= 0 ? size : file.bytes ?? -1;
      final unknown = total < 0;
      final available = await publicationDiskFree(staging);
      _requireSpace(unknown ? 0 : total, available);
      await checkDestination(unknown ? 0 : total);
      check();
      final output = await temporary.open(mode: FileMode.write);
      try {
        var received = 0;
        var checkedThrough = 0;
        var remaining = available;
        onProgress(0, total);
        reading = true;
        await for (final chunk in response.body) {
          check();
          final next = received + chunk.length;
          if (unknown && next > _unknownLengthLimit) {
            throw const FormatException('来源未提供文件大小，最多可下载 512 MiB');
          }
          if (!unknown && next > total) {
            throw const PublicationFailure(PublicationProblem.invalid);
          }
          if (unknown) {
            if (remaining < chunk.length + _reserve ||
                next - checkedThrough >= _spaceCheckInterval) {
              remaining = await publicationDiskFree(staging);
              checkedThrough = received;
            }
            _requireSpace(chunk.length, remaining);
            remaining -= chunk.length;
          }
          check();
          await output.writeFrom(chunk);
          received = next;
          onProgress(received, total);
        }
        if (unknown ? received == 0 : received != total) {
          throw const PublicationFailure(PublicationProblem.invalid);
        }
        await output.flush();
        if (unknown) {
          total = received;
          onProgress(received, received);
        }
      } finally {
        await output.close();
      }
    } finally {
      if (!reading) await discardPublicationResponse(response);
    }

    return total;
  }

  Future<Directory> _desktopFolder(
    String destination,
    List<String> folders,
    void Function() check,
  ) async {
    var directory = Directory(destination);
    for (final folder in folders) {
      check();
      final child = Directory(p.join(directory.path, folder));
      final kind = await FileSystemEntity.type(child.path, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        await child.create();
      } else if (kind != FileSystemEntityType.directory) {
        throw const PublicationFailure(PublicationProblem.destinationConflict);
      }
      directory = child;
    }
    return directory;
  }

  Future<T> _run<T>(Future<T> Function(CancellationToken) action) async {
    if (_current != null) {
      throw const PublicationFailure(PublicationProblem.cloudOperationBusy);
    }
    final token = _current = CancellationToken();
    try {
      return await action(token);
    } finally {
      _current = null;
    }
  }

  String _filename(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty ||
        safe.length > 240 ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]) *(\.|$)',
          caseSensitive: false,
        ).hasMatch(safe)) {
      throw const FormatException('分享文件名无法安全保存');
    }
    return safe;
  }

  void _requireSpace(int bytes, int available) {
    if (available < _reserve || bytes > available - _reserve) {
      throw PublicationFailure(
        PublicationProblem.diskFull,
        spaceShortfall: (
          availableBytes: available,
          requiredBytes: bytes + _reserve,
          protectedBytes: 0,
        ),
      );
    }
  }
}
