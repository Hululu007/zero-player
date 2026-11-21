part of 'book_reader_page.dart';

extension _TextReaderMarks on _BookReaderPageState {
  bool _marksAllowed() =>
      _books.bookAllowed(widget.book) &&
      (!_books.store.vault.isPrivate(widget.book.id) ||
          _books.store.vault.unlocked);

  Listenable get _markPolicy => Listenable.merge([
    _books.policy,
    _books.sourceRiskChanges,
    _books.store.vault,
  ]);

  String _textVersion(BookChapter chapter, String text) =>
      sha256.convert(utf8.encode('${chapter.id}\u0000$text')).toString();

  Future<void> _reloadTextMarks() async {
    if (!_marksAllowed()) return;
    try {
      final marks = await _textMarkStore.load();
      if (mounted && _marksAllowed()) {
        _setReadingMarks([
          for (final mark in marks)
            if (_books.policy.textAllowed(mark.quote)) mark,
        ]);
      }
    } on Exception {
      if (mounted) _readerNotice('无法读取标注');
    }
  }

  Future<void> _editTextMark(ReadingRange range) async {
    final digest = _markDigest;
    if (!_ready ||
        !_marksAllowed() ||
        digest == null ||
        _index < 0 ||
        range.start < 0 ||
        range.end > _text.length ||
        range.end <= range.start) {
      return;
    }
    final quote = _text.substring(range.start, range.end);
    final whitespace = RegExp(r'\s+');
    if (quote.replaceAll(whitespace, '') !=
        _selection.replaceAll(whitespace, '')) {
      return;
    }
    final draft = ReadingMark(
      digest: digest,
      section: _index,
      range: range,
      quote: quote,
    );
    try {
      _stopAutomation();
      final mark = await editReadingMark(
        context,
        _textMarks
                .where((item) => item.identity == draft.identity)
                .firstOrNull ??
            draft,
        policy: _markPolicy,
        allowed: _marksAllowed,
      );
      if (mounted && mark != null && _marksAllowed()) {
        await _textMarkStore.save(mark);
        await _reloadTextMarks();
      }
    } on Exception {
      if (mounted) _readerNotice('无法保存标注');
    }
  }

  Future<void> _openTextMarks() async {
    if (!_ready || !_marksAllowed()) return;
    _stopAutomation();
    final mark = await showReadingMarks(
      context,
      initial: _textMarks,
      save: _textMarkStore.save,
      delete: _textMarkStore.delete,
      location: (mark) => mark.section < _chapters.length
          ? _chapters[mark.section].title
          : '章节不可用',
      policy: _markPolicy,
      allowed: _marksAllowed,
    );
    if (!mounted || !_marksAllowed()) return;
    await _reloadTextMarks();
    if (!mounted ||
        mark == null ||
        !_marksAllowed() ||
        mark.section >= _chapters.length) {
      return;
    }
    final chapter = _chapters[mark.section];
    if (chapter != _chapter) await _open(chapter);
    if (!mounted || !_ready || !_marksAllowed()) return;
    if (_markDigest != mark.digest || !mark.matches(_text)) {
      _readerNotice('原文版本已变更，无法定位');
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ready && _marksAllowed() && _markDigest == mark.digest) {
        _viewport.currentState?.jumpToOffset(mark.range.start);
      }
    });
  }
}
