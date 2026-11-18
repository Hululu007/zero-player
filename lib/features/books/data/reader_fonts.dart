import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../../core/network/request_scheduler.dart';

const readerBundledFonts = {
  'NotoSerifSC': '宋体',
  'NotoSansSC': '黑体',
  'Xiaolai': '手写',
  'system': '系统默认',
};

/// Entries from wordshub/free-font, linked to the upstream OFL projects.
/// Versions, bytes and licenses were verified against the upstream files.
final class OpenReaderFont {
  const OpenReaderFont(
    this.id,
    this.label,
    this.repo,
    this.version,
    this.file,
    this.bytes,
    this.digest,
    this.licenseDigest,
  );
  final String id, label, repo, version, file, digest, licenseDigest;
  final int bytes;
  String get base =>
      'https://raw.githubusercontent.com/adobe-fonts/$repo/$version/';
  Uri get uri => Uri.parse('${base}OTF/SimplifiedChinese/$file');
  Uri get license => Uri.parse('${base}LICENSE.txt');
  Uri get project => Uri.parse('https://github.com/adobe-fonts/$repo');
}

const openReaderFonts = [
  OpenReaderFont(
    'open:source-han-sans-light',
    '思源黑体 · 细体',
    'source-han-sans',
    '2.005R',
    'SourceHanSansSC-Light.otf',
    16460112,
    'b6dfc945aae0daf9b15019f59c2f7b18d17da3b92f00c3ec32fb5f0333696d9c',
    'fcac737e761ec63dbfbdce11030a1780161920d80315edba9c8beff1c2bac5a2',
  ),
  OpenReaderFont(
    'open:source-han-serif',
    '思源宋体 · 完整字库',
    'source-han-serif',
    '2.003R',
    'SourceHanSerifSC-Regular.otf',
    24543332,
    '78aa7a328fd974df2d688c8a9fd74a33d8334dfa84ab24d9d11efb2ffc464117',
    '9ff5bb567e1b92c801fc1069e5fbf992ff8efccacb9db94e5959a5b3ba9bb903',
  ),
];

bool validReaderFontFamily(Object? family) =>
    family is String &&
    (readerBundledFonts.containsKey(family) ||
        openReaderFonts.any((font) => font.id == family) ||
        (family.startsWith('system:') &&
            family.length > 7 &&
            family.length <= 263 &&
            !family.contains(RegExp(r'[\x00-\x1f]'))));

String readerFontLabel(String family) =>
    readerBundledFonts[family] ??
    openReaderFonts.where((f) => f.id == family).firstOrNull?.label ??
    (family.startsWith('system:') ? family.substring(7) : '宋体');

String? readerFontFamily(String family) => family == 'system'
    ? null
    : family.startsWith('system:')
    ? family.substring(7)
    : family;

final class ReaderFontStore {
  ReaderFontStore(this.root, this.network);
  final Directory root;
  final DocumentClient network;
  static const _channel = MethodChannel('zero_player/reader_fonts');
  final _loaded = <String>{};
  final _loading = <String, Future<bool>>{};

  Future<List<String>> systemFamilies() async {
    try {
      final names = await _channel.invokeListMethod<String>('systemFamilies');
      return {
        ...?names?.where((s) => s.trim().isNotEmpty && s.length <= 256),
      }.toList()..sort();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  File _file(OpenReaderFont font) => File(p.join(root.path, font.file));
  File _license(OpenReaderFont font) =>
      File(p.join(root.path, '${font.file}.OFL.txt'));
  Future<bool> installed(OpenReaderFont font) async =>
      await _file(font).exists() && await _license(font).exists();

  Future<void> remove(OpenReaderFont font) async {
    if (!openReaderFonts.contains(font)) throw const FormatException('未知字体项目');
    for (final file in [_file(font), _license(font)]) {
      if (await file.exists()) await file.delete();
    }
    // Flutter does not expose font unloading. A loaded face remains usable
    // until process exit; only its disk copy is removed here.
  }

  Future<bool> ensure(String family) => _loading.putIfAbsent(
    family,
    () => _ensure(family).whenComplete(() {
      _loading.remove(family);
    }),
  );

  Future<bool> _ensure(String family) async {
    if (_loaded.contains(family) || readerBundledFonts.containsKey(family)) {
      return true;
    }
    if (family.startsWith('system:')) {
      return (await systemFamilies()).contains(family.substring(7));
    }
    final font = openReaderFonts.where((font) => font.id == family).firstOrNull;
    if (font == null || !await installed(font)) return false;
    try {
      if (await _file(font).length() != font.bytes ||
          await _license(font).length() > 65536) {
        return false;
      }
      final bytes = await _file(font).readAsBytes();
      final license = await _license(font).readAsBytes();
      if (sha256.convert(bytes).toString() != font.digest ||
          sha256.convert(license).toString() != font.licenseDigest) {
        return false;
      }
      final loader = FontLoader(font.id)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loaded.add(font.id);
      return true;
    } on Exception {
      return false;
    }
  }

  Future<void> download(OpenReaderFont font, CancellationToken token) async {
    if (!openReaderFonts.contains(font)) throw const FormatException('未知字体项目');
    void target(Uri uri) {
      if (uri != font.uri && uri != font.license) {
        throw const FormatException('字体下载地址发生变化');
      }
    }

    final license = await network.get(
      font.license,
      cancellation: token,
      maxBytes: 65536,
      validateTarget: target,
      priority: RequestPriority.background,
    );
    final data = await network.get(
      font.uri,
      cancellation: token,
      maxBytes: font.bytes,
      validateTarget: target,
      priority: RequestPriority.background,
      networkTimeout: const Duration(seconds: 90),
    );
    token.check();
    if (data.bytes.length != font.bytes ||
        sha256.convert(data.bytes).toString() != font.digest ||
        sha256.convert(license.bytes).toString() != font.licenseDigest) {
      throw const FormatException('字体或许可证校验失败，请重试');
    }
    await root.create(recursive: true);
    final staging = await root.createTemp('.pending-');
    try {
      final stagedFont = File(p.join(staging.path, font.file));
      final stagedLicense = File(p.join(staging.path, 'OFL.txt'));
      await stagedFont.writeAsBytes(data.bytes, flush: true);
      await stagedLicense.writeAsBytes(license.bytes, flush: true);
      token.check();
      await stagedFont.rename(_file(font).path);
      await stagedLicense.rename(_license(font).path);
      token.check();
      if (!await ensure(font.id)) throw const FormatException('字体加载失败');
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
