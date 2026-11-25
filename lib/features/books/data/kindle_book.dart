import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_convert/gbk.dart';
import 'package:html/parser.dart' as html;
import 'package:kindle_unpack/kindle_unpack.dart' as kindle;

import 'kindle_text.dart';

final class KindleProtected implements Exception {
  const KindleProtected();
}

/// Convert reading content in memory so Kindle bytes can use the same EPUB
/// resource handling, text admission, and reader as an ordinary publication.
Uint8List kindleReadingEpub(Uint8List bytes) {
  try {
    final file = kindle.PdbFile.parse(bytes);
    if (file.header.type != 'BOOK' || file.header.creator != 'MOBI') {
      throw invalidKindle;
    }
    final layout = kindle.KindleFile.inspect(file);
    for (final section in [layout.mobi7, layout.kf8].nonNulls) {
      if (section.palmDoc.isEncrypted || section.mobi.hasDrm) {
        throw const KindleProtected();
      }
    }
    final selected = layout.kf8 ?? layout.mobi7!;
    final relative = kindle.PdbFile(
      header: file.header,
      records: file.records.sublist(selected.recordOffset),
    );
    return _readingPackage(file, relative, selected, layout.mobi7);
  } on kindle.KindleUnpackException {
    throw invalidKindle;
  } on RangeError {
    throw invalidKindle;
  }
}

Uint8List _readingPackage(
  kindle.PdbFile original,
  kindle.PdbFile relative,
  kindle.KindleSection section,
  kindle.KindleSection? legacy,
) {
  final raw = decodeKindleText(relative, section);
  if (raw.length >= 4 &&
      ascii.decode(raw.take(4).toList(), allowInvalid: true) == '%MOP') {
    throw const FormatException('暂不支持 Kindle Print Replica 固定版式文件');
  }
  final mobi = section.mobi;
  final encoding = mobi.textEncoding;
  final flows = _readFlows(relative, mobi, raw);
  final images = _images(original, relative, section, legacy);
  final sheets = <int, kindle.EpubAsset>{};
  for (final flow in flows?.flows ?? const <kindle.FlowSection>[]) {
    if (flow.kind == kindle.FlowKind.css) {
      sheets[flow.index] = kindle.EpubAsset(
        name: 'style${flow.index}.css',
        bytes: utf8.encode(_text(flow.bytes, encoding)),
      );
    }
  }
  final List<String> content;
  if (mobi.fileVersion >= 8) {
    final primary = flows?.primaryHtml?.bytes ?? raw;
    content = _kindleXhtml(
      relative,
      mobi,
      primary,
    ).map((part) => _text(part.bytes, encoding)).toList();
  } else {
    content = _splitMobi(_text(raw, encoding));
  }
  final imagesByIndex = {for (final image in images) image.blockIndex: image};
  final parts = <kindle.XhtmlPart>[];
  var total = 0;
  for (final chunk in content) {
    final markup = _fixResources(chunk, imagesByIndex, sheets);
    if (markup == null) continue;
    final prepared = utf8.encode(markup);
    total += prepared.length;
    if (total > 24 << 20) throw invalidKindle;
    parts.add(kindle.XhtmlPart(fileNumber: parts.length, bytes: prepared));
  }
  if (parts.isEmpty) throw invalidKindle;
  return kindle.EpubBuilder.build(
    metadata: kindle.EpubMetadata(
      identifier: 'urn:kindle:${mobi.uniqueId}',
      title: section.exth?.title ?? mobi.fullName(relative.records.first.data),
      language: section.exth?.language ?? 'und',
      creators: section.exth?.authors ?? const [],
    ),
    parts: parts,
    css: sheets.values.toList(),
    images: images,
  );
}

kindle.BookFlows? _readFlows(
  kindle.PdbFile file,
  kindle.MobiHeader mobi,
  Uint8List raw,
) {
  // A single-flow KF8 file can put its content range here instead of an FDST.
  if (mobi.fileVersion < 8 || (mobi.fdstFlowCount ?? 0) <= 1) return null;
  final index = mobi.fdstRecord;
  if (index == null || index == 0 || index == kindle.MobiHeader.unset) {
    return null;
  }
  if (index >= file.records.length || (mobi.fdstFlowCount ?? 0) > 512) {
    throw invalidKindle;
  }
  final fdst = kindle.FdstTable.parse(file.records[index].data);
  if (fdst.entries.length > 512) throw invalidKindle;
  return kindle.BookFlows.split(raw, fdst);
}

