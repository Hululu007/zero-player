import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import '../domain/book.dart';
import 'epub_styles.dart';
import 'kindle_book.dart';
import 'local_book.dart';

Future<LocalBook> parsePdfBook(String filename, Uint8List bytes) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openData(bytes, sourceName: filename);
  try {
    if (document.pages.length > 4000) {
      throw const FormatException('PDF 页数超过 4000');
    }
    final sections = <({String title, String text})>[];
    for (final page in document.pages) {
      final text = (await page.loadText())?.fullText ?? '';
      sections.add((
        title: '第 ${page.pageNumber} 页',
        text: text.isEmpty ? '此页没有可搜索文字' : text,
      ));
    }
    return (
      title: bookLabel(p.basenameWithoutExtension(filename)),
      author: '',
      sections: sections,
    );
  } finally {
    await document.dispose();
  }
}

typedef RichSection = ({String title, String html, String text, bool vertical});
typedef RichBook = ({String title, String author, List<RichSection> sections});

Future<RichBook> readKindleBookOffThread(Uint8List bytes) =>
    Isolate.run(() => _readEpub(kindleReadingEpub(bytes), internalLinks: true));

Future<List<RichSection>> readRichEpubOffThread(
  List<int> bytes, {
  bool internalLinks = false,
}) =>
    Isolate.run(() => _readEpub(bytes, internalLinks: internalLinks).sections);

Future<LocalBook> parseEpubBookOffThread(String filename, List<int> bytes) =>
    Isolate.run(() {
      final package = _readEpub(bytes);
      return (
        title: package.title.isEmpty
            ? bookLabel(p.basenameWithoutExtension(filename))
            : package.title,
        author: package.author,
        sections: [
          for (final section in package.sections)
            (
              title: section.title,
              text: section.text.trim().isEmpty ? '[插图]' : section.text,
            ),
        ],
      );
    });

List<RichSection> readRichEpub(List<int> bytes) => _readEpub(bytes).sections;

const _maxEpubBytes = 256 * 1024 * 1024;
const _maxEpubEntryBytes = 16 * 1024 * 1024;
final _xmlDeclarations = RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false);

bool _unsafeEpubPath(String path) =>
    path == '.' ||
    path == '..' ||
    path.startsWith('../') ||
    p.posix.isAbsolute(path) ||
    path.contains('\\') ||
    path.contains('\u0000');

