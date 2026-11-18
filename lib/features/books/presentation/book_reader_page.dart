import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/request_scheduler.dart';
import '../../../core/network/document_client.dart';
import '../../../core/platform/platform_services.dart';
import '../../../core/platform/foreground_workload.dart';
import '../application/reader_preloader.dart';
import 'reader_cleanup_sheet.dart';
import '../data/books_repository.dart';
import '../data/book_chapter_policy.dart';
import '../../supervision/domain/supervision_rules.dart';
import 'book_text_policy_dialog.dart';
import '../data/book_mixed_content.dart';
import '../domain/book.dart';
import 'reader_pagination.dart';
import 'reader_automation.dart';
import 'reader_style.dart';
import 'reader_system_ui.dart';
import 'reader_safe_area.dart';
import 'book_image_chapter.dart';

part 'reader_tools.dart';
part 'reader_session.dart';

final class BookReaderPage extends StatefulWidget {
  const BookReaderPage({
    super.key,
    required this.repository,
    required this.book,
    required this.chapters,
    required this.initial,
    this.platform,
  });
  final BooksRepository repository;
  final Book book;
  final List<BookChapter> chapters;
  final BookChapter initial;
  final PlatformServices? platform;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

final class _BookReaderPageState extends State<BookReaderPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late BookChapter _chapter = widget.initial;
  late List<BookChapter> _chapters = widget.chapters;
  late final _systemUi = ReaderSystemUi(widget.platform);
  GlobalKey<ReaderViewportState> _viewport = GlobalKey();
  GlobalKey<BookImageChapterState> _imageViewport = GlobalKey();
  final _paperFocus = FocusNode(debugLabel: '阅读正文');
  final _contentsFocus = FocusNode(debugLabel: '章节目录');
  final _progress = ValueNotifier<ReaderProgress>(readerProgress(0));
  CancellationToken? _token;
  CancellationToken? _endToken;
  Timer? _saveTimer, _clock;
  final _minute = ValueNotifier<DateTime>(DateTime.now());
  late final _releaseReading = ForegroundWorkload.instance.beginReading();
  late final _preloader = ReaderPreloader((chapter, token) async {
    await withRequestPriority(
      RequestPriority.background,
      () => _books.readText(widget.book, chapter, token),
    );
  });
  bool _foreground = true;
  String? _lastSavedChapter;
  ReaderProgress? _lastSavedProgress;
  late final _automation = ReaderAutomation(this, _advanceAutomatically);
  bool _autoRunning = false;
  bool _preferencesLoaded = false;
  bool _configuring = false;
  ReaderPreferences _style = const ReaderPreferences();
  ReaderProgress? _retryPosition;
  TextRange? _highlight;
  String _sourceStatus = '', _selection = '', _text = '';
  List<Uri> _images = const [];
  List<BookChapterSegment>? _mixedSegments;
  Book? _imageBook;
  BookChapter? _imageSourceChapter;
  String _chapterQuery = '', _findQuery = '';
  bool _reverse = false, _controls = false, _loading = true;
  bool _checkingEnd = false;
  String? _error;
  ChapterContentBlocked? _blockedChapter;
  double? _seeking;

  BooksRepository get _books => widget.repository;
  int get _index => _chapters.indexOf(_chapter);
  bool get _ready =>
      !_loading && _error == null && (_text.isNotEmpty || _images.isNotEmpty);

