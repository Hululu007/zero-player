import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_tokyo_hong_catalogue.dart';
import 'package:zero_player/features/publications/domain/publication.dart';

void main() {
  test('Tokyo Hong catalogue publishes a single stable metadata page', () {
    final edition = parseTokyoHongListing('''
      <form name="qform"><select name="col"></select></form>
      <table>
        <tr class="line_color_a">
          <td>1</td><td>司馬溫公切韻一卷</td><td>經-小學-音韻-宋</td>
          <td>雙紅堂-戲曲-283</td>
          <td>
            <a href="javascript:img_open('A582100','rn_no','00001','hb')">Scan</a>
            <a href="javascript:HelpClick('A582100')"><img alt="目錄data"></a>
          </td>
        </tr>
        <tr class="line_color_b">
          <td>2</td><td>Untrusted row</td><td>經</td><td>號</td>
          <td><a href="https://elsewhere.example/"><img alt="目錄data"></a></td>
        </tr>
      </table>
    ''').single;
    expect(edition.title, '司馬溫公切韻一卷');
    expect(edition.edition, '雙紅堂-戲曲-283');
    expect(edition.tags.single, '經-小學-音韻-宋');
    expect(
      edition.page,
      Uri.parse(
        'https://kanseki.ioc.u-tokyo.ac.jp/kanzi/user/query_detail_im.php?nu=A582100',
      ),
    );
    expect(edition.candidates, isEmpty);
  });

  test('Tokyo Hong distinguishes empty results from an unrelated page', () {
    expect(
      parseTokyoHongListing(
        '<form name="qform"><select name="col"></select></form>',
      ),
      isEmpty,
    );
    expect(
      () => parseTokyoHongListing('<h1>Access check</h1>'),
      throwsA(isA<PublicationFailure>()),
    );
  });
}
