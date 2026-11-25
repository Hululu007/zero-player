import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/features/books/domain/reading_mark.dart';
import 'package:zero_player/features/books/presentation/reader_pagination.dart';
import 'package:zero_player/features/books/presentation/reader_style.dart';

void main() {
  testWidgets(
    'right-click quick marking keeps the original text range',
    (tester) async {
      const body = 'One two three four five';
      String selection = '';
      (ReadingRange, ReadingMarkStyle?)? mark;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderViewport(
              text: body,
              titleLength: 0,
              style: const TextStyle(fontSize: 20),
              palette: const ReaderPalette(
                Colors.white,
                Colors.black,
                Colors.blue,
              ),
              mode: ReaderTurnMode.scroll,
              animate: false,
              texture: false,
              margin: 20,
              initial: readerProgress(0),
              onProgress: (_) {},
              canCross: (_) => false,
              onBoundary: (_) {},
              onSelection: (value) => selection = value,
              onAnnotate: () {},
              onMark: (range, style) => mark = (range, style),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = find.text(body, findRichText: true);
      final origin = tester.getTopLeft(text) + const Offset(2, 10);
      final drag = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(205, 0));
      await drag.up();
      await tester.pumpAndSettle();
      final selected = selection;
      expect(selected, startsWith('One two'));
      final click = await tester.startGesture(
        origin + const Offset(40, 0),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.up();
      await tester.pumpAndSettle();
      final highlight = find.text('背景高亮');
      expect(highlight, findsOneWidget);
      await tester.tap(highlight);
      await tester.pumpAndSettle();
      expect(mark?.$2, ReadingMarkStyle.highlight);
      final range = mark!.$1;
      expect(body.substring(range.start, range.end), selected);
      expect(selection, selected);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}