/// No extraction to disk or external resource loading. Bound decoded resources.
({String title, String author, List<RichSection> sections}) _readEpub(
  List<int> bytes, {
  bool internalLinks = false,
}) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > 4000) {
    throw const FormatException('EPUB 条目过多');
  }
  final files = <String, ZipFile>{};
  var total = 0;
  for (final header in directory.fileHeaders) {
    final f = header.file!;
    final name = p.posix.normalize(f.filename);
    if ((f.flags | header.generalPurposeBitFlag) & 1 != 0 ||
        f.filename != header.filename ||
        _unsafeEpubPath(name) ||
        files.containsKey(name) ||
        f.uncompressedSize < 0 ||
        f.uncompressedSize > _maxEpubEntryBytes ||
        (header.versionMadeBy >> 8 == 3 &&
            (header.externalFileAttributes >> 16) & 0xf000 == 0xa000)) {
      throw const FormatException('EPUB 路径或大小无效');
    }
    total += f.uncompressedSize;
    if (total > _maxEpubBytes) throw const FormatException('EPUB 解包内容过大');
    files[name] = f;
  }
  var remaining = _maxEpubBytes;
  List<int> read(String name) {
    final f = files[name];
    if (f == null) throw const FormatException('EPUB 资源缺失');
    if (f.uncompressedSize > remaining) {
      throw const FormatException('EPUB 解包内容过大');
    }
    remaining -= f.uncompressedSize;
    final out = OutputMemoryStream(size: f.uncompressedSize);
    f.decompress(out);
    final data = out.getBytes();
    if (data.length != f.uncompressedSize || getCrc32(data) != f.crc32) {
      throw const FormatException('EPUB 校验失败');
    }
    return data;
  }

  String resolve(String folder, String href) {
    final uri = Uri.parse(href);
    final relative = Uri.decodeComponent(uri.path);
    final path = p.posix.normalize(p.posix.join(folder, relative));
    if (uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        relative.isEmpty ||
        p.posix.isAbsolute(relative) ||
        _unsafeEpubPath(path)) {
      throw const FormatException('EPUB 外部资源不允许自动读取');
    }
    return path;
  }

  XmlElement xml(String name) {
    final text = utf8.decode(read(name));
    if (_xmlDeclarations.hasMatch(text)) {
      throw const FormatException('不支持 XML 实体');
    }
    return XmlDocument.parse(text).rootElement;
  }

  final container = xml('META-INF/container.xml');
  final opf = container.descendantElements
      .where((e) => e.name.local == 'rootfile')
      .firstOrNull
      ?.getAttribute('full-path');
  if (opf == null) throw const FormatException('EPUB 缺少书籍清单');
  final path = resolve('', opf);
  final package = xml(path);
  final folder = p.posix.dirname(path);
  const encryption = 'META-INF/encryption.xml';
  if (files[encryption] case final descriptor?) {
    if (descriptor.uncompressedSize > 128 << 10 ||
        files.containsKey('META-INF/rights.xml')) {
      throw const FormatException('不支持加密 EPUB');
    }
    final fonts = _obfuscatedFonts(xml(encryption), package, folder, resolve);
    if (!fonts.every(files.containsKey)) {
      throw const FormatException('不支持加密 EPUB');
    }
    // Preserve the original file. The renderer uses reader fonts and never
    // reads or decodes these resources.
    for (final font in fonts) {
      files.remove(font);
    }
  }
  return _readEpubSpine(package, folder, read, resolve, internalLinks);
}

Set<String> _obfuscatedFonts(
  XmlElement descriptor,
  XmlElement package,
  String folder,
  String Function(String, String) resolve,
) {
  const ocf = 'urn:oasis:names:tc:opendocument:xmlns:container';
  const enc = 'http://www.w3.org/2001/04/xmlenc#';
  const unsupported = FormatException('不支持加密 EPUB');
  final records = descriptor.childElements.toList();
  if (descriptor.namespaceUri != ocf ||
      descriptor.localName != 'encryption' ||
      records.isEmpty) {
    throw unsupported;
  }
  const types = {
    'font/ttf',
    'font/otf',
    'font/woff',
    'font/woff2',
    'application/font-sfnt',
    'application/font-woff',
    'application/vnd.ms-opentype',
  };
  const extensions = {'.ttf', '.otf', '.woff', '.woff2'};
  final manifest = package.childElements
      .where((element) => element.localName == 'manifest')
      .firstOrNull;
  final declared = {
    for (final item in manifest?.childElements ?? const <XmlElement>[])
      if (item.localName == 'item' &&
          types.contains(item.getAttribute('media-type')))
        if (item.getAttribute('href') case final href?) resolve(folder, href),
  };
  final fonts = <String>{};
  for (final record in records) {
    final method = record.getElement('EncryptionMethod', namespaceUri: enc);
    final cipher = record.getElement('CipherData', namespaceUri: enc);
    final reference = cipher?.getElement('CipherReference', namespaceUri: enc);
    final uri = Uri.tryParse(reference?.getAttribute('URI') ?? '');
    if (record.namespaceUri != enc ||
        record.localName != 'EncryptedData' ||
        record.childElements.length != 2 ||
        method == null ||
        method.getAttribute('Algorithm') !=
            'http://www.idpf.org/2008/embedding' ||
        method.childElements.isNotEmpty ||
        cipher?.childElements.length != 1 ||
        reference == null ||
        reference.childElements.isNotEmpty ||
        uri == null ||
        uri.hasFragment) {
      throw unsupported;
    }
    final path = resolve('', uri.toString());
    if (!extensions.contains(p.posix.extension(path).toLowerCase()) ||
        !declared.contains(path) ||
        !fonts.add(path)) {
      throw unsupported;
    }
  }
  return fonts;
}