  void _changeAutomation(bool running) => setState(() {
    _autoRunning = running;
    if (running) _controls = false;
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _releaseReading;
    _books.readingCleanup.addListener(_policyChanged);
    _books.policy.addListener(_policyChanged);
    _books.sourceRiskChanges.addListener(_policyChanged);
    unawaited(_start());
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncClock();
    if (_foreground) {
      _schedulePreload();
      if (_preferencesLoaded && ModalRoute.of(context)?.isCurrent == true) {
        _systemUi.apply(_style.immersive);
      }
    } else {
      _preloader.cancel();
      _stopAutomation();
      _saveTimer?.cancel();
      _saveTimer = null;
      _savePosition();
    }
  }

  Future<void> _start() async {
    try {
      await _books.readingCleanup.load();
      final data = await _books.store.read('books_reader_preferences');
      if (data is Map && mounted) {
        var style = ReaderPreferences.fromJson(data);
        if (!await _books.readerFonts.ensure(style.family)) {
          style = style.copyWith(family: 'system');
        }
        if (mounted) setState(() => _style = style);
      }
    } on Exception {
      // A damaged preference record can be replaced in the style panel.
    }
    if (mounted) {
      _preferencesLoaded = true;
      _syncClock();
      _systemUi.apply(_style.immersive);
    }
    if (mounted && _token == null) {
      await _open(widget.initial, resume: true);
      if (mounted && _style.autoEnabled) _startAutomation();
    }
  }

  void _policyChanged() {
    _stopAutomation();
    _token?.cancel();
    _endToken?.cancel();
    if (mounted) {
      unawaited(
        _open(
          _chapter,
          resume: true,
          location: _ready ? _progress.value : _retryPosition,
        ),
      );
    }
  }

  void _moved(ReaderProgress progress) {
    if (!_ready) return;
    if (_controls && progress.offset != _progress.value.offset) {
      setState(() => _controls = false);
    }
    _progress.value = progress;
    _saveTimer ??= Timer(const Duration(seconds: 3), () {
      _saveTimer = null;
      _savePosition();
    });
  }

  void _savePosition() {
    if (!_ready) return;
    final progress = _progress.value;
    if (_lastSavedChapter == _chapter.id &&
        _lastSavedProgress?.offset == progress.offset &&
        _lastSavedProgress?.fraction == progress.fraction) {
      return;
    }
    _lastSavedChapter = _chapter.id;
    _lastSavedProgress = progress;
    unawaited(
      _books.store
          .saveReadingPosition(
            widget.book,
            _chapter,
            progress.fraction,
            progress.offset,
          )
          .onError((_, _) {
            _lastSavedChapter = null;
          }),
    );
  }

  Future<void> _open(
    BookChapter chapter, {
    bool resume = false,
    ReaderProgress? location,
  }) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _savePosition();
    _preloader.cancel();
    _token?.cancel();
    final token = _token = CancellationToken();
    _retryPosition = location;
    setState(() {
      _chapter = chapter;
      _viewport = GlobalKey();
      _imageViewport = GlobalKey();
      _loading = true;
      _error = null;
      _blockedChapter = null;
      _text = _selection = _sourceStatus = '';
      _images = const [];
      _mixedSegments = null;
      _imageBook = null;
      _imageSourceChapter = null;
      _controls = false;
      _highlight = null;
      _seeking = null;
    });
    _progress.value = readerProgress(0);
    try {
      final saved = resume && location == null
          ? await _books.store.entry(widget.book)
          : null;
      token.check();
      final restored =
          location ??
          (saved?.last == chapter.id
              ? readerProgress(
                  saved!.position.clamp(0.0, 1.0),
                  offset: saved.textOffset,
                )
              : readerProgress(0));
      _progress.value = restored;
      if (widget.book.kind == BookKind.comic) {
        if (!await _loadImageChapter(chapter, token)) {
          _fail(token, '章节没有可阅读的图片');
        }
        return;
      }
      await _loadTextChapter(chapter, token, restored);
    } on ChapterContentBlocked catch (error) {
      if (mounted && identical(_token, token) && !token.isCancelled) {
        _blockedChapter = error;
        _fail(token, error.message);
      }
    } on ContentBlocked catch (error) {
      _fail(token, error.message);
    } on FormatException catch (error) {
      if (widget.book.kind == BookKind.comic) {
        _fail(token, error.message);
        return;
      }
      try {
        if (!await _loadImageChapter(chapter, token)) {
          _fail(token, error.message);
        }
      } on Exception {
        _fail(token, error.message);
      }
    } on RemoteFailure catch (error) {
      if (widget.book.kind != BookKind.comic &&
          error.kind == FailureKind.invalid &&
          error.message.contains('大小限制')) {
        try {
          if (!await _loadImageChapter(chapter, token)) {
            _fail(token, error.message);
          }
        } on Exception {
          _fail(token, error.message);
        }
      } else {
        _fail(token, error.message);
      }
    } on Exception {
      _fail(token, '无法打开正文或内容受限');
    }
  }

