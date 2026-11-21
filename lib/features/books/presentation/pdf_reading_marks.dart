import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../domain/reading_mark.dart';
import 'reading_mark_tools.dart';

final class PdfReadingMarks {
  PdfReadingMarks(this.controller, this.allowed);
  final PdfViewerController controller;
  final bool Function() allowed;
  final _text = <int, PdfPageText?>{};
  final _pending = <int>{};
  List<ReadingMark> marks = const [];

  Future<PdfPageText?> _load(PdfPage page) async {
    final number = page.pageNumber;
    if (_text.containsKey(number)) return _text[number];
    try {
      final text = await controller.useDocument<PdfPageText?>(
        (document) => document.pages[number - 1].loadStructuredText(),
        ensureLoaded: false,
      );
      if (allowed()) _text[number] = text;
      return text;
    } on Exception {
      return null;
    }
  }

  Iterable<PdfPageTextRange> _ranges(PdfPageText text, ReadingMark mark) sync* {
    if (!mark.matches(text.fullText) ||
        mark.range.end > text.charRects.length) {
      return;
    }
    final first = text.getFragmentIndexForTextIndex(mark.range.start);
    final last = text.getFragmentIndexForTextIndex(mark.range.end - 1);
    if (first < 0 || last < first || last >= text.fragments.length) return;
    for (var index = first; index <= last; index++) {
      final fragment = text.fragments[index];
      yield PdfPageTextRange(
        pageText: text,
        start: math.max(mark.range.start, fragment.index),
        end: math.min(mark.range.end, fragment.end),
      );
    }
  }

  void paint(Canvas canvas, Rect pageRect, PdfPage page) {
    if (!allowed()) return;
    final items = marks.where((mark) => mark.section + 1 == page.pageNumber);
    if (items.isEmpty || !page.isLoaded) return;
    if (!_text.containsKey(page.pageNumber)) {
      if (_pending.add(page.pageNumber)) {
        unawaited(
          _load(page).whenComplete(() {
            _pending.remove(page.pageNumber);
            if (allowed()) controller.invalidate();
          }),
        );
      }
      return;
    }
    final text = _text[page.pageNumber];
    if (text == null) return;
    for (final mark in items) {
      for (final range in _ranges(text, mark)) {
        paintReadingMark(
          canvas,
          range.bounds
              .toRect(page: page, scaledPageSize: pageRect.size)
              .shift(pageRect.topLeft),
          mark,
        );
      }
    }
  }

  Future<void> jump(ReadingMark mark) async {
    if (!allowed() ||
        mark.section < 0 ||
        mark.section >= controller.pageCount) {
      return;
    }
    final page = controller.pages[mark.section];
    final text = await _load(page);
    if (!allowed() || text == null) return;
    final first = _ranges(text, mark).firstOrNull;
    if (first == null) return;
    await controller.ensureVisible(
      controller.calcRectForRectInsidePage(
        pageNumber: page.pageNumber,
        rect: first.bounds,
      ),
      margin: 50,
    );
  }
}
