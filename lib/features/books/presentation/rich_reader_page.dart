import '../../../core/platform/foreground_workload.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/platform_services.dart';
import '../data/local_book.dart';
import '../data/books_repository.dart';
import '../data/rich_book.dart';
import '../data/reading_marks_store.dart';
import '../data/book_site_check.dart';
import '../domain/book.dart';
import '../domain/reading_mark.dart';
import '../domain/rich_document_access.dart';
import 'pdf_reader_search.dart';
import 'pdf_reading_marks.dart';
import 'rich_document_notes.dart';
import 'reading_mark_tools.dart';
import 'reader_style.dart';
import 'reader_automation.dart';
import 'reader_pagination.dart' show ReaderTapZones;
import 'reader_system_ui.dart';
import 'reader_safe_area.dart';
import 'vertical_book_text.dart';
import 'epub_contents_sheet.dart';
import 'epub_html_viewport.dart';
import 'epub_source.dart';

class RichReaderPage extends StatefulWidget {
  const RichReaderPage({
    super.key,
    required this.repository,
    required this.book,
    required this.file,
    this.initial,
    this.platform,
    this.document,
  });
  final BooksRepository repository;
  final Book book;
  final File file;
  final BookChapter? initial;
  final PlatformServices? platform;
  final RichDocumentAccess? document;
  @override
  State<RichReaderPage> createState() => _RichReaderState();
}