List<kindle.XhtmlPart> _kindleXhtml(
  kindle.PdbFile file,
  kindle.MobiHeader mobi,
  Uint8List raw,
) {
  final skeletonIndex = mobi.skeletonIndex;
  final fragmentIndex = mobi.fragmentIndex;
  if (skeletonIndex == null ||
      skeletonIndex == 0 ||
      skeletonIndex == kindle.MobiHeader.unset ||
      fragmentIndex == null ||
      fragmentIndex == 0 ||
      fragmentIndex == kindle.MobiHeader.unset) {
    return [kindle.XhtmlPart(fileNumber: 0, bytes: raw)];
  }
  final skeleton = kindle.SkeletonTable.parse(file, mobi);
  final fragments = kindle.FragmentTable.parse(file, mobi);
  if (skeleton.entries.isEmpty ||
      skeleton.entries.length > 2048 ||
      fragments.entries.length > 16384) {
    throw invalidKindle;
  }
  var lastEnd = 0;
  var fragment = 0;
  for (final part in skeleton.entries) {
    if (part.start < lastEnd ||
        part.end > raw.length ||
        part.fragmentCount > 256 ||
        fragment + part.fragmentCount > fragments.entries.length) {
      throw invalidKindle;
    }
    var end = part.end;
    for (var i = 0; i < part.fragmentCount; i++) {
      end += fragments.entries[fragment++].length;
    }
    if (end > raw.length || end - part.start > 8 << 20) throw invalidKindle;
    lastEnd = end;
  }
  return kindle.XhtmlSplitter.split(
    primaryFlow: raw,
    skeletons: skeleton,
    fragments: fragments,
  );
}

List<kindle.ExtractedImage> _images(
  kindle.PdbFile original,
  kindle.PdbFile relative,
  kindle.KindleSection section,
  kindle.KindleSection? legacy,
) {
  final shared =
      legacy != null &&
      section.recordOffset > 0 &&
      legacy.mobi.firstImageIndex < section.recordOffset;
  final records = shared
      ? kindle.PdbFile(
          header: original.header,
          records: original.records.sublist(0, section.recordOffset),
        )
      : relative;
  return kindle.BookImages.extract(
    pdb: records,
    mobi: shared ? legacy.mobi : section.mobi,
  ).all.where((image) => image.data.length <= 8 << 20).take(512).toList();
}

String _text(Uint8List bytes, int encoding) => switch (encoding) {
  65001 => utf8.decode(bytes, allowMalformed: true),
  936 => gbk.decode(bytes),
  _ => _decode1252(bytes),
};

String _decode1252(Uint8List bytes) {
  const high = '€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008DŽ\u008F\u0090‘’“”•–—˜™š›œ\u009DžŸ';
  return String.fromCharCodes(
    bytes.map(
      (byte) =>
          byte >= 0x80 && byte < 0xa0 ? high.codeUnitAt(byte - 0x80) : byte,
    ),
  );
}

List<String> _splitMobi(String markup) {
  final split = markup.split(
    RegExp(r'<(?:mbp:)?pagebreak\b[^>]*>', caseSensitive: false),
  );
  if (split.length > 2048) throw invalidKindle;
  return split;
}

String? _fixResources(
  String markup,
  Map<int, kindle.ExtractedImage> images,
  Map<int, kindle.EpubAsset> sheets,
) {
  final document = html.parse(markup.replaceAll('\u0000', ''));
  for (final node in document.querySelectorAll('img')) {
    final recindex = int.tryParse(node.attributes['recindex'] ?? '');
    final reference = _kindleReference(node.attributes['src'], 'embed');
    final id = recindex ?? reference;
    if (id case final int number) {
      final image = images[number - 1];
      if (image != null) node.attributes['src'] = '../Images/${image.name}';
    }
  }
  for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
    final reference = _kindleReference(link.attributes['href'], 'flow');
    if (sheets[reference] case final sheet?) {
      link.attributes['href'] = '../Styles/${sheet.name}';
    }
  }
  final body = document.body!;
  if (body.text.trim().isEmpty && body.querySelector('img[src],svg') == null) {
    return null;
  }
  return document.outerHtml;
}

int? _kindleReference(String? value, String type) {
  final prefix = 'kindle:$type:';
  if (value == null || !value.startsWith(prefix)) return null;
  final id = value.substring(prefix.length).split('?').first;
  return id.length <= 6 ? int.tryParse(id, radix: 32) : null;
}