  Future<void> _loadTextChapter(
    BookChapter chapter,
    CancellationToken token,
    ReaderProgress restored,
  ) async {
    final result = await _books.readWithFallback(
      widget.book,
      chapter,
      token,
      automatic: _style.automatic,
    );
    if (!mounted || token.isCancelled) return;
    final images = result.text.trimLeft().startsWith('[')
        ? await _books.imageAddressesInText(
            result.sourceBook,
            result.sourceChapter,
            result.text,
            token,
          )
        : const <Uri>[];
    var mixed = <BookChapterSegment>[];
    if (images.isEmpty) {
      try {
        mixed = await _books.mixedReading(
          result.sourceBook,
          result.sourceChapter,
          token,
        );
      } on Exception {
        token.check();
        // Reviewed text remains readable when optional media is unavailable.
      }
    }
    if (!mounted || token.isCancelled) return;
    final body = _cleanText(
      result.sourceBook,
      result.sourceChapter,
      result.text,
    );
    mixed = [
      for (final part in mixed)
        if (part is BookTextSegment)
          BookTextSegment(
            _cleanText(result.sourceBook, result.sourceChapter, part.text),
          )
        else
          part,
    ];
    setState(() {
      if (mixed.isNotEmpty) {
        _mixedSegments = mixed;
        _images = mixed
            .whereType<BookImageSegment>()
            .map((part) => part.address)
            .toList();
        _imageBook = result.sourceBook;
        _imageSourceChapter = result.sourceChapter;
      } else if (images.isEmpty) {
        _text = _chapterText(chapter.title, body);
      } else {
        _images = images;
        _imageBook = result.sourceBook;
        _imageSourceChapter = result.sourceChapter;
      }
      _sourceStatus = result.sourceBook.id == widget.book.id
          ? ''
          : '已换源 · ${result.sourceBook.uri.host}';
      _loading = false;
    });
    _schedulePreload();
    unawaited(
      _books.store
          .saveBook(
            widget.book,
            chapters: widget.book.sourceId == 'local' ? null : _chapters,
            preserveCatalog: true,
            last: chapter,
            position: restored.fraction,
            textOffset: restored.offset,
          )
          .onError((_, _) {}),
    );
  }

  Future<bool> _loadImageChapter(
    BookChapter chapter,
    CancellationToken token,
  ) async {
    final images = await _books.chapterImages(widget.book, chapter, token);
    if (!mounted || token.isCancelled) return true;
    if (images.isEmpty) return false;
    setState(() {
      _images = images;
      _imageBook = widget.book;
      _imageSourceChapter = chapter;
      _loading = false;
    });
    unawaited(
      _books.store
          .saveBook(
            widget.book,
            chapters: _chapters,
            preserveCatalog: true,
            last: chapter,
            position: _progress.value.fraction,
          )
          .onError((_, _) {}),
    );
    return true;
  }

  void _fail(CancellationToken token, String message) {
    if (mounted && !token.isCancelled) {
      _stopAutomation();
      setState(() {
        _loading = false;
        _error = message;
      });
    }
  }

  bool _canCross(int direction) {
    final index = _index + direction;
    return _ready &&
        index >= 0 &&
        index < _chapters.length &&
        _books.policy.textAllowed(_chapters[index].title);
  }