class _RichReaderState extends State<RichReaderPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  GlobalKey<VerticalBookTextState> _vertical = GlobalKey();
  GlobalKey<EpubHtmlViewportState> _html = GlobalKey();
  EpubSource? _epubSource;
  int? _sourceOffset, _restoreSourceOffset;
  double _restoreFraction = 0;
  int _initialVerticalPage = 0;
  double? _seeking;
  int _epubLinkRevision = 0;

  bool get _verticalLayout =>
      !_isPdf && !_horizontal && _sections?[_index].vertical == true;
  late final _markStore = ReadingMarksStore(
    widget.repository.store,
    widget.book,
    _markAllowed,
  );
  List<ReadingMark> _marks = const [];
  bool _horizontal = false;
  late String _policySnapshot;
  bool _validated = false;
  final _pdf = PdfViewerController();
  bool _pdfCanMark = false;
  late final _pdfMarks = PdfReadingMarks(_pdf, () => mounted && _markAllowed());
  late final _systemUi = ReaderSystemUi(widget.platform);
  PdfReaderSearch? _searcher;
  final _searchInput = TextEditingController();
  List<RichSection>? _sections;
  List<BookChapter> _chapters = [];
  List<PdfOutlineNode> _outline = [];
  ReaderPreferences _style = const ReaderPreferences();
  int _index = 0;
  String? _error;
  String _query = '';
  String _selection = '';
  bool _controls = false, _auto = false;
  bool _configuring = false;
  Timer? _saveTimer;
  late final _releaseReading = ForegroundWorkload.instance.beginReading();
  late final _automation = ReaderAutomation(this, _advanceAutomatically);
  double? _resumeOffset;
  double _lastScrollOffset = 0, _scrollFraction = 0;
  int _verticalPage = 0;
  bool get _isPdf => widget.file.path.toLowerCase().endsWith('.pdf');
  bool get _ready =>
      _validated && _error == null && (!_isPdf || _searcher != null);
  String get _positionKey => 'rich_position_${widget.book.id}';

  @override
  void initState() {
    super.initState();
    _releaseReading;
    WidgetsBinding.instance.addObserver(this);
    _policySnapshot = bookSitePolicySnapshot(widget.repository.policy);
    widget.repository.policy.addListener(_onPolicyChanged);
    if (widget.document != null) {
      widget.repository.store.vault.addListener(_onPolicyChanged);
    }
    _load();
  }

  bool get _continuous =>
      !_isPdf && !_verticalLayout && _style.mode == ReaderTurnMode.scroll;

  void _advanceAutomatically(double? seconds) {
    if (!_ready ||
        _controls ||
        _configuring ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (seconds == null || !_continuous) {
      if (seconds == null) _next(1);
      return;
    }
    _html.currentState?.advance(_style.scrollSpeed * seconds);
  }

  void _startAutomation() {
    if (!_ready || !_style.autoEnabled) return;
    _hideControls();
    if (!_auto) setState(() => _auto = true);
    _automation.start(scroll: _continuous, interval: _style.autoSeconds);
  }

  void _onPolicyChanged() {
    final next = bookSitePolicySnapshot(widget.repository.policy);
    if (next == _policySnapshot &&
        widget.repository.bookAllowed(widget.book) &&
        widget.document?.isAllowed() != false) {
      return;
    }
    _policySnapshot = next;
    _stop();
    _saveTimer?.cancel();
    _searcher?.resetTextSearch();
    _searchInput.clear();
    setState(() {
      _auto = false;
      _controls = false;
      _query = '';
      _error = '内容策略已变更，请退出后重新打开';
    });
  }

  Future<void> _load() async {
    try {
      final repository = widget.repository;
      final document = widget.document;
      final data = await repository.store.read('books_reader_preferences');
      final position = await document?.loadPosition();
      final stored = document == null
          ? await repository.store.readBookValue(widget.book, _positionKey)
          : position == null
          ? null
          : {
              'index': position.index,
              'horizontal': position.horizontal,
              'verticalPage': position.verticalPage,
              'sourceOffset': position.sourceOffset,
              'offset': position.offset,
            };
      final saved = document == null
          ? await repository.store.entry(widget.book)
          : null;
      final chapters =
          document?.chapters ?? saved?.chapters ?? const <BookChapter>[];
      if (chapters.isEmpty) throw const FormatException('电子书目录为空');
      final sections = _isPdf
          ? null
          : await readRichEpubOffThread(
              await readLocalBookBytes(widget.file),
              internalLinks: true,
            );
      if (!mounted || _error != null) return;
      if (sections != null && sections.length != chapters.length) {
        throw const FormatException('EPUB 文件与已导入目录不一致');
      }
      if (!await _contentAllowed(chapters, sections)) {
        if (mounted && _error == null) {
          setState(() => _error = '当前内容策略限制访问此书');
        }
        return;
      }
      if (!mounted || _error != null) return;
      final storedIndex = stored is Map ? stored['index'] : stored;
      final selected = chapters.indexWhere(
        (chapter) => chapter.id == widget.initial?.id,
      );
      final index =
          (selected >= 0
                  ? selected
                  : storedIndex is int
                  ? storedIndex
                  : chapters.indexWhere((chapter) => chapter.id == saved?.last))
              .clamp(0, chapters.length - 1);
      var style = data is Map ? ReaderPreferences.fromJson(data) : _style;
      if (!await repository.readerFonts.ensure(style.family)) {
        style = style.copyWith(family: 'system');
      }
      if (!mounted || _error != null) return;
      setState(() {
        _validated = true;
        _chapters = chapters;
        _style = style;
        _sections = sections;
        if (sections != null) _epubSource = EpubSource(sections[index].html);
        _index = index;
        if (stored is Map) {
          _horizontal = stored['horizontal'] == true;
          if (storedIndex == index) {
            final verticalPage = stored['verticalPage'];
            final anchor = stored['sourceOffset'];
            if (anchor is int && sections != null && anchor >= 0) {
              _restoreSourceOffset = _sourceOffset = anchor.clamp(
                0,
                _epubSource!.text.length,
              );
            }
            final offset = stored['offset'];
            if (verticalPage is int) {
              _initialVerticalPage = _verticalPage = verticalPage.clamp(
                0,
                100000,
              );
            }
            if (offset is num) {
              _lastScrollOffset = _resumeOffset = offset.toDouble().clamp(
                0,
                10000000,
              );
            }
            if (position != null) {
              _scrollFraction = position.fraction;
            } else if (saved?.last == chapters[index].id) {
              _scrollFraction = saved!.position.clamp(0.0, 1.0);
            }
          }
        }
      });
      if (_isPdf) _save();
      if (!_isPdf) unawaited(_refreshMarks());
      _systemUi.apply(_style.immersive);
      if (!_isPdf && _style.autoEnabled) _startAutomation();
    } on Exception {
      if (mounted && _error == null) {
        setState(() => _error = '无法打开电子书，文件可能损坏或格式不受支持');
      }
    }
  }

  Future<bool> _contentAllowed(
    List<BookChapter> chapters,
    List<RichSection>? sections,
  ) async {
    final repository = widget.repository;
    // EPUB/PDF documents are local imports; remote content uses the guarded
    // online reader and must not be paired with an unrelated local file.
    if (widget.book.sourceId != 'local') return false;
    if (!repository.bookAllowed(widget.book)) return false;
    if (widget.document case final document?) {
      return document.isAllowed() &&
          (sections == null ||
              sections.every(
                (section) =>
                    repository.policy.textAllowed(section.title) &&
                    repository.policy.textAllowed(section.text),
              ));
    }
    for (final (index, chapter) in chapters.indexed) {
      if (!mounted || _error != null) return false;
      final cached = (await repository.offlineText(
        widget.book,
        chapter,
        CancellationToken(),
      )).body;
      if (cached == null ||
          !repository.policy.textAllowed(chapter.title) ||
          !repository.policy.textAllowed(cached)) {
        return false;
      }
      if (sections != null &&
          (!repository.policy.textAllowed(sections[index].title) ||
              !repository.policy.textAllowed(sections[index].text))) {
        return false;
      }
    }
    return repository.bookAllowed(widget.book);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_validated && ModalRoute.of(context)?.isCurrent == true) {
        _systemUi.apply(_style.immersive);
      }
    } else {
      _stop();
      _save();
    }
  }

  void _stop() {
    _automation.stop();
    if (_auto) setState(() => _auto = false);
  }

  void _epubProgress(int? offset, double pixels, double fraction) {
    if (!_ready) return;
    _sourceOffset = offset;
    _lastScrollOffset = pixels;
    _scrollFraction = fraction;
    if (_controls && _seeking == null) setState(() {});
    _saveTimer ??= Timer(const Duration(seconds: 3), () {
      _saveTimer = null;
      _save();
    });
  }

  void _save() {
    if (!_ready || _index >= _chapters.length) return;
    if (widget.document case final document?) {
      if (document.isAllowed()) {
        unawaited(
          document
              .savePosition((
                index: _index,
                horizontal: _horizontal,
                verticalPage: _verticalPage,
                sourceOffset: _sourceOffset,
                offset: _lastScrollOffset,
                fraction: _scrollFraction,
              ))
              .onError((_, _) {}),
        );
      }
      return;
    }
    unawaited(
      widget.repository.store
          .saveRichPosition(
            widget.book,
            _chapters[_index],
            index: _index,
            horizontal: _horizontal,
            verticalPage: _verticalPage,
            sourceOffset: _sourceOffset,
            offset: _lastScrollOffset,
            fraction: _scrollFraction,
          )
          .onError((_, _) {}),
    );
  }

  void _hideControls() {
    if (!_controls) return;
    if (_query.isNotEmpty) FocusManager.instance.primaryFocus?.unfocus();
    _searcher?.resetTextSearch();
    _searchInput.clear();
    setState(() {
      _controls = false;
      _query = '';
    });
  }

  void _toggleControls() {
    _stop();
    if (_controls) {
      _hideControls();
    } else {
      _selection = '';
      setState(() => _controls = true);
    }
  }

  void _next(int direction) {
    if (!_ready) return;
    final wasShowingResults = !_isPdf && _query.isNotEmpty;
    _hideControls();
    if (wasShowingResults) return;
    if (_isPdf) {
      final page = (_pdf.pageNumber ?? 1) + direction;
      if (page < 1 || page > _chapters.length) {
        _stop();
        return;
      }
      _pdf.goToPage(pageNumber: page);
    } else if (_vertical.currentState case final viewport?) {
      viewport.turn(direction);
    } else {
      _html.currentState?.turn(direction);
    }
  }

  void _crossSection(int direction) {
    final next = _index + direction;
    if (next < 0 || next >= _sections!.length) {
      _stop();
    } else {
      _openSection(next, fraction: direction < 0 ? 1 : 0);
    }
  }

  void _openSection(int index, {int? offset, double fraction = 0}) {
    if (!_ready) return;
    _hideControls();
    final continuous = _continuous;
    _saveTimer?.cancel();
    _saveTimer = null;
    setState(() {
      if (_index != index) {
        _index = index;
        _epubSource = EpubSource(_sections![index].html);
      }
      _vertical = GlobalKey();
      _html = GlobalKey();
      _initialVerticalPage = _verticalPage = 0;
      _lastScrollOffset = 0;
      _restoreFraction = _scrollFraction = fraction;
      _restoreSourceOffset = _sourceOffset = offset;
      _resumeOffset = null;
      _selection = '';
    });
    if (_auto && continuous != _continuous) _startAutomation();
    _save();
  }

  void _switchLayout() {
    if (!_ready || _sections?[_index].vertical != true) return;
    _stop();
    _hideControls();
    setState(() {
      _horizontal = !_horizontal;
      _restoreSourceOffset = _sourceOffset;
      _restoreFraction = _scrollFraction;
      _resumeOffset = null;
      _selection = '';
    });
    _save();
  }

  Future<void> _contents() async {
    if (!_ready) return;
    _stop();
    final destination = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: !_isPdf,
      builder: (context) => AnimatedBuilder(
        animation: Listenable.merge([
          widget.repository.policy,
          widget.repository.store.vault,
        ]),
        builder: (context, _) {
          if (!_ready || widget.document?.isAllowed() == false) {
            return const Center(child: Text('内容策略已变更'));
          }
          if (!_isPdf) {
            return EpubContentsSheet(
              titles: [for (final section in _sections!) section.title],
              current: _index,
            );
          }
          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ListView(
              children: [
                if (_outline.isEmpty)
                  const ListTile(title: Text('此 PDF 没有目录，可按页浏览')),
                ..._outlineTiles(context, _outline),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted || !_ready) return;
    if (destination is int) {
      if (destination != _index) {
        _openSection(destination);
      } else {
        _hideControls();
      }
    } else if (destination is PdfDest) {
      _hideControls();
      await _pdf.goToDest(destination);
    }
  }

  List<Widget> _outlineTiles(
    BuildContext context,
    List<PdfOutlineNode> nodes,
  ) => [
    for (final node in nodes) ...[
      ListTile(
        title: Text(node.title),
        onTap: node.dest == null
            ? null
            : () => Navigator.pop(context, node.dest),
      ),
      ..._outlineTiles(context, node.children),
    ],
  ];

  @override
  void dispose() {
    _releaseReading();
    _automation.dispose();
    _saveTimer?.cancel();
    _save();
    _searcher?.dispose();
    _searchInput.dispose();
    widget.repository.policy.removeListener(_onPolicyChanged);
    if (widget.document != null) {
      widget.repository.store.vault.removeListener(_onPolicyChanged);
    }
    WidgetsBinding.instance.removeObserver(this);
    _systemUi.restore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _style.paper.palette(Theme.of(context).colorScheme);
    final toolbar = _controls || !_ready;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.pageUp,
          includeRepeats: false,
        ): () =>
            _manualTurn(-1),
        const SingleActivator(
          LogicalKeyboardKey.pageDown,
          includeRepeats: false,
        ): () =>
            _manualTurn(1),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (_ready && !_controls) _toggleControls();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _isPdf ? null : palette.paper,
          body: ReaderSafeArea(
            preferences: _style,
            forceTop: !_ready,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!_isPdf)
                  Positioned.fill(
                    child: ReaderPaperSurface(
                      palette: palette,
                      texture: _style.texture,
                    ),
                  ),
                Builder(builder: (context) => _readerContent(context, palette)),
                if (toolbar)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _readerToolbar(),
                  ),
                if (_ready && (!_isPdf || _controls || !_style.immersive))
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Material(
                      elevation: 2,
                      child: SafeArea(
                        top: false,
                        child: _isPdf ? _footerBar() : _epubMenu(palette),
                      ),
                    ),
                  ),
                if (_isPdf && _ready && _style.immersive && !_controls)
                  _readingStatus(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _readerToolbar() => Material(
    elevation: 2,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppBar(
          title: Text(_error == null ? widget.book.title : '电子书阅读'),
          actions: [
            if (_ready && (!_isPdf || _pdfCanMark))
              IconButton(
                tooltip: '标注与关联书签',
                icon: const Icon(Icons.border_color_outlined),
                onPressed: _showMarks,
              ),
            if (_ready && widget.document != null)
              IconButton(
                tooltip: '书签与笔记',
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: _notes,
              ),
            if (_ready && _verticalLayoutAvailable)
              IconButton(
                tooltip: '切换横排／竖排',
                icon: const Icon(Icons.screen_rotation),
                onPressed: _switchLayout,
              ),
            if (_isPdf)
              IconButton(
                tooltip: '目录',
                onPressed: _ready ? _contents : null,
                icon: const Icon(Icons.list),
              ),
            if (_isPdf)
              IconButton(
                tooltip: '阅读样式',
                onPressed: _ready ? _settings : null,
                icon: const Icon(Icons.text_fields),
              ),
          ],
        ),
        if (_controls && _ready)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
            child: _searchBar(),
          ),
      ],
    ),
  );

  Widget _readerContent(BuildContext context, ReaderPalette palette) {
    if (_error case final message?) return Center(child: Text(message));
    if (!_validated) return const Center(child: CircularProgressIndicator());
    final viewport = Listener(
      onPointerDown: (_) => _stop(),
      onPointerSignal: (_) => _stop(),
      child: _isPdf
          ? _pdfView()
          : ReaderTapZones(
              horizontal: _style.mode.horizontal,
              reverse: _verticalLayout && _style.mode.horizontal,
              tapRevision: () => _epubLinkRevision,
              selectionActive: () => _selection.isNotEmpty,
              onTurn: _manualTurn,
              onMenu: _toggleControls,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 48,
                ),
                child: _epub(palette),
              ),
            ),
    );
    if (_isPdf || !_controls || _query.isEmpty) {
      return Stack(fit: StackFit.expand, children: [viewport]);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        viewport,
        ColoredBox(
          color: palette.paper,
          child: Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + kToolbarHeight + 64,
              bottom: MediaQuery.paddingOf(context).bottom + 100,
            ),
            child: _searchResults(_sections!),
          ),
        ),
      ],
    );
  }

  void _manualTurn(int direction) {
    _stop();
    _next(direction);
  }

  Widget _navigationButton(int direction, {bool tonal = false}) {
    final label = _isPdf
        ? (direction < 0 ? '上一页' : '下一页')
        : (direction < 0 ? '上一章' : '下一章');
    final icon = Icon(
      _isPdf
          ? (direction < 0 ? Icons.chevron_left : Icons.chevron_right)
          : (direction < 0
                ? Icons.skip_previous_outlined
                : Icons.skip_next_outlined),
    );
    final target = _index + direction;
    final action = !_ready || target < 0 || target >= _chapters.length
        ? null
        : () {
            if (_isPdf) {
              _manualTurn(direction);
            } else {
              _stop();
              _openSection(target);
            }
          };
    return tonal
        ? IconButton.filledTonal(tooltip: label, icon: icon, onPressed: action)
        : IconButton(tooltip: label, icon: icon, onPressed: action);
  }

  Widget _readingStatus() => Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _navigationButton(-1, tonal: true),
            _pageLabel(),
            IconButton.filledTonal(
              tooltip: _auto ? '停止自动阅读' : '阅读菜单',
              icon: Icon(_auto ? Icons.pause : Icons.more_horiz),
              onPressed: _auto ? _stop : _toggleControls,
            ),
            _navigationButton(1, tonal: true),
          ],
        ),
      ),
    ),
  );

  Widget _pageLabel() => Material(
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainer.withValues(alpha: .86),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text('${_index + 1} / ${_chapters.length}'),
    ),
  );

  Future<void> _settings() async {
    final wasRunning = _auto;
    final wasEnabled = _style.autoEnabled;
    _configuring = true;
    _stop();
    if (_isPdf ||
        await showReaderQuickStyle(context, _style, _applyStyle) == true) {
      if (mounted && _ready) {
        await showReaderSettings(
          context,
          _style,
          _applyStyle,
          fontStore: widget.repository.readerFonts,
          rich: true,
          pdf: _isPdf,
        );
      }
    }
    _configuring = false;
    if (mounted && _ready) {
      if (_style.autoEnabled && (wasRunning || !wasEnabled)) _startAutomation();
      try {
        await widget.repository.store.write(
          'books_reader_preferences',
          _style.toJson(),
        );
      } on Exception {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('阅读设置保存失败，请重试')));
        }
      }
    }
  }

  Widget _pdfView() => PdfViewer.file(
    widget.file.path,
    controller: _pdf,
    passwordProvider: widget.document?.password == null ? null : _pdfPassword,
    initialPageNumber: _index + 1,
    params: PdfViewerParams(
      onDocumentLoadFinished: (_, succeeded) {
        if (mounted && !succeeded && _error == null) {
          setState(() => _error = '无法打开 PDF，文件可能损坏');
        }
      },
      onViewerReady: _pdfReady,
      onGeneralTap: (context, controller, details) {
        if (!_ready ||
            details.type != PdfViewerGeneralTapType.tap ||
            details.tapOn == PdfViewerPart.selectedText) {
          return false;
        }
        _toggleControls();
        return false;
      },
      onPageChanged: (page) {
        if (mounted && _ready && page != null) {
          setState(() => _index = page - 1);
          if (_query.isEmpty) _hideControls();
          _save();
        }
      },
      pagePaintCallbacks: [
        if (_searcher != null) _searcher!.pageTextMatchPaintCallback,
        if (_pdfCanMark) _pdfMarks.paint,
      ],
      customizeContextMenuItems: _pdfSelectionMenu,
      linkHandlerParams: PdfLinkHandlerParams(onLinkTap: (link) {}),
    ),
  );

  bool _passwordTried = false;
  String? _pdfPassword() {
    if (_passwordTried || widget.document?.isAllowed() != true) return null;
    _passwordTried = true;
    return widget.document?.password;
  }

  Future<void> _pdfReady(
    PdfDocument document,
    PdfViewerController controller,
  ) async {
    if (!mounted || _error != null) return;
    if (document.pages.length != _chapters.length) {
      setState(() => _error = 'PDF 页数与已导入目录不一致');
      return;
    }
    setState(() {
      final access = widget.document;
      _searcher ??= access == null
          ? LegacyPdfReaderSearch(controller)
          : PublicationPdfSearch(controller, access.isAllowed);
      _index = (controller.pageNumber ?? _index + 1) - 1;
      _pdfCanMark = document.permissions?.allowsCopying != false;
    });
    _save();
    if (_style.autoEnabled && !_auto) _startAutomation();
    if (_pdfCanMark) unawaited(_refreshMarks());
    try {
      final outline = await document.loadOutline();
      if (mounted && _ready) setState(() => _outline = outline);
    } on Exception {
      // Page navigation and search are available without an outline.
    }
  }

  Widget _searchBar() => Row(
    children: [
      Expanded(
        child: _isPdf && widget.document?.searchable == false
            ? const Text('本文件没有可搜索文字')
            : TextField(
                controller: _searchInput,
                decoration: const InputDecoration(labelText: '全文搜索'),
                onChanged: (q) {
                  final query = q.trim();
                  setState(() {
                    if (_query.isEmpty && query.isNotEmpty && !_isPdf) {
                      _resumeOffset ??= _lastScrollOffset;
                    }
                    _query = query;
                  });
                  if (query.isEmpty) {
                    _searcher?.resetTextSearch();
                  } else {
                    _searcher?.startTextSearch(query);
                  }
                },
              ),
      ),
      if (_isPdf && _searcher != null) ...[
        ListenableBuilder(
          listenable: _searcher!,
          builder: (_, _) {
            if (widget.document?.searchable == false) {
              return const SizedBox.shrink();
            }
            final search = _searcher!;
            final count = search.matchCount;
            final publication = search is PublicationPdfSearch ? search : null;
            final paused = publication?.isPaused == true;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  paused
                      ? '已暂停 · $count'
                      : search.isSearching
                      ? '检索中 · $count'
                      : '$count 项',
                ),
                if (publication != null && (search.isSearching || paused))
                  IconButton(
                    tooltip: paused ? '继续检索' : '暂停检索',
                    onPressed: publication.togglePause,
                    icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  ),
              ],
            );
          },
        ),
        IconButton(
          tooltip: '下个结果',
          onPressed: widget.document?.searchable == false
              ? null
              : _searcher!.goToNextMatch,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: '放大',
          onPressed: () => _pdf.zoomUp(),
          icon: const Icon(Icons.zoom_in),
        ),
        IconButton(
          tooltip: '缩小',
          onPressed: () => _pdf.zoomDown(),
          icon: const Icon(Icons.zoom_out),
        ),
      ],
    ],
  );

  Widget _footerBar() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      _navigationButton(-1),
      Text('${_index + 1} / ${_chapters.length}'),
      IconButton(
        tooltip: '阅读菜单',
        onPressed: _toggleControls,
        icon: const Icon(Icons.more_horiz),
      ),
      _navigationButton(1),
    ],
  );

  void _applyStyle(ReaderPreferences settings) {
    if (!mounted || !_ready) return;
    if (settings.immersive != _style.immersive) {
      _systemUi.apply(settings.immersive);
    }
    setState(() {
      _style = settings;
      if (!_isPdf) {
        _restoreSourceOffset = _sourceOffset;
        _restoreFraction = _scrollFraction;
        _resumeOffset = null;
      }
    });
  }

  Widget _epubMenu(ReaderPalette palette) {
    final position = _seeking ?? _scrollFraction;
    return Material(
      color: palette.paper,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: _controls
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 16),
                        Text('${_index + 1}/${_chapters.length} 章'),
                        Expanded(
                          child: Slider(
                            value: position,
                            activeColor: palette.accent,
                            onChanged: (value) =>
                                setState(() => _seeking = value),
                            onChangeEnd: (value) {
                              _seeking = null;
                              _openSection(_index, fraction: value);
                            },
                          ),
                        ),
                        Text('${(position * 100).round()}%'),
                        const SizedBox(width: 16),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _navigationButton(-1),
                        IconButton(
                          tooltip: '章节目录',
                          icon: const Icon(Icons.list_alt_outlined),
                          onPressed: _contents,
                        ),
                        IconButton(
                          tooltip: '阅读样式',
                          icon: const Icon(Icons.format_size_outlined),
                          onPressed: _settings,
                        ),
                        IconButton(
                          tooltip: '收起阅读菜单',
                          icon: const Icon(Icons.expand_more),
                          onPressed: _hideControls,
                        ),
                        _navigationButton(1),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 15),
                        child: Text(
                          _style.status
                              ? '${_index + 1}/${_chapters.length} 章'
                              : '',
                          style: TextStyle(fontSize: 12, color: palette.ink),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _auto ? '停止自动阅读' : '阅读菜单',
                      icon: Icon(
                        _auto ? Icons.pause_circle_outline : Icons.more_horiz,
                      ),
                      color: palette.ink,
                      onPressed: _auto ? _stop : _toggleControls,
                    ),
                    const Spacer(),
                  ],
                ),
        ),
      ),
    );
  }

  int _textBoundary(String text, int offset) {
    if (offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xDC00 &&
        text.codeUnitAt(offset) <= 0xDFFF &&
        text.codeUnitAt(offset - 1) >= 0xD800 &&
        text.codeUnitAt(offset - 1) <= 0xDBFF) {
      return offset - 1;
    }
    return offset;
  }

  Widget _searchResults(List<RichSection> sections) {
    final pattern = RegExp(
      RegExp.escape(_query),
      caseSensitive: false,
      unicode: true,
    );
    final matches = [
      for (final (index, section) in sections.indexed)
        if (pattern.firstMatch(section.text) case final match?) (index, match),
    ];
    if (matches.isEmpty) return const Center(child: Text('没有匹配的章节'));
    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (_, i) {
        final (index, match) = matches[i];
        final section = sections[index];
        return ListTile(
          title: Text(section.title),
          subtitle: Text(
            section.text.substring(
              _textBoundary(
                section.text,
                (match.start - 40).clamp(0, section.text.length),
              ),
              _textBoundary(
                section.text,
                (match.end + 100).clamp(0, section.text.length),
              ),
            ),
          ),
          onTap: () => _openSection(index),
        );
      },
    );
  }

  bool get _verticalLayoutAvailable => _sections?[_index].vertical == true;

  Widget _epub(ReaderPalette palette) {
    final source = _epubSource;
    if (source == null) return const Center(child: CircularProgressIndicator());
    if (_verticalLayout) {
      return Padding(
        padding: EdgeInsets.fromLTRB(_style.margin, 8, _style.margin, 22),
        child: VerticalBookText(
          key: _vertical,
          text: source.text,
          html: source.htmlContent,
          initialPage: _initialVerticalPage,
          sourceOffset: _restoreSourceOffset,
          marks: _visibleMarks(source),
          selectionMenu: _epubSelectionMenu,
          onSelectionChanged: (value) => _selection = value,
          initialFraction: _restoreFraction,
          mode: _style.mode,
          animate: _style.animate,
          palette: palette,
          onProgress: (page, offset, fraction) {
            _verticalPage = page;
            _epubProgress(offset, 0, fraction);
          },
          style: _style.bodyStyle.copyWith(color: palette.ink),
          onBoundary: _crossSection,
          onTapUrl: _epubLink,
        ),
      );
    }
    return EpubHtmlViewport(
      key: _html,
      source: source,
      marks: _visibleMarks(source),
      preferences: _style,
      palette: palette,
      sourceOffset: _restoreSourceOffset,
      legacyPixels: _resumeOffset,
      initialFraction: _restoreFraction,
      onProgress: _epubProgress,
      onBoundary: _crossSection,
      onSelectionChanged: (value) => _selection = value,
      selectionMenu: _epubSelectionMenu,
      onLink: _epubLink,
    );
  }

  bool _epubLink(String url) {
    if (!_ready || widget.document?.isAllowed() == false) return true;
    final link = Uri.tryParse(url);
    if (link == null) return true;
    final index = url.startsWith('#')
        ? _index
        : link.scheme == 'epub-section'
        ? int.tryParse(link.path)
        : null;
    if (index == null || index < 0 || index >= _chapters.length) return true;
    final source = index == _index
        ? _epubSource!
        : EpubSource(_sections![index].html);
    final target = link.hasFragment ? source.destinations[link.fragment] : 0;
    if (target != null) {
      _epubLinkRevision++;
      _openSection(index, offset: target);
    }
    return true;
  }

  bool _markAllowed() =>
      _ready &&
      (!_isPdf || _pdfCanMark) &&
      widget.repository.bookAllowed(widget.book) &&
      widget.document?.isAllowed() != false &&
      (!widget.repository.store.vault.isPrivate(widget.book.id) ||
          widget.repository.store.vault.unlocked);

  List<ReadingMark> _visibleMarks(EpubSource source) => [
    for (final mark in _marks)
      if (mark.section == _index && mark.matches(source.text)) mark,
  ];

  Future<void> _refreshMarks() async {
    if (!_markAllowed()) return;
    try {
      final marks = await _markStore.load(digest: widget.book.uri.path);
      if (mounted && _markAllowed()) {
        setState(
          () => _marks = [
            for (final mark in marks)
              if (widget.repository.policy.textAllowed(mark.quote)) mark,
          ],
        );
      }
      if (mounted && _markAllowed() && _isPdf) {
        _pdfMarks.marks = _marks;
        _pdf.invalidate();
      }
    } on Exception {
      if (mounted) _markError();
    }
  }

  void _markError() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('无法读取或保存标注')));

  ReadingMark? _selectedMark() {
    if (!_markAllowed() || _selection.isEmpty) return null;
    final range =
        _html.currentState?.selectedRange ??
        _vertical.currentState?.selectedRange;
    final source = _epubSource?.text;
    if (source == null ||
        range == null ||
        range.end > source.length ||
        range.end - range.start > 1200) {
      return null;
    }
    final quote = source.substring(range.start, range.end);
    final whitespace = RegExp(r'\s+');
    if (quote.replaceAll(whitespace, '') !=
        _selection.replaceAll(whitespace, '')) {
      return null;
    }
    final draft = ReadingMark(
      digest: widget.book.uri.path,
      section: _index,
      range: range,
      quote: quote,
    );
    return _marks
            .where((item) => item.identity == draft.identity)
            .firstOrNull ??
        draft;
  }

  Listenable get _markPolicy => Listenable.merge([
    widget.repository.policy,
    widget.repository.store.vault,
  ]);

  Future<void> _editMark(ReadingMark initial) async {
    try {
      final mark = await editReadingMark(
        context,
        initial,
        policy: _markPolicy,
        allowed: _markAllowed,
      );
      if (!mounted || mark == null || !_markAllowed()) return;
      await _markStore.save(mark);
      if (mounted) await _refreshMarks();
    } on Exception {
      if (mounted) _markError();
    }
  }

  Future<void> _showMarks() async {
    if (!_markAllowed()) return;
    _stop();
    final mark = await showReadingMarks(
      context,
      initial: _marks,
      save: _markStore.save,
      delete: _markStore.delete,
      location: (mark) => mark.section < _chapters.length
          ? _chapters[mark.section].title
          : '章节不可用',
      policy: _markPolicy,
      allowed: _markAllowed,
    );
    if (!mounted || !_markAllowed()) return;
    await _refreshMarks();
    if (!mounted ||
        !_markAllowed() ||
        mark == null ||
        mark.section >= _chapters.length) {
      return;
    }
    if (_isPdf) {
      await _pdfMarks.jump(mark);
      return;
    }
    final source = mark.section == _index
        ? _epubSource!
        : EpubSource(_sections![mark.section].html);
    if (mark.matches(source.text)) {
      _openSection(mark.section, offset: mark.range.start);
    }
  }

  Widget _epubSelectionMenu(
    BuildContext context,
    SelectableRegionState region,
  ) {
    final mark = _selectedMark();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        if (mark != null)
          ContextMenuButtonItem(
            label: '添加标注',
            onPressed: () {
              region.clearSelection();
              region.hideToolbar();
              unawaited(_editMark(mark));
            },
          ),
        if (_selection.isNotEmpty && widget.document?.isAllowed() == true)
          ContextMenuButtonItem(
            label: '添加摘录',
            onPressed: () {
              final excerpt = _selection;
              region.clearSelection();
              region.hideToolbar();
              if (excerpt.isNotEmpty) unawaited(_notes(excerpt: excerpt));
            },
          ),
        ...region.contextMenuButtonItems,
      ],
    );
  }

  void _pdfSelectionMenu(
    PdfViewerContextMenuBuilderParams params,
    List<ContextMenuButtonItem> items,
  ) {
    final selection = params.textSelectionDelegate;
    if (!_markAllowed() ||
        !selection.isCopyAllowed ||
        !selection.hasSelectedText ||
        selection.isSelectingAllText) {
      return;
    }
    final a = params.a;
    final b = params.b;
    if (a != null && b != null && a.page.pageNumber == b.page.pageNumber) {
      final range = a.page.getRangeFromAB(a.index, b.index);
      if (range.text.isNotEmpty && range.text.length <= 1200) {
        items.insert(
          0,
          ContextMenuButtonItem(
            label: '添加标注',
            onPressed: () async {
              if (!_markAllowed()) return;
              final draft = ReadingMark(
                digest: widget.book.uri.path,
                section: range.pageNumber - 1,
                range: (start: range.start, end: range.end),
                quote: range.text,
              );
              await selection.clearTextSelection();
              if (!mounted || !_markAllowed()) return;
              await _editMark(
                _marks
                        .where((item) => item.identity == draft.identity)
                        .firstOrNull ??
                    draft,
              );
            },
          ),
        );
      }
    }
    if (widget.document == null) return;
    final index = (params.a?.page.pageNumber ?? _index + 1) - 1;
    items.insert(
      0,
      ContextMenuButtonItem(
        label: '添加摘录',
        onPressed: () async {
          if (!_ready || widget.document?.isAllowed() != true) return;
          final excerpt = await selection.getSelectedText();
          if (!mounted || !_ready || excerpt.isEmpty) return;
          await selection.clearTextSelection();
          if (mounted) await _notes(excerpt: excerpt, selectionIndex: index);
        },
      ),
    );
  }

  Future<void> _notes({String excerpt = '', int? selectionIndex}) async {
    final document = widget.document;
    if (!_ready ||
        document == null ||
        !document.isAllowed() ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _stop();
    final note = await showRichDocumentNotes(
      context,
      document,
      selectionIndex ?? _index,
      _scrollFraction,
      excerpt,
      pdf: _isPdf,
      policy: Listenable.merge([
        widget.repository.policy,
        widget.repository.store.vault,
      ]),
    );
    if (!mounted ||
        note == null ||
        !_ready ||
        !document.isAllowed() ||
        note.index < 0 ||
        note.index >= _chapters.length) {
      return;
    }
    if (_isPdf) {
      await _pdf.goToPage(pageNumber: note.index + 1);
      return;
    }
    _openSection(note.index, fraction: note.fraction);
  }
}
