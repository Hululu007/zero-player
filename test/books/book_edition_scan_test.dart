import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/data/books_repository.dart';

import '../../test_support/book_editions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'publishes checked channels before slow searches and isolates failures',
    () async {
      final f = await BookEditionsFixture.create();
      addTearDown(f.close);
      final updates = <BookEditionUpdate>[];
      var finished = false;
      final scan = f.services.books.alternatives(
        f.book,
        CancellationToken(),
        refresh: true,
        includeCurrent: true,
        onProgress: updates.add,
      )..then((_) => finished = true);
      await _until(
        () =>
            f.slowWaiting &&
            updates.any((u) => u.edition?.chapters.length == 5) &&
            updates.any((u) => u.source?.source.id == f.sources['failed']!.id),
      );
      expect(finished, isFalse);
      expect(updates.first.total, 4);
      expect(updates.last.completed, lessThan(4));
      expect(
        updates
            .singleWhere((u) => u.source?.source.id == f.sources['failed']!.id)
            .failed,
        isTrue,
      );
      f.releaseSlow();
      final editions = await scan;
      expect(
        editions.map((e) => e.chapters.length),
        unorderedEquals([3, 5, 7]),
      );
      expect(updates.last.completed, 4);
    },
  );

  test('cancelled scans cannot publish late catalogues', () async {
    final f = await BookEditionsFixture.create();
    addTearDown(f.close);
    final token = CancellationToken();
    final updates = <BookEditionUpdate>[];
    final scan = f.services.books.alternatives(
      f.book,
      token,
      refresh: true,
      onProgress: updates.add,
    );
    final expectation = expectLater(scan, throwsA(isA<RequestCancelled>()));
    await _until(() => f.slowWaiting && updates.any((u) => u.edition != null));
    token.cancel();
    final count = updates.length;
    f.releaseSlow();
    await expectation;
    expect(updates, hasLength(count));
  });

  test(
    'a completed channel revoked during another search is omitted from final editions',
    () async {
      final f = await BookEditionsFixture.create();
      addTearDown(f.close);
      final updates = <BookEditionUpdate>[];
      final scan = f.services.books.alternatives(
        f.book,
        CancellationToken(),
        refresh: true,
        onProgress: updates.add,
      );
      await _until(
        () =>
            f.slowWaiting &&
            updates.any(
              (u) => u.edition?.book.sourceId == f.sources['fast']!.id,
            ),
      );
      await f.services.books.saveSource(f.sources['fast']!, {'enabled': false});
      f.releaseSlow();
      expect(
        (await scan).any((e) => e.book.sourceId == f.sources['fast']!.id),
        isFalse,
      );
    },
  );
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for a fixture channel');
}
