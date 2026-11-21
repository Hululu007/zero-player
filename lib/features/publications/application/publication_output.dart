import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/protected_book_export.dart';
import '../../../core/platform/video_files.dart';
import '../data/publication_sources.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';
import 'publication_backup.dart';
import 'publication_library.dart';

final class PublicationOutput {
  PublicationOutput(this.library, this.backup);
  final PublicationLibrary library;
  final PublicationBackup backup;
  final _tokens = <CancellationToken>{};
  final _exporter = ProtectedBookExport();
  static const directoryPreference = 'automaticDirectory';

  Future<String?> pickDirectory() async {
    library.requireImport('');
    final path = await VideoFiles.chooseDirectory();
    library.requireImport('');
    if (path != null) {
      await library.store.setPreference(directoryPreference, path);
    }
    return path;
  }

  Future<void> clearDirectory() async {
    library.requireImport('');
    await library.store.setPreference(directoryPreference, '');
  }

  Future<void> exportBackup() => _withToken((token) async {
    final data = await backup.encode();
    await _exporter.saveBytes(
      '图书书库备份.json',
      utf8.encode(data),
      'application/json',
      cancellation: token,
      validate: () => library.requireImport(''),
    );
  });

  Future<void> exportRule(PublicationSource source) =>
      _withToken((token) async {
        void validate() =>
            library.requireImport('${source.name} ${source.endpoint.host}');
        validate();
        if (!source.configurable) throw const FormatException('此书源没有可导出的规则');
        final raw = const JsonEncoder.withIndent('  ').convert(source.toSpec());
        await _exporter.saveBytes(
          '图书书源规则.json',
          utf8.encode(raw),
          'application/json',
          cancellation: token,
          validate: validate,
        );
      });

  Future<void> exportBook(PublicationHolding entry, {String? password}) =>
      _withToken((token) async {
        final ready = await library.open(entry, token, password: password);
        try {
          await _exporter.saveFile(
            ready.file,
            _name(entry),
            _mime(entry.format),
            cancellation: token,
            validate: () => _requireOpen(ready),
            publication: (
              id: p.basenameWithoutExtension(ready.file.path),
              legacy: p.equals(
                ready.file.parent.path,
                library.legacyDocuments.path,
              ),
            ),
          );
        } finally {
          await library.space.unlease(ready.lease);
        }
      });

  Future<String?> autoSave(String digest, {String? password}) async {
    final destination = await library.store.preference(directoryPreference);
    if (destination == null || destination.isEmpty) return null;
    final holding = (await library.holdings())
        .where((entry) => entry.digest == digest && entry.resident)
        .firstOrNull;
    if (holding == null) return null;
    return _withToken((token) async {
      final ready = await library.open(holding, token, password: password);
      final name = _name(holding, suffix: '-${digest.substring(0, 8)}');
      try {
        _requireOpen(ready);
        final existing = await VideoFiles.recoverSave(
          destination,
          name,
          digest,
          publication: true,
        );
        _requireOpen(ready);
        token.check();
        return existing ??
            await VideoFiles.save(
              ready.file,
              destination,
              name,
              cancellation: token,
              publicationMime: _mime(holding.format),
            );
      } on PlatformException catch (error) {
        throw PublicationFailure(switch (error.code) {
          'publication_directory_permission' =>
            PublicationProblem.directoryPermission,
          'publication_directory_unavailable' =>
            PublicationProblem.directoryUnavailable,
          'publication_destination_conflict' =>
            PublicationProblem.destinationConflict,
          'publication_disk_full' => PublicationProblem.diskFull,
          _ => PublicationProblem.storage,
        });
      } on FileSystemException catch (error) {
        throw PublicationFailure(
          await _desktopSaveProblem(error, destination, name),
        );
      } finally {
        await library.space.unlease(ready.lease);
      }
    });
  }

  Future<PublicationProblem> _desktopSaveProblem(
    FileSystemException error,
    String destination,
    String name,
  ) async {
    if (Platform.isWindows) {
      switch (error.osError?.errorCode) {
        case 5: // ERROR_ACCESS_DENIED
          return PublicationProblem.directoryPermission;
        case 39 || 112: // ERROR_HANDLE_DISK_FULL or ERROR_DISK_FULL
          return PublicationProblem.diskFull;
        case 80 || 183: // ERROR_FILE_EXISTS or ERROR_ALREADY_EXISTS
          return PublicationProblem.destinationConflict;
      }
    }
    final target = await FileSystemEntity.type(
      p.join(destination, name),
      followLinks: false,
    );
    if (target != FileSystemEntityType.notFound) {
      return PublicationProblem.destinationConflict;
    }
    return await Directory(destination).exists()
        ? PublicationProblem.storage
        : PublicationProblem.directoryUnavailable;
  }

  Future<T> _withToken<T>(Future<T> Function(CancellationToken) action) async {
    library.requireImport('');
    final token = CancellationToken();
    _tokens.add(token);
    try {
      return await action(token);
    } finally {
      _tokens.remove(token);
    }
  }

  void revoke() {
    for (final token in _tokens) {
      token.cancel();
    }
  }

  void _requireOpen(PublicationOpened book) {
    library.requireImport(book.book.title);
    if (!book.allowed()) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
  }

  String _name(PublicationHolding item, {String suffix = ''}) {
    final title = publicationLabel(item.edition.title, max: 80)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    return '${title.isEmpty ? '图书' : title}$suffix.${item.format.name}';
  }

  String _mime(PublicationFormat format) => format == PublicationFormat.pdf
      ? 'application/pdf'
      : 'application/epub+zip';
}