  void _cross(int direction, {bool lastPage = true}) {
    if (_canCross(direction)) {
      unawaited(
        _open(
          _chapters[_index + direction],
          location: readerProgress(direction < 0 && lastPage ? 1 : 0),
        ),
      );
    } else if (direction > 0 &&
        _ready &&
        !_checkingEnd &&
        _index == _chapters.length - 1 &&
        widget.book.sourceId != 'local') {
      unawaited(_checkEnd());
    }
  }

  Future<void> _checkEnd() async {
    _checkingEnd = true;
    try {
      final check = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('已读到当前最后一章'),
          content: const Text('检测当前渠道更新及其他渠道的最新章节？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('检测更新'),
            ),
          ],
        ),
      );
      if (check != true || !mounted) return;
      final token = _endToken = CancellationToken();
      final current = _chapters.length;
      List<BookChapter>? fresh;
      List<BookEdition> editions = [];
      try {
        fresh = await _books.chapters(widget.book, token, refresh: true);
        if (fresh.length > current && mounted) {
          final currentChapter = fresh
              .where((item) => item.id == _chapter.id)
              .firstOrNull;
          if (currentChapter != null) {
            setState(() {
              _chapters = fresh!;
              _chapter = currentChapter;
            });
            await _books.store.saveBook(
              widget.book,
              chapters: fresh,
              preserveCatalog: true,
            );
          }
        }
      } on Exception {
        // Other channels may still be available.
      }
      try {
        editions = await _books.alternatives(widget.book, token);
      } on Exception {
        // The current channel's result is still useful.
      }
      if (!mounted || !_books.bookAllowed(widget.book)) return;
      final newer = editions.where((edition) {
        final match = _books.matchingChapter(edition.chapters, _chapter);
        return match != null &&
            edition.chapters.indexOf(match) < edition.chapters.length - 1;
      }).toList();
      final message = _chapters.length > current
          ? '当前渠道新增 ${_chapters.length - current} 章，可继续翻页。'
          : newer.isNotEmpty
          ? '其他渠道发现 ${newer.length} 个可能有更新的版本，请在详情页换源查看。'
          : fresh == null && editions.isEmpty
          ? '检测失败，请稍后重试。'
          : '暂未发现新章节。';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      _endToken = null;
      _checkingEnd = false;
    }
  }

  void _page(int direction) {
    _stopAutomation();
    if (_controls) {
      setState(() => _controls = false);
      _paperFocus.requestFocus();
    }
    if (_images.isNotEmpty) {
      _imageViewport.currentState?.turn(direction);
    } else if (_ready) {
      _viewport.currentState?.turn(direction);
    }
  }

  void _toggleControls() {
    _stopAutomation();
    setState(() => _controls = !_controls);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (_controls ? _contentsFocus : _paperFocus).requestFocus();
    });
  }

  void _showMatch(TextRange match) {
    setState(() {
      _highlight = match;
      _controls = false;
    });
    _viewport.currentState?.jumpToOffset(match.start);
    _paperFocus.requestFocus();
  }

  void _readerNotice(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, _controls ? 110 : 54),
      ),
    );
  }

  KeyEventResult _readingKey(FocusNode node, KeyEvent event) {
    if (_controls || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent) _toggleControls();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.space) {
      _page(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _page(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _settings() => _editStyle(_fullSettings);

  Future<void> _fullSettings() => showReaderSettings(
    context,
    _style,
    _applyStyle,
    fontStore: _books.readerFonts,
    onCleanupRules: () => showReadingCleanupRules(context, _books, widget.book),
    onClearCache: () async {
      _preloader.cancel();
      try {
        await _books.store.clearReadingCache(widget.book);
        if (mounted) _readerNotice('本书临时阅读缓存已清除，离线下载保留');
      } on Exception {
        if (mounted) _readerNotice('清除缓存失败，请重试');
      }
    },
  );

  Future<void> _cleanupSelection() async {
    _stopAutomation();
    try {
      await editReadingCleanup(
        context,
        _books,
        widget.book,
        selected: _selection,
        body: _text,
      );
    } on Exception {
      if (mounted) _readerNotice('无法打开阅读净化规则');
    }
  }

  String _cleanText(Book book, BookChapter chapter, String original) {
    final cleaned = _books.readingCleanup.apply(widget.book, original);
    // The original has already passed readWithFallback; check the result too.
    if (cleaned == original) return original;
    return _books.chapterPolicy.checkPrepared(book, chapter, cleaned);
  }

  void _schedulePreload() {
    _preloader.cancel();
    if (!_ready ||
        !_foreground ||
        _style.preloadChapters == 0 ||
        widget.book.sourceId == 'local' ||
        _images.isNotEmpty ||
        _index < 0) {
      return;
    }
    final next = _chapters
        .skip(_index + 1)
        .take(_style.preloadChapters)
        .toList();
    _preloader.schedule(
      next,
      allowed: () async =>
          !_style.preloadUnmeteredOnly ||
          !(await (widget.platform?.isMetered() ??
              (defaultTargetPlatform == TargetPlatform.android
                  ? PlatformServices.queryMeteredConnection()
                  : Future.value(false)))),
    );
  }

  void _syncClock() {
    _clock?.cancel();
    _clock = null;
    if (!_foreground || !_style.status) return;
    _minute.value = DateTime.now();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      _minute.value = DateTime.now();
    });
  }

  /// Shared by the full style sheet and the compact phone sheet.
  void _applyStyle(ReaderPreferences settings) {
    if (!mounted) return;
    final previous = _style;
    if (previous.immersive != settings.immersive) {
      _systemUi.apply(settings.immersive);
    }
    setState(() => _style = settings);
    if (previous.status != settings.status) _syncClock();
    if (previous.preloadChapters != settings.preloadChapters ||
        previous.preloadUnmeteredOnly != settings.preloadUnmeteredOnly) {
      _schedulePreload();
    }
    if (!settings.autoEnabled) {
      _stopAutomation();
    } else if (!previous.autoEnabled ||
        previous.mode != settings.mode ||
        previous.autoSeconds != settings.autoSeconds) {
      if (!_configuring) _startAutomation();
    }
  }

  Future<void> _quickStyle() => _editStyle(() async {
    final more = await showReaderQuickStyle(context, _style, _applyStyle);
    if (mounted && more == true) {
      await _fullSettings();
    }
  });

  /// Opens a style sheet and persists the result once it closes; both sheets
  /// write the same preference record.
  Future<void> _editStyle(Future<void> Function() open) async {
    final wasRunning = _autoRunning;
    final wasEnabled = _style.autoEnabled;
    _configuring = true;
    _stopAutomation();
    try {
      await open();
    } finally {
      _configuring = false;
    }
    if (!mounted) return;
    if (_style.autoEnabled && _foreground && (wasRunning || !wasEnabled)) {
      _startAutomation();
    }
    try {
      await _books.store.write('books_reader_preferences', _style.toJson());
    } on Exception {
      if (mounted) _readerNotice('阅读设置保存失败，请重试');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _automation.dispose();
    _systemUi.restore();
    _saveTimer?.cancel();
    _clock?.cancel();
    _minute.dispose();
    _preloader.dispose();
    _releaseReading();
    _books.readingCleanup.removeListener(_policyChanged);
    _savePosition();
    _token?.cancel();
    _endToken?.cancel();
    _books.policy.removeListener(_policyChanged);
    _books.sourceRiskChanges.removeListener(_policyChanged);
    _paperFocus.dispose();
    _contentsFocus.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _style.paper.palette(Theme.of(context).colorScheme);
    final readerTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: palette.brightness,
        surface: palette.paper,
      ),
    );
    return Theme(
      data: readerTheme,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
              _skipChapter(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
              _skipChapter(1),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _showFind,
        },
        child: Scaffold(
          backgroundColor: palette.paper,
          body: _readerBody(palette),
        ),
      ),
    );
  }

  Widget _readerBody(ReaderPalette palette) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: ReaderPaperSurface(palette: palette, texture: _style.texture),
      ),
      ReaderSafeArea(
        preferences: _style,
        child: Listener(
          onPointerDown: (_) => _stopAutomation(),
          onPointerSignal: (_) => _stopAutomation(),
          child: RepaintBoundary(child: _content(palette)),
        ),
      ),
      if (_controls || !_ready)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(bottom: false, child: _topBar(palette)),
        ),
      if (_ready)
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: _controls ? _menu(palette) : _footer(palette),
          ),
        ),
    ],
  );

  void _skipChapter(int direction) {
    _stopAutomation();
    _cross(direction, lastPage: false);
  }

  Widget _readingError(ReaderPalette palette) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.ink),
            ),
            TextButton(
              onPressed: () =>
                  _open(_chapter, resume: true, location: _retryPosition),
              child: const Text('重试正文'),
            ),
            if (_blockedChapter case final block?) ...[
              TextButton(
                onPressed: () async {
                  if (await reviewBlockedChapter(context, _books, block) &&
                      mounted) {
                    await _open(
                      _chapter,
                      resume: true,
                      location: _retryPosition,
                    );
                  }
                },
                child: const Text('验证并查看命中原因 / 复核'),
              ),
              TextButton(
                onPressed: () => showBookTextReplacements(context, _books),
                child: const Text('验证并设置文本替换'),
              ),
              if (_index < _chapters.length - 1)
                TextButton(
                  onPressed: () => _open(_chapters[_index + 1]),
                  child: const Text('跳过本章，阅读下一章'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _content(ReaderPalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _readingError(palette);
    }
    if (_images.isNotEmpty) {
      return Focus(
        focusNode: _paperFocus,
        autofocus: !_controls,
        onKeyEvent: _readingKey,
        child: BookImageChapter(
          key: _imageViewport,
          loadImage: (address, token) => _books.chapterImageBytes(
            _imageBook ?? widget.book,
            address,
            token,
            chapter: _imageSourceChapter,
          ),
          images: _images,
          segments: _mixedSegments,
          mode: _style.mode,
          animate: _style.animate,
          textStyle: _style.bodyStyle.copyWith(color: palette.ink),
          textAlign: _style.justify ? TextAlign.justify : TextAlign.start,
          margin: _style.margin,
          onMenu: _toggleControls,
          initialFraction: _progress.value.fraction,
          onProgress: (fraction) => _moved(readerProgress(fraction)),
          onPrevious: () => _cross(-1),
          onNext: () => _cross(1),
        ),
      );
    }
    return Focus(
      focusNode: _paperFocus,
      autofocus: !_controls,
      onKeyEvent: _readingKey,
      child: ReaderTapZones(
        horizontal: _style.mode.horizontal,
        selectionActive: () => _selection.isNotEmpty,
        onTurn: _page,
        onMenu: _toggleControls,
        child: ReaderViewport(
          key: _viewport,
          text: _text,
          titleLength: _chapter.title.length,
          style: _style.bodyStyle.copyWith(color: palette.ink),
          palette: palette,
          mode: _style.mode,
          animate: _style.animate,
          texture: _style.texture,
          margin: _style.margin,
          align: _style.justify ? TextAlign.justify : TextAlign.start,
          initial: _progress.value,
          highlight: _highlight,
          onProgress: _moved,
          canCross: _canCross,
          onBoundary: _cross,
          onSelection: (selection) => _selection = selection,
          onAnnotate: _addAnnotation,
          onCleanup: _cleanupSelection,
        ),
      ),
    );
  }

  Widget _topBar(ReaderPalette palette) => Material(
    color: palette.paper,
    elevation: 2,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Row(
          children: [
            BackButton(color: palette.ink),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _books.bookAllowed(widget.book) ? _chapter.title : '阅读',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    if (_sourceStatus.isNotEmpty)
                      Text(
                        _sourceStatus,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: palette.accent),
                      ),
                  ],
                ),
              ),
            ),
            if (_ready) ...[
              IconButton(
                tooltip: '字号与排版',
                color: palette.ink,
                icon: const Icon(Icons.format_size),
                onPressed: _quickStyle,
              ),
              IconButton(
                tooltip: '书签与笔记',
                color: palette.ink,
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: _annotations,
              ),
              IconButton(
                tooltip: '添加书签或笔记',
                color: palette.ink,
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: _addAnnotation,
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _footer(ReaderPalette palette) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 800),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        child: ValueListenableBuilder<ReaderProgress>(
          valueListenable: _progress,
          builder: (context, progress, _) {
            final label = !_style.status || !_ready
                ? ''
                : _images.isNotEmpty
                ? '${_images.length} 张图片'
                : _style.mode == ReaderTurnMode.scroll
                ? '${(progress.fraction * 100).round()}%'
                : '${progress.page} / ${progress.pages} 页';
            return Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.ink.withValues(alpha: .76),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _autoRunning ? '停止自动阅读' : '阅读菜单',
                  iconSize: 20,
                  color: palette.ink,
                  onPressed: !_ready
                      ? null
                      : _autoRunning
                      ? _stopAutomation
                      : _toggleControls,
                  icon: Icon(
                    _autoRunning
                        ? Icons.pause_circle_outline
                        : Icons.more_horiz,
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<DateTime>(
                    valueListenable: _minute,
                    builder: (context, now, _) => Text(
                      _style.status
                          ? MaterialLocalizations.of(context).formatTimeOfDay(
                              TimeOfDay.fromDateTime(now),
                              alwaysUse24HourFormat: true,
                            )
                          : '',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.ink.withValues(alpha: .76),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _menu(ReaderPalette palette) => Material(
    color: palette.paper,
    elevation: 4,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<ReaderProgress>(
              valueListenable: _progress,
              builder: (context, progress, _) {
                final value = _seeking ?? progress.fraction;
                return Row(
                  children: [
                    const SizedBox(width: 16),
                    Text(
                      '${_index + 1}/${_chapters.length} 章',
                      style: TextStyle(color: palette.ink, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: value,
                        label: '${(value * 100).round()}%',
                        activeColor: palette.accent,
                        onChanged: _images.isNotEmpty
                            ? null
                            : (value) => setState(() => _seeking = value),
                        onChangeEnd: _images.isNotEmpty
                            ? null
                            : (value) {
                                setState(() => _seeking = null);
                                _viewport.currentState?.jump(value);
                              },
                      ),
                    ),
                    Text(
                      '${(value * 100).round()}%',
                      style: TextStyle(color: palette.ink, fontSize: 12),
                    ),
                    const SizedBox(width: 16),
                  ],
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _page(-1),
                ),
                IconButton(
                  focusNode: _contentsFocus,
                  tooltip: '章节目录',
                  icon: const Icon(Icons.format_list_bulleted),
                  onPressed: _showChapters,
                ),
                IconButton(
                  tooltip: '章内查找',
                  icon: const Icon(Icons.search),
                  onPressed: _showFind,
                ),
                IconButton(
                  tooltip: '阅读样式',
                  icon: const Icon(Icons.text_fields),
                  onPressed: _settings,
                ),
                IconButton(
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _page(1),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String _chapterText(String title, String body) {
  final newline = body.indexOf('\n');
  final first = newline == -1 ? body : body.substring(0, newline);
  if (first.trim() != title.trim()) return '$title\n\n$body';
  if (newline == -1) return title;
  final rest = body
      .substring(newline + 1)
      .replaceFirst(RegExp(r'^(?:[ \t]*\r?\n)+'), '');
  return rest.isEmpty ? title : '$title\n\n$rest';
}
