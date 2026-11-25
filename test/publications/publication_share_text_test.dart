import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_share_provider.dart';
import 'package:zero_player/features/publications/domain/share_text.dart';

void main() {
  test('Baidu share handoff keeps only the selected extraction code', () {
    final input = publicationShareInputs(
      'pan.baidu.com/s/fixture-1?pwd=ab12&from=sample\n提取码：cd34',
    ).single;
    expect(input.needsConfirmation, isTrue);
    expect(input.link, Uri.https('pan.baidu.com', '/s/fixture-1'));
    expect(
      baiduPublicationSharePage(input.link, 'cd34'),
      Uri.https('pan.baidu.com', '/s/fixture-1', {'pwd': 'cd34'}),
    );
    expect(
      baiduPublicationSharePage(
        Uri.parse('http://pan.baidu.com/s/fixture-1?pwd=ab12#ignored'),
        null,
      ),
      input.link,
    );
    for (final address in [
      'https://pan.baidu.com.example/s/fixture-1',
      'https://pan.baidu.com:8443/s/fixture-1',
      'https://other.pan.baidu.com/s/fixture-1',
      'https://pan.baidu.com/s/fixture-1/more',
    ]) {
      expect(isBaiduPublicationShare(Uri.parse(address)), isFalse);
    }
    expect(
      () => baiduPublicationSharePage(input.link, 'a c!'),
      throwsFormatException,
    );
  });

  test('known cloud share domains may be pasted without the scheme', () {
    final inputs = publicationShareInputs(
      '链接：\npan.quark.cn/s/first?pwd=ab12\n提取码：ab12\n\n'
      '链接：drive.uc.cn/s/second 提取码：cd34',
    );
    expect(inputs.map((input) => input.link.toString()), [
      'https://pan.quark.cn/s/first',
      'https://drive.uc.cn/s/second',
    ]);
    expect(inputs.map((input) => input.code), ['ab12', 'cd34']);
    expect(inputs.every((input) => !input.needsConfirmation), isTrue);
  });

  test('a host embedded in an unqualified URL never becomes a cloud share', () {
    for (final text in [
      'example.test/pan.quark.cn/s/first',
      'other.pan.quark.cn/s/first',
      'pan.quark.cn.example.test/s/first',
      'example@drive.uc.cn/s/second',
      r'K:\pan.quark.cn/s/first',
    ]) {
      expect(() => publicationShareInputs(text), throwsFormatException);
    }
  });

  test('passwords before a share link stay in its own paragraph', () {
    final inputs = publicationShareInputs(
      '链接: https://a.example/books/first.zip\r\n'
      '　\r\n'
      '提取码: bc42\r\n'
      'ZIP 压缩包密码: archive-b\r\n'
      'PDF 文档密码: 文档乙\r\n'
      '链接: https://b.example/books/second.zip',
    );

    expect(inputs.map((input) => input.code), [null, 'bc42']);
    expect(inputs.map((input) => input.zipPassword), [null, 'archive-b']);
    expect(inputs.map((input) => input.pdfPassword), [null, '文档乙']);
    expect(inputs.map((input) => input.needsConfirmation), [false, false]);
  });

  test('a prefix on the next link line stays with that link', () {
    final inputs = publicationShareInputs(
      'https://a.example/s/first?pwd=aa22\n'
      'ZIP 密码: archive-a\n'
      '提取码: bb33 PDF 密码: document-b https://b.example/s/second',
    );

    expect(inputs.map((input) => input.code), ['aa22', 'bb33']);
    expect(inputs.map((input) => input.zipPassword), ['archive-a', null]);
    expect(inputs.map((input) => input.pdfPassword), [null, 'document-b']);
    expect(inputs.every((input) => !input.link.hasQuery), isTrue);
    expect(inputs.every((input) => !input.needsConfirmation), isTrue);
  });

  test('a single link retains credentials separated by a blank line', () {
    final input = publicationShareInputs(
      '提取码: ph35\n\nhttps://a.example/books/manual.pdf\n\nPDF 密码: notes',
    ).single;

    expect(input.code, 'ph35');
    expect(input.pdfPassword, 'notes');
    expect(input.needsConfirmation, isFalse);
  });

  test('document passwords in a shared header stay unassigned', () {
    final inputs = publicationShareInputs(
      'ZIP 压缩包密码: archive\n'
      'PDF 文档密码: notes\n'
      'https://a.example/books/first.zip?pwd=aa22\n'
      'https://b.example/books/second.zip',
    );

    expect(inputs.map((input) => input.code), ['aa22', null]);
    expect(inputs.every((input) => input.zipPassword == null), isTrue);
    expect(inputs.every((input) => input.pdfPassword == null), isTrue);
    expect(inputs.every((input) => !input.needsConfirmation), isTrue);
  });
}
