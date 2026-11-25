import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero_player/app/shell.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/publications/presentation/baidu_token_guide.dart';

import '../../test_support/mobile_app_fixture.dart';

final _baidu = Uri.https('pan.baidu.com', '/s/fixture');

void main() {
  test('only Baidu access refusals qualify for the token guide', () {
    for (final problem in PublicationProblem.values) {
      expect(
        isBaiduTokenRefusal(_baidu, problem),
        const {
          PublicationProblem.login,
          PublicationProblem.challenge,
          PublicationProblem.guestLimit,
        }.contains(problem),
      );
    }
    expect(
      isBaiduTokenRefusal(
        Uri.https('pan.quark.cn', '/s/fixture'),
        PublicationProblem.login,
      ),
      isFalse,
    );
  });

  testWidgets('a failed Baidu task opens the guide only once', (tester) async {
    final fixture = MobileAppFixture();
    await tester.runAsync(fixture.initialize);
    final store = fixture.services.publications.store;
    Future<String> addFailure(String title) {
      final candidate = AcquisitionCandidate(
        source: 'manual',
        link: _baidu,
        format: PublicationFormat.pdf,
        fileId: '42',
      );
      return store.addTask(
        PublicationEdition(id: publicationId(title), title: title),
        [candidate],
        preflightFailure: const PublicationFailure(
          PublicationProblem.challenge,
        ),
      );
    }

    await tester.runAsync(() => addFailure('百度样本'));
    await fixture.pump(tester);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    final guide = find.text('获取百度网盘访问令牌');
    router.go('/publications?tab=tasks');
    await fixture.waitFor(tester, () => guide.evaluate().isNotEmpty);
    await fixture.settle(tester);
    expect(find.text('打开百度 OAuth 指南'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await fixture.settle(tester);
    expect(find.textContaining('来源要求网页验证'), findsOneWidget);

    final added = addFailure('另一个百度样本');
    await fixture.waitFor(
      tester,
      () => find.text('另一个百度样本').evaluate().isNotEmpty,
    );
    await added;
    await fixture.settle(tester);
    expect(guide, findsNothing);
    String? seen;
    final recorded = store
        .preference('baidu_token_guide_seen')
        .then((value) => seen = value);
    await fixture.waitFor(tester, () => seen == '1');
    await recorded;
    await fixture.finish(tester);
  });
}