({String title, String author, List<RichSection> sections}) _readEpubSpine(
  XmlElement package,
  String folder,
  List<int> Function(String) read,
  String Function(String, String) resolve,
  bool internalLinks,
) {
  XmlElement? child(String name) =>
      package.childElements.where((e) => e.name.local == name).firstOrNull;
  final manifestNode = child('manifest');
  final spine = child('spine');
  if (manifestNode == null || spine == null) {
    throw const FormatException('EPUB 缺少阅读顺序');
  }
  final metadata = child('metadata')?.childElements ?? const <XmlElement>[];
  String label(String name) => bookLabel(
    metadata.where((e) => e.name.local == name).firstOrNull?.innerText,
  );
  final manifest = {
    for (final item in manifestNode.childElements.where(
      (e) => e.name.local == 'item',
    ))
      if (item.getAttribute('id') case final String id)
        if (item.getAttribute('href') case final String href) id: href,
  };
  final items = spine.childElements.where((e) => e.name.local == 'itemref');
  if (items.length > 4000) throw const FormatException('EPUB 正文章节过多');
  final paths = [
    for (final item in items)
      if (manifest[item.getAttribute('idref')] case final String href)
        resolve(folder, href),
  ];
  final index = <String, int>{};
  if (internalLinks) {
    for (final (section, path) in paths.indexed) {
      index.putIfAbsent(path, () => section);
    }
  }
  final loaded = <String, RichSection>{};
  final sections = [
    for (final path in paths)
      loaded.putIfAbsent(path, () => _section(path, read, resolve, index)),
  ];
  if (sections.isEmpty) throw const FormatException('EPUB 阅读顺序为空');
  return (title: label('title'), author: label('creator'), sections: sections);
}

RichSection _section(
  String path,
  List<int> Function(String) read,
  String Function(String, String) resolve,
  Map<String, int> index,
) {
  final source = utf8.decode(read(path), allowMalformed: true);
  final doc = html.parse(source);
  final sheets = <String>[];
  for (final node in doc.querySelectorAll(
    'style,link[rel="stylesheet"][href]',
  )) {
    try {
      sheets.add(
        node.localName == 'style'
            ? node.text
            : utf8.decode(
                read(resolve(p.posix.dirname(path), node.attributes['href']!)),
              ),
      );
    } on Exception {
      /* An unavailable stylesheet uses reader defaults. */
    }
  }
  applyEpubStyles(doc, sheets);
  _inlineSvg(doc);
  for (final node in doc.querySelectorAll(
    'script,iframe,object,embed,link,style,form,video,audio,svg',
  )) {
    node.remove();
  }
  _inlineResources(doc, path, read, resolve, index);
  final body = doc.body!;
  final heading = bookLabel(body.querySelector('h1,h2,h3')?.text);
  final title = bookLabel(doc.querySelector('title')?.text);
  return (
    title: heading.isNotEmpty
        ? heading
        : title.isNotEmpty
        ? title
        : bookLabel(p.posix.basename(path)),
    html:
        '<div style="${htmlEscape.convert(body.attributes['style'] ?? '')}">${body.innerHtml}</div>',
    text:
        '${body.text} ${body.querySelectorAll('img').map((e) => e.attributes['alt'] ?? '').join(' ')}',
    vertical: doc.querySelectorAll('[style]').any((element) {
      final mode = safeDeclarations(
        element.attributes['style']!,
      )['writing-mode'];
      return const {'vertical-rl', 'tb-rl'}.contains(mode?.toLowerCase());
    }),
  );
}

