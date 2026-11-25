import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/books/application/reader_preloader.dart';
import 'package:zero_player/features/books/domain/book.dart';

void main() {
  final chapters = [
    for (var i = 1; i <= 5; i++)
      BookChapter('第$i章', Uri.https('reader.example', '/$i')),
  ];

  testWidgets('refills before reaching the end of the warmed window', (
    tester,
  ) async {
    final calls = <BookChapter>[];
    final loader = ReaderPreloader((chapter, token) async {
      calls.add(chapter);
    }, delay: const Duration(milliseconds: 500));
    addTearDown(loader.dispose);
    loader.schedule(chapters.sublist(1, 4), refillAt: 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, chapters.sublist(1, 4));

    final token = CancellationToken();
    await loader.enter(chapters[1], token);
    loader.schedule(chapters.sublist(2, 5), refillAt: 1);
    await tester.pump();
    expect(calls, chapters.sublist(1, 4));

    await loader.enter(chapters[2], token);
    loader.schedule(chapters.sublist(3), refillAt: 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, chapters.sublist(1));
  });

  testWidgets('entering an in-flight prefetch shares it without cancelling', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    final loader = ReaderPreloader((chapter, token) async {
      calls++;
      await gate.future;
      token.check();
    }, delay: Duration.zero);
    addTearDown(loader.dispose);
    loader.schedule([chapters.first]);
    await tester.pump(const Duration(milliseconds: 1));
    var ready = false;
    unawaited(
      loader
          .enter(chapters.first, CancellationToken())
          .then((_) => ready = true),
    );
    await tester.pump();
    expect(ready, isFalse);
    gate.complete();
    await tester.pump();
    expect(ready, isTrue);
    expect(calls, 1);
  });
}
