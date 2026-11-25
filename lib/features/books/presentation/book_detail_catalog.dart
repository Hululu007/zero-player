part of 'book_detail_page.dart';

const _catalogPageSize = 120;

extension _BookDetailCatalog on _BookDetailPageState {
  List<BookChapter> get _visibleChapters {
    final chapters = _reverse ? _readerCatalog.reversed : _readerCatalog;
    return chapters
        .where(
          (c) =>
              _books.policy.textAllowed(c.title) &&
              (!_offline || _saved.contains(c.id) || isRebuiltBookChapter(c)) &&
              c.title.toLowerCase().contains(_chapterQuery),
        )
        .toList();
  }

  int _catalogPageCount(int chapters) =>
      chapters == 0 ? 1 : (chapters + _catalogPageSize - 1) ~/ _catalogPageSize;

  int _currentCatalogPage(int chapters) =>
      _catalogPage.clamp(0, _catalogPageCount(chapters) - 1);

  void _jumpToCurrent() {
    if (_last != null) _locateChapter((chapter) => chapter.id == _last);
  }

  void _locateChapter(bool Function(BookChapter) matches) {
    _updateCatalog(() {
      _offline = false;
      _reverse = false;
      _chapterQuery = '';
      _filter.clear();
    });
    final index = _visibleChapters.indexWhere(matches);
    if (index < 0) return;
    _showCatalogPage(index ~/ _catalogPageSize, row: index % _catalogPageSize);
  }

  void _showCatalogPage(int page, {int row = 0}) {
    _updateCatalog(() => _catalogPage = page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _catalogPage != page) return;
      final header = _catalogHeader.currentContext?.size?.height;
      if (header == null) return;
      _scrollCatalogTo(
        header + row * _BookDetailPageState._chapterExtent,
        immediate: true,
      );
    });
  }

  void _scrollCatalogTo(double offset, {bool immediate = false}) {
    if (!_catalogScroll.hasClients) return;
    final target = offset.clamp(0.0, _catalogScroll.position.maxScrollExtent);
    if (immediate || MediaQuery.disableAnimationsOf(context)) {
      _catalogScroll.jumpTo(target);
    } else {
      unawaited(
        _catalogScroll.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Future<void> _jumpToChapter() async {
    final bookId = _book.id;
    final ordered = _readerCatalog
        .where((chapter) => _books.policy.textAllowed(chapter.title))
        .toList();
    final index = await showDialog<int>(
      context: context,
      useRootNavigator: false,
      builder: (context) => _ChapterNumberDialog(total: ordered.length),
    );
    if (!mounted || index == null || bookId != _book.id || !_pageBookAllowed) {
      return;
    }
    _locateChapter((chapter) => chapter.id == ordered[index].id);
  }

  Widget _catalogNavigation(bool hasLast, int page, int visibleCount) {
    final pages = _catalogPageCount(visibleCount);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '跳转章节',
          onPressed:
              _readerCatalog.any(
                (chapter) => _books.policy.textAllowed(chapter.title),
              )
              ? _jumpToChapter
              : null,
          icon: const Icon(Icons.format_list_numbered),
        ),
        IconButton(
          tooltip: '定位当前章节',
          onPressed: hasLast ? _jumpToCurrent : null,
          icon: const Icon(Icons.my_location),
        ),
        if (pages > 1) ...[
          IconButton(
            tooltip: '目录上一页',
            onPressed: page == 0 ? null : () => _showCatalogPage(page - 1),
            icon: const Icon(Icons.chevron_left),
          ),
          Flexible(child: Text('${page + 1}/$pages', maxLines: 1)),
          IconButton(
            tooltip: '目录下一页',
            onPressed: page + 1 >= pages
                ? null
                : () => _showCatalogPage(page + 1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ],
    );
  }
}

final class _ChapterNumberDialog extends StatefulWidget {
  const _ChapterNumberDialog({required this.total});
  final int total;

  @override
  State<_ChapterNumberDialog> createState() => _ChapterNumberDialogState();
}

final class _ChapterNumberDialogState extends State<_ChapterNumberDialog> {
  int? _number;
  bool get _valid =>
      _number != null && _number! >= 1 && _number! <= widget.total;

  void _submit() {
    if (_valid) Navigator.pop(context, _number! - 1);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('跳转章节'),
    content: TextField(
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: '目录序号',
        helperText: '请输入 1–${widget.total}',
      ),
      onChanged: (value) => setState(() => _number = int.tryParse(value)),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _valid ? _submit : null, child: const Text('定位')),
    ],
  );
}
