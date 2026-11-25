import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/publications/data/publication_shuge_catalogue.dart';

void main() {
  test(
    'only declared licences and verified Shuge references permit resolution',
    () {
      final data = {
        'resource_id': 'SJ00000771',
        'resource_type': '书籍',
        'resource_name': '鲁班木经匠家镜',
        'responsibility': [
          {'name': '午荣'},
        ],
        'edition_info': '清代刊本',
        'intro_url': 'https://www.shuge.org/view/lu_ban_mu_jing/',
        'license': 'CC BY 4.0',
        'download_url': 'https://s.shuge.org/tzlbmj',
      };
      final book = shugeRecord(data);
      expect(book?.author, '午荣');
      expect(book?.share?.host, 's.shuge.org');
      expect(shugeRecord({...data, 'license': '未申明'})?.share, isNull);
      expect(
        shugeRecord({
          ...data,
          'download_url': 'https://s.shuge.org.evil.test/original',
        })?.share,
        isNull,
      );
      expect(
        shugeRecord({...data, 'intro_url': 'https://outside.test/view/book/'}),
        isNull,
      );
    },
  );

  test(
    'public storage selection ignores third parties and ambiguous share ids',
    () {
      expect(
        shugeStorageShares(
          Uri.parse(
            'https://f.shuge.org/dl/?sj=Readable&yun=Original&bd=OtherPan',
          ),
        ),
        [
          (host: 'du.shuge.org', id: 'Readable'),
          (host: 'yun.shuge.org', id: 'Original'),
        ],
      );
      expect(
        shugeStorageShares(
          Uri.parse('https://f.shuge.org/dl/4/?sj=TokenOne&sj=TokenTwo'),
        ),
        isEmpty,
      );
      expect(
        shugeStorageShares(Uri.parse('https://other.test/dl/?sj=Readable')),
        isEmpty,
      );
      expect(
        shugeStorageShares(Uri.parse('https://f.shuge.org/other/?sj=Readable')),
        isEmpty,
      );
    },
  );
}
