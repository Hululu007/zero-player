import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/network/cancellation_token.dart';

abstract interface class PdfReaderSearch implements Listenable {
  bool get isSearching;
  int get matchCount;
  void startTextSearch(String query);
  void resetTextSearch();
  Future<int> goToNextMatch();
  void pageTextMatchPaintCallback(Canvas canvas, Rect pageRect, PdfPage page);
  void dispose();
}

final class LegacyPdfReaderSearch extends PdfTextSearcher
    implements PdfReaderSearch {
  LegacyPdfReaderSearch(super.controller);

  @override
  int get matchCount => matches.length;
}

/// Keeps one count per scanned page and one highlight for the selected result.
final class PublicationPdfSearch extends ChangeNotifier
    implements PdfReaderSearch {
  PublicationPdfSearch(this._viewer, this._isAllowed);

  final PdfViewerController _viewer;
  final bool Function() _isAllowed;
  final _pageCounts = <int>[];
  Future<void> _scanWork = Future.value();
  Timer? _debounce;
  CancellationToken? _scan;
  String _query = '';
  int _generation = 0;
  int _count = 0;
  int _selected = -1;
  ({int page, PdfRect bounds})? _highlight;
  bool _paused = false;
  bool _moving = false;
  bool _disposed = false;

  @override
  bool get isSearching => _scan != null;
  bool get isPaused => _paused;
  @override
  int get matchCount => _count;

  @override
  void startTextSearch(String query) {
    _clear();
    _query = query.trim().toLowerCase();
    if (_query.isNotEmpty && _canRead(_generation)) {
      _beginScan(debounce: true);
    } else {
      _changed();
    }
  }

  void togglePause() {
    if (!_canRead(_generation)) return;
    if (_paused) {
      _beginScan();
    } else if (isSearching) {
      _cancelScan();
      _paused = true;
      _changed();
    }
  }

  void _beginScan({bool debounce = false}) {
    final token = CancellationToken();
    final generation = _generation;
    final query = _query;
    _paused = false;
    _scan = token;
    void queueScan() {
      _scanWork = _scanWork.then((_) => _searchPages(query, generation, token));
    }

    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 500), queueScan);
    } else {
      queueScan();
    }
    _changed();
  }

  Future<void> _searchPages(
    String query,
    int generation,
    CancellationToken token,
  ) async {
    bool running() => !token.isCancelled && _canRead(generation);
    try {
      if (!running()) return;
      await _viewer.useDocument((document) async {
        while (_pageCounts.length < document.pages.length) {
          if (!running()) return;
          final page = await _loadedPage(
            document.pages[_pageCounts.length],
            token,
          );
          if (!running()) return;
          if (page == null) {
            _paused = true;
            return;
          }
          final text = await page.loadStructuredText();
          if (!running()) return;
          final matches = query.allMatches(text.fullText.toLowerCase());
          final count = matches.length;
          _pageCounts.add(count);
          if (count == 0) continue;
          _count += count;
          _changed();
          if (_selected < 0 && !_moving) {
            _moving = true;
            try {
              await _select(text, matches.first, 0, generation);
            } finally {
              _moving = false;
            }
          }
        }
      });
    } catch (_) {
      if (running()) _paused = true;
    } finally {
      if (!_disposed && identical(_scan, token)) {
        _scan = null;
        _changed();
      }
    }
  }

  Future<PdfPage?> _loadedPage(PdfPage page, CancellationToken token) async {
    if (page.isLoaded) return page;
    // Progressive loading replaces page placeholders instead of updating them.
    final loading = StreamIterator(
      page.events.map((event) => event.page).where((page) => page.isLoaded),
    );
    final unlisten = token.listen(() => unawaited(loading.cancel()));
    try {
      return await loading.moveNext() ? loading.current : null;
    } finally {
      unlisten();
      await loading.cancel();
    }
  }

  @override
  Future<int> goToNextMatch() async {
    final generation = _generation;
    final index = _selected + 1;
    if (_moving || index >= _count || !_canRead(generation)) return -1;
    var matchOnPage = index;
    var pageIndex = 0;
    while (matchOnPage >= _pageCounts[pageIndex]) {
      matchOnPage -= _pageCounts[pageIndex++];
    }
    final query = _query;
    _moving = true;
    try {
      return await _viewer.useDocument((document) async {
            final text = await document.pages[pageIndex].loadStructuredText();
            if (!_canRead(generation)) return -1;
            final match = query
                .allMatches(text.fullText.toLowerCase())
                .skip(matchOnPage)
                .firstOrNull;
            if (match == null) return -1;
            await _select(text, match, index, generation);
            return _canRead(generation) ? index : -1;
          }) ??
          -1;
    } on Exception {
      return -1;
    } finally {
      _moving = false;
    }
  }

  Future<void> _select(
    PdfPageText text,
    Match match,
    int index,
    int generation,
  ) async {
    final bounds = PdfPageTextRange(
      pageText: text,
      start: match.start,
      end: match.end,
    ).bounds;
    _highlight = (page: text.pageNumber, bounds: bounds);
    _selected = index;
    _changed();
    final target = _viewer.calcRectForRectInsidePage(
      pageNumber: text.pageNumber,
      rect: bounds,
    );
    // The reader toolbar overlays the viewer and can hide a result at its edge.
    await _viewer.goTo(
      _viewer.calcMatrixForRect(target, zoomMax: _viewer.currentZoom),
      duration: Duration.zero,
    );
    if (_canRead(generation)) _viewer.setCurrentPageNumber(text.pageNumber);
  }

  @override
  void pageTextMatchPaintCallback(Canvas canvas, Rect pageRect, PdfPage page) {
    final hit = _highlight;
    if (hit == null || hit.page != page.pageNumber || !_canRead(_generation)) {
      return;
    }
    final rect = hit.bounds
        .toRect(page: page, scaledPageSize: pageRect.size)
        .translate(pageRect.left, pageRect.top);
    canvas.drawRect(
      rect,
      Paint()
        ..color =
            _viewer.params.activeMatchTextColor ?? Colors.orange.withAlpha(127),
    );
  }

  bool _canRead(int generation) =>
      !_disposed &&
      generation == _generation &&
      _viewer.isReady &&
      _isAllowed();

  void _changed() {
    if (_viewer.isReady) _viewer.invalidate();
    notifyListeners();
  }

  void _cancelScan() {
    _debounce?.cancel();
    _scan?.cancel();
    _scan = null;
  }

  void _clear() {
    _generation++;
    _cancelScan();
    _pageCounts.clear();
    _query = '';
    _count = 0;
    _selected = -1;
    _highlight = null;
    _paused = false;
  }

  @override
  void resetTextSearch() {
    _clear();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _clear();
    super.dispose();
  }
}