String _svgData(String source) {
  if (_xmlDeclarations.hasMatch(source)) {
    throw const FormatException('SVG entities are unsupported');
  }
  final doc = XmlDocument.parse(source);
  if (doc.rootElement.name.local != 'svg') {
    throw const FormatException('SVG 缺少根元素');
  }
  for (final e in doc.descendants.whereType<XmlElement>().toList()) {
    if ([
      'script',
      'style',
      'foreignobject',
      'image',
      'animate',
      'set',
    ].contains(e.name.local.toLowerCase())) {
      e.parent?.children.remove(e);
      continue;
    }
    e.attributes.removeWhere(
      (a) =>
          a.name.local.toLowerCase().startsWith('on') ||
          a.name.local == 'style' ||
          (a.name.local == 'href' && !a.value.startsWith('#')) ||
          (a.value.contains('url(') &&
              !RegExp(r'^url\(#[a-zA-Z0-9_-]+\)$').hasMatch(a.value)),
    );
  }
  return 'data:image/svg+xml;base64,${base64Encode(utf8.encode(doc.toXmlString()))}';
}

void _inlineSvg(dom.Document doc) {
  for (final svg in doc.querySelectorAll('svg')) {
    // Nested SVG elements are kept in their enclosing illustration.
    if (svg.parent?.namespaceUri == 'http://www.w3.org/2000/svg') continue;
    final image = dom.Element.tag('img')..attributes['alt'] = svg.text;
    image.attributes['src'] =
        'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg.outerHtml))}';
    svg.replaceWith(image);
  }
}

void _inlineResources(
  dom.Document doc,
  String path,
  List<int> Function(String) read,
  String Function(String, String) resolve,
  Map<String, int> index,
) {
  for (final element in doc.querySelectorAll('*')) {
    final link = index.isEmpty || element.localName != 'a'
        ? null
        : element.attributes['href'];
    element.attributes.removeWhere(
      (key, _) =>
          key.toString().startsWith('on') ||
          const ['srcset', 'background', 'href'].contains(key),
    );
    if (link != null) {
      final target = _safeEpubLink(link, path, index, resolve);
      if (target != null) element.attributes['href'] = target;
    }
    if (element.localName == 'img') {
      final src = element.attributes.remove('src');
      if (src == null) continue;
      try {
        if (src.startsWith('data:image/svg+xml;base64,')) {
          final markup = utf8.decode(base64Decode(src.split(',').last));
          element.attributes['src'] = _svgData(markup);
          _svgAlt(element, markup);
        } else {
          final name = resolve(p.posix.dirname(path), src);
          final ext = p.posix.extension(name).toLowerCase();
          if (ext == '.svg') {
            final markup = utf8.decode(read(name));
            element.attributes['src'] = _svgData(markup);
            _svgAlt(element, markup);
          }
          if ({'.png', '.jpg', '.jpeg', '.gif', '.webp'}.contains(ext)) {
            final bytes = read(name);
            element.attributes['src'] =
                'data:image/${ext == '.jpg' ? 'jpeg' : ext.substring(1)};base64,${base64Encode(bytes)}';
          }
        }
      } on Exception {
        // Missing, invalid or remote artwork stays a placeholder.
      }
    }
  }
}

String? _safeEpubLink(
  String link,
  String path,
  Map<String, int> index,
  String Function(String, String) resolve,
) {
  if (link.length > 2048) return null;
  try {
    final uri = Uri.parse(link);
    if (uri.hasScheme || uri.hasAuthority || uri.hasQuery) return null;
    final target = uri.path.isEmpty
        ? path
        : resolve(p.posix.dirname(path), uri.path);
    final destination = index[target];
    if (destination == null) return null;
    if (target == path && uri.hasFragment) return '#${uri.fragment}';
    return Uri(
      scheme: 'epub-section',
      path: '$destination',
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  } on FormatException {
    return null;
  }
}

void _svgAlt(dom.Element element, String markup) {
  final text = html.parse(markup).querySelector('svg')?.text ?? '';
  final alt = element.attributes['alt'] ?? '';
  if (text.trim().isNotEmpty && alt.trim() != text.trim()) {
    element.attributes['alt'] = '$alt $text'.trim();
  }
}
