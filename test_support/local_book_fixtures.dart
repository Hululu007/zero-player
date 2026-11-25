import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

Uint8List sampleKindle({bool kf8 = false, bool protected = false}) {
  final text = utf8.encode(
    '<html><body><h1>第一章</h1><p>电子书格式测试正文</p>'
    '<mbp:pagebreak/><h1>第二章</h1><p>续读位置示例</p></body></html>',
  );
  final title = utf8.encode('Kindle 格式示例');
  const firstRecord = 96;
  const recordHeader = 280;
  final source = Uint8List(
    firstRecord + recordHeader + title.length + text.length,
  );
  final data = ByteData.sublistView(source);
  source.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data.setUint16(76, 2);
  data.setUint32(78, firstRecord);
  final textOffset = firstRecord + recordHeader + title.length;
  data.setUint32(86, textOffset);
  data.setUint16(firstRecord, 1);
  data.setUint32(firstRecord + 4, text.length);
  data.setUint16(firstRecord + 8, 1);
  data.setUint16(firstRecord + 10, 4096);
  data.setUint16(firstRecord + 12, protected ? 2 : 0);
  const mobi = firstRecord + 16;
  source.setRange(mobi, mobi + 4, ascii.encode('MOBI'));
  data.setUint32(mobi + 4, recordHeader - 16);
  data.setUint32(mobi + 12, 65001);
  data.setUint32(mobi + 20, kf8 ? 8 : 6);
  data.setUint32(mobi + 68, recordHeader);
  data.setUint32(mobi + 72, title.length);
  for (final offset in [92, 152, 176, 232, 236]) {
    data.setUint32(mobi + offset, 0xffffffff);
  }
  source.setRange(firstRecord + recordHeader, textOffset, title);
  source.setRange(textOffset, source.length, text);
  return source;
}

List<int> samplePdf({String? secondPageText}) {
  const text = 'BT /F1 24 Tf 50 700 Td (Hello Technical Book) Tj ET';
  final secondPageContent = secondPageText == null
      ? null
      : 'BT /F1 24 Tf 50 700 Td ($secondPageText) Tj ET';
  final secondPageObject = secondPageContent == null ? 6 : 9;
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 5 0 R >> >> /Contents $secondPageObject 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${text.length} >>\nstream\n$text\nendstream',
    '<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>',
    '<< /Title (Second chapter) /Parent 7 0 R /Dest [4 0 R /Fit] >>',
    if (secondPageContent != null)
      '<< /Length ${secondPageContent.length} >>\nstream\n$secondPageContent\nendstream',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (final (i, object) in objects.indexed) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n$object\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(buffer.toString());
}

List<int> sampleEpub({
  String image = 'picture.png',
  bool vertical = false,
  int paragraphs = 1,
}) {
  final archive = Archive();
  void add(String name, String text) =>
      archive.addFile(ArchiveFile.string(name, text));
  add(
    'META-INF/container.xml',
    '<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>',
  );
  add(
    'OEBPS/book.opf',
    '<package><metadata><title>测试</title><creator>作者</creator></metadata><manifest><item id="a" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>',
  );
  add(
    'OEBPS/style.css',
    vertical ? 'body{writing-mode:vertical-rl}' : 'body{}',
  );
  add(
    'OEBPS/chapter.xhtml',
    '<html><head><link rel="stylesheet" href="style.css"/><title>章节</title></head><body><h1>第一章</h1><p>中文正文</p><ruby>漢<rt>hàn</rt></ruby><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40"><rect width="120" height="40" fill="#008080"/><text x="5" y="25">Diagram</text></svg><pre><code>docker run hello-world\n  --example</code></pre><img src="$image"/>${List.filled(paragraphs, '<p>阅读示例文字，保留章节内的分页及位置。</p>').join()}<script>alert(1)</script><iframe src="https://evil.test"/><p style="background:url(https://evil.test)">结束</p></body></html>',
  );
  final picture = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAANwAAABaCAIAAABc0a8TAAABvElEQVR4nO3SwUlDYRBG0dRkBy7cW4kNpU4RsspWnr4HEZK58T9wCxi+OafPr4uU6jR+gbQJSuWCUrmgVC4olQtK5YJSuaBULiiVC0rlglK5oFQuKJULSuWCUrmgVC4olQtK5YJSz4by7eP87xv/gdmhvGEdKEdmhxLK3OxQQpmbHUooc7NDCWVudiihzM0OJZS52aGEMjc7lFDmZocSytzsUEKZmx1KKHOzQwllbnYooczNDuUAypfXd7NDmUN57HLx2aEcQ3ngcvHZoZxEuedy8dmhHEb5q8vFZ4dyHuVPl4vPDmUC5cbl4rNDWUH53eXis0N53iMy2PgmDwjKo8YJQgnltnGCUEK5bZwglFBuGycIJZQ3rHOn9iyaHcoWSrND2UJpdihbKM0OZQul2aFsoTQ7lC2UZoeyhdLsUP5xnakWnx1KKHOzQwllbnYooczNDiWUudmhhDI3O5RQ5maHEsrc7FBCmZsdSihzs0MJZW52KKHMzQ4llLnZoYQyNzuUUD4bSunxQalcUCoXlMoFpXJBqVxQKheUygWlckGpXFAqF5TKBaVyQalcUCoXlMoFpXJBqVxQ6lLrCvDATx2my6NXAAAAAElFTkSuQmCC',
  );
  archive.addFile(ArchiveFile('OEBPS/picture.png', picture.length, picture));
  return ZipEncoder().encode(archive);
}
