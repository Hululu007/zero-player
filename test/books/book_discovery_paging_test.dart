import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/data/book_discovery_paging.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/domain/legado_source.dart';

void main() {
  final source = BookSource.fromJson({
    'name': '测试混合源',
    'url': 'https://mixed.example/',
    'kind': 'text',
    'format': 'html',
    'legado': {
      'search': '/search?key={{key}}',
      'rules': {'content': '#body@text'},
    },
  });

  test('known restricted paths and aliases take precedence over paging', () {
    const normal = LegadoCategory('玄幻', '/normal?page={{page}}');
    const adult = LegadoCategory('肉文', '/adult');
    expect(
      bookDiscoveryNextAllowed(source, normal, [adult], '/normal?page=2', 2),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        const LegadoCategory('玄幻', '/normal'),
        [adult],
        '/normal?page=2',
        2,
      ),
      isTrue,
    );
    for (final next in [
      '/adult',
      '/adult?page=2',
      'https://MIXED.example:443/adult/2',
      '/adult%2F2',
      'https://other.example/normal?page=2',
    ]) {
      expect(
        bookDiscoveryNextAllowed(source, normal, [adult], next, 2),
        isFalse,
        reason: next,
      );
    }
    for (final alias in [
      const LegadoCategory('普通', '/adult?page=1'),
      const LegadoCategory('普通', 'https://MIXED.example:443/adult/2'),
    ]) {
      expect(bookDiscoveryCategoryDenied(source, alias, [adult]), isTrue);
    }
  });

  test('restricted category takes priority over an otherwise valid next', () {
    const normal = LegadoCategory('玄幻', '/normal?page={{page}}');
    const restricted = LegadoCategory('肉文', '/normal/2');
    const alias = LegadoCategory('普通', '/normal/2');
    const next = '/normal/2?page=2';
    // Without the separately collected restricted category this resembles a
    // valid page of the ordinary category; it must still be denied with it.
    expect(bookDiscoveryNextAllowed(source, normal, [], next, 2), isTrue);
    expect(
      bookDiscoveryNextAllowed(source, normal, [restricted], next, 2),
      isFalse,
    );
    expect(bookDiscoveryCategoryDenied(source, alias, [restricted]), isTrue);
  });

  test('numeric siblings of restricted paths are treated as aliases', () {
    const adult = LegadoCategory('肉文', '/adult/1');
    for (final candidate in [
      const LegadoCategory('普通', '/adult/2'),
      const LegadoCategory('普通', '/adult/9?page=1'),
    ]) {
      expect(bookDiscoveryCategoryDenied(source, candidate, [adult]), isTrue);
    }
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/sort/2'),
        [const LegadoCategory('肉文', '/sort/1')],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/other/2'),
        [adult],
      ),
      isFalse,
    );
  });

  test('restricted query, form and JSON parameters match across carriers', () {
    const postAdult = LegadoCategory(
      '肉文',
      '/list,{"method":"POST","body":"kind=adult&page=1"}',
    );
    const getAdult = LegadoCategory('肉文', '/list?kind=adult');
    const jsonAdult = LegadoCategory(
      '肉文',
      '/list,{"method":"POST","body":{"kind":"adult","type":3}}',
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=adult&page=2'),
        [postAdult],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory(
          '普通',
          '/list,{"method":"POST","body":"kind=adult&page=2"}',
        ),
        [getAdult],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=adult&type=3'),
        [jsonAdult],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=normal'),
        [postAdult],
      ),
      isFalse,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=adult&type=4'),
        [jsonAdult],
      ),
      isFalse,
    );
  });

  test('fixed query discriminators survive encoding and extra parameters', () {
    const normal = LegadoCategory('玄幻', '/list?kind=normal&page={{page}}');
    const adult = LegadoCategory('肉文', '/list?kind=adult&page={{page}}');
    expect(
      bookDiscoveryNextAllowed(
        source,
        normal,
        [adult],
        '/list?page=2&kind=normal',
        2,
      ),
      isTrue,
    );
    for (final next in [
      '/list?kind=adult&page=2',
      '/list?%6bind=adult&page=2&extra=1',
      '/list?kind=adult&KIND=normal&page=2',
      '/list?kind=normal&sort=adult&page=2',
      '/list?kind=normal&page=999',
      '/list?kind=normal',
    ]) {
      expect(
        bookDiscoveryNextAllowed(source, normal, [adult], next, 2),
        isFalse,
        reason: next,
      );
    }
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=adult&PAGE=8'),
        [adult],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/list?kind=normal&page=1'),
        [adult],
      ),
      isFalse,
    );
  });

  test('only a proven numeric page position may change in a path', () {
    const normal = LegadoCategory('玄幻', '/sort/1/1');
    const adult = LegadoCategory('肉文', '/sort/2/1');
    expect(
      bookDiscoveryNextAllowed(source, normal, [adult], '/sort/1/2', 2),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(source, normal, [adult], '/sort/2/1', 2),
      isFalse,
    );
    expect(
      bookDiscoveryCategoryDenied(
        source,
        const LegadoCategory('普通', '/sort/2/2'),
        [adult],
      ),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        const LegadoCategory('玄幻', '/sort/1'),
        [],
        '/sort/2',
        2,
      ),
      isFalse,
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        const LegadoCategory('玄幻', '/sort/{{page}}'),
        [],
        '/sort/2',
        2,
      ),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        const LegadoCategory('玄幻', '/library/normal.html'),
        [],
        '/library/normal/2.html',
        2,
      ),
      isTrue,
    );
    expect(
      bookDiscoveryPageAllowed(
        source,
        const LegadoCategory('玄幻', '/sort/{{page}}'),
        [const LegadoCategory('肉文', '/sort/2')],
        2,
      ),
      isFalse,
    );
    expect(bookDiscoveryPageAllowed(source, normal, [adult], 0), isFalse);
  });

  test('POST pagination keeps the category discriminator fixed', () {
    const normal = LegadoCategory(
      '玄幻',
      '/list,{"method":"POST","body":"kind=normal&page={{page}}"}',
    );
    const adult = LegadoCategory(
      '肉文',
      '/list,{"method":"POST","body":"kind=adult&page={{page}}"}',
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        normal,
        [adult],
        '/list,{"method":"POST","body":"kind=normal&page=2"}',
        2,
      ),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        normal,
        [adult],
        '/list,{"method":"POST","body":"kind=adult&page=2"}',
        2,
      ),
      isFalse,
    );
    expect(
      bookDiscoveryNextAllowed(source, normal, [adult], '/list?page=2', 2),
      isFalse,
    );
  });

  test('page requests cannot alter approved headers or character encoding', () {
    const selected = LegadoCategory(
      '玄幻',
      '/normal?page={{page}},{"headers":{"User-Agent":"approved"},"charset":"gbk"}',
    );
    expect(
      bookDiscoveryNextAllowed(
        source,
        selected,
        [],
        '/normal?page=2,{"headers":{"User-Agent":"approved"},"charset":"gbk"}',
        2,
      ),
      isTrue,
    );
    for (final next in [
      '/normal?page=2',
      '/normal?page=2,{"headers":{"User-Agent":"different"},"charset":"gbk"}',
      '/normal?page=2,{"headers":{"User-Agent":"approved"},"charset":"utf-8"}',
      '/normal?page=2,{"headers":{"User-Agent":"approved","Referer":"https://mixed.example/other"},"charset":"gbk"}',
    ]) {
      expect(
        bookDiscoveryNextAllowed(source, selected, [], next, 2),
        isFalse,
        reason: next,
      );
    }
    expect(bookDiscoveryPageAllowed(source, selected, [], 2), isTrue);
  });

  test(
    'unresolved scripts fail closed but expanded concrete categories work',
    () {
      const normal = LegadoCategory('玄幻', '/normal?page={{page}}');
      const unknownAdult = LegadoCategory('肉文', "@js:java.ajax('/adult')");
      expect(
        bookDiscoveryCategoryDenied(source, normal, [unknownAdult]),
        isTrue,
      );
      expect(bookDiscoveryCategoryDenied(source, normal, []), isFalse);
      expect(
        bookDiscoveryCategoryDenied(
          source,
          const LegadoCategory('普通', '@js:result'),
          [const LegadoCategory('肉文', '/adult')],
        ),
        isTrue,
      );
      expect(
        bookDiscoveryNextAllowed(
          source,
          normal,
          [unknownAdult],
          '/normal?page=2',
          2,
        ),
        isFalse,
      );
      expect(
        bookDiscoveryNextAllowed(
          source,
          const LegadoCategory('玄幻', '@js:result'),
          [],
          '/normal?page=2',
          2,
        ),
        isFalse,
      );
      expect(
        bookDiscoveryNextAllowed(
          source,
          normal,
          [const LegadoCategory('肉文', '/adult')],
          '/normal?page=2',
          2,
        ),
        isTrue,
      );
    },
  );

  test('native category adapters accept only their expected numeric page', () {
    final audio = BookSource.fromJson({
      'name': '书音',
      'url': 'https://m.mekui.com/ecmsapi/index.php',
      'kind': 'audio',
      'format': 'shuyin',
    });
    expect(
      bookDiscoveryNextAllowed(
        audio,
        const LegadoCategory('普通', '1'),
        [],
        '2',
        2,
      ),
      isTrue,
    );
    expect(
      bookDiscoveryNextAllowed(
        audio,
        const LegadoCategory('普通', '1'),
        [],
        '/adult',
        2,
      ),
      isFalse,
    );
    expect(
      bookDiscoveryNextAllowed(
        audio,
        const LegadoCategory('普通', '1'),
        [],
        '3',
        2,
      ),
      isFalse,
    );
  });
}
