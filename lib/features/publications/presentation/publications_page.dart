import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/platform_services.dart';
import '../../books/data/books_repository.dart';
import '../../books/presentation/book_page_route.dart';
import '../../books/presentation/rich_reader_page.dart';
import '../application/publication_discovery.dart';
import '../application/publication_module.dart';
import '../application/publication_output.dart';
import '../application/publication_workflow.dart';
import '../data/publication_documents.dart';
import '../data/publication_share.dart';
import '../data/publication_sources.dart';
import '../data/publication_zip.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';
import '../domain/share_text.dart';
import 'publication_catalog_view.dart';
import 'publication_rule_editor.dart';
import 'publication_dialogs.dart';
import 'publication_management_view.dart';

class PublicationsPage extends StatefulWidget {
  const PublicationsPage({
    super.key,
    required this.module,
    required this.books,
    required this.platform,
    this.visible = true,
  });
  final PublicationModule module;
  final BooksRepository books;
  final PlatformServices platform;
  final bool visible;
  @override
  State<PublicationsPage> createState() => _PublicationsPageState();
}

class _PublicationsPageState extends State<PublicationsPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _tabs = TabController(length: 4, vsync: this);
  final _query = TextEditingController();
  final _updates = <PublicationSearchUpdate>[];
  final _autoAttempted = <String>{};
  final _passwords = <String, ({String? zip, String? pdf})>{};
  List<PublicationHolding> _holdings = [];
  List<AcquisitionTask> _tasks = [];
  List<PublicationSourceStatus> _sources = [];
  ({int used, int reserved, int limit})? _usage;
  Timer? _poll;
  Timer? _sourcePoll;
  late final StreamSubscription<void> _sourceChanges;
  CancellationToken? _searchToken;
  int _searchPages = 1;
  int _sourceRead = 0;
  String? _loadError;
  bool _loaded = false,
      _active = false,
      _refreshing = false,
      _searching = false,
      _hasDirectory = false;
  bool _resumed = true;
  PublicationModule get _module => widget.module;

  List<PublicationEdition> get _editions {
    final seen = <String>{};
    return [
      for (final update in _updates)
        for (final edition in update.editions)
          if (seen.add(edition.id)) edition,
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _module.policy.addListener(_policyChanged);
    _module.legacy.vault.addListener(_policyChanged);
    _sourceChanges = _module.store.db
        .changesFor(const {'publication_source_settings'})
        .listen((_) => unawaited(_refreshSources().catchError((Object _) {})));
    _visibility();
    unawaited(_refresh(initial: true));
  }

  @override
  void didUpdateWidget(covariant PublicationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _visibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _visibility();
  }

  void _visibility() {
    _poll?.cancel();
    _sourcePoll?.cancel();
    if (!widget.visible || !_resumed) return;
    if (_loaded) {
      unawaited(_refresh());
      _checkSources();
    }
    _sourcePoll = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _checkSources(),
    );
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tasks.any((task) => task.state != AcquisitionState.complete) ||
          _tabs.index == 2) {
        unawaited(_refresh());
      }
    });
  }

  void _checkSources() {
    if (!mounted || !_loaded || !widget.visible || !_resumed) return;
    unawaited(_module.discovery.checkDue().catchError((Object _) {}));
  }

  Future<void> _refreshSources() async {
    final read = ++_sourceRead;
    final sources = await _module.discovery.sources();
    if (!mounted || read != _sourceRead) return;
    final previous = {for (final item in _sources) item.source.id: item};
    final active = {
      for (final item in sources)
        if (item.enabled && !item.paused) item.source.id: item.source,
    };
    setState(() {
      _sources = sources;
      _updates.removeWhere(
        (update) =>
            active[update.source.id]?.sameConfiguration(update.source) != true,
      );
    });
    if (!_loaded || !widget.visible || !_resumed) return;
    final paused = sources
        .where(
          (item) => item.paused && previous[item.source.id]?.paused != true,
        )
        .firstOrNull;
    if (paused != null) {
      _notice(
        '${paused.source.name}已暂停检索 · '
        '${publicationSourceProblemLabel(paused.problem!)}',
      );
    }
  }

  void _policyChanged() {
    _searchToken?.cancel();
    _passwords.clear();
    if (!mounted) return;
    setState(() {
      _updates.clear();
      _holdings = [];
      _tasks = [];
      _searching = false;
    });
    unawaited(_refresh());
  }

  Future<void> _refresh({bool initial = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _module.workflow.initialize();
      if (initial) await _refreshSources();
      final holdings = await _module.library.holdings();
      final tasks = (await _module.store.tasks())
          .where(
            (task) =>
                !_module.policy.supervision.enabled &&
                _module.policy.textAllowed(
                  '${task.edition.title} ${task.edition.author}',
                ),
          )
          .toList();
      final usage = await _module.space.usage();
      final directory = await _module.store.preference(
        PublicationOutput.directoryPreference,
      );
      if (!mounted) return;
      setState(() {
        _holdings = holdings;
        _tasks = tasks;
        _usage = usage;
        _hasDirectory = directory?.isNotEmpty == true;
        _loaded = true;
        _loadError = null;
      });
      if (initial) _checkSources();
      _scheduleImport();
    } catch (error) {
      if (mounted) setState(() => _loadError = _message(error));
    } finally {
      _refreshing = false;
    }
  }

  void _scheduleImport() {
    if (_active || !widget.visible || !_resumed || !mounted) return;
    final task = _tasks
        .where(
          (task) =>
              task.state == AcquisitionState.downloaded &&
              task.problem == null &&
              task.candidate.format != PublicationFormat.zip &&
              !_autoAttempted.contains(task.id),
        )
        .firstOrNull;
    if (task == null) return;
    _autoAttempted.add(task.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_active) {
        unawaited(_run(() => _finish(task, interactive: false), quiet: true));
      }
    });
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool quiet = false,
  }) async {
    if (_active || !mounted) return;
    setState(() => _active = true);
    try {
      await action();
    } on RequestCancelled {
      if (!quiet) _notice('图书操作已中止');
    } catch (error) {
      if (!quiet) _notice(_message(error));
    } finally {
      if (mounted) setState(() => _active = false);
      if (mounted) await _refresh();
    }
  }

  Future<void> _browse() {
    _query.clear();
    return _search(maxPages: 1);
  }

  Future<void> _search({int maxPages = 3}) async {
    _searchToken?.cancel();
    final token = _searchToken = CancellationToken();
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchPages = maxPages;
      _updates.clear();
    });
    try {
      await for (final result in _module.discovery.search(
        _query.text,
        token,
        maxPages: maxPages,
      )) {
        if (!mounted || token.isCancelled || !identical(token, _searchToken)) {
          return;
        }
        setState(() => _updates.add(result));
      }
    } on RequestCancelled {
      // A new query superseded this one.
    } catch (error) {
      if (identical(token, _searchToken)) _notice(_message(error));
    } finally {
      if (mounted && identical(token, _searchToken)) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _buy(
    PublicationEdition edition,
    PublicationFormat format, {
    List<PublicationEdition>? alternatives,
  }) async {
    final task = await _module.workflow.acquireFromCatalog(
      edition,
      format,
      _selectSourceFile,
      alternatives: alternatives ?? _editions,
    );
    if (mounted && task != null) _tabs.animateTo(2);
  }

  Future<PublicationFileSelection?> _selectSourceFile(
    AcquisitionCandidate candidate,
  ) async {
    final access = candidate.publishedAccess;
    var code = access?.code;
    if (access?.needsConfirmation == true) {
      if (!mounted) return null;
      code = await publicationPrompt(context, '确认分享提取码', password: true);
      if (code == null) return null;
    }
    final files = await _inspectShare(
      (supplied, token) async {
        final files = await _module.workflow.inspectSourceShare(
          candidate,
          supplied,
          token,
        );
        return files.where(candidate.matchesSharedFile).toList(growable: false);
      },
      code,
      (next) => code = next,
    );
    if (!mounted || files == null) return null;
    final file = await choosePublicationValue(
      context,
      '选择网盘文件',
      files,
      (file) => file.bytes == null
          ? file.name
          : '${file.name} · ${publicationSize(file.bytes!)}',
      confirmSingle: true,
    );
    return file == null ? null : (file: file, code: code);
  }

  Future<void> _importLocal() async {
    _module.library.requireImport('');
    final digest = _module.workflow.android
        ? await _module.workflow.withAndroidDocument(_importSelectedDocument)
        : await _pickDesktopDocument();
    if (!mounted || digest == null) return;
    _tabs.animateTo(1);
    _notice('图书已入库');
  }

  Future<String?> _pickDesktopDocument() async {
    final item = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'EPUB、PDF、ZIP',
          extensions: ['epub', 'pdf', 'zip'],
          mimeTypes: [
            'application/epub+zip',
            'application/pdf',
            'application/zip',
          ],
        ),
      ],
    );
    if (!mounted || item == null) return null;
    return _importSelectedDocument(
      PublicationLocalDocument.external(File(item.path)),
    );
  }

  Future<String?> _importSelectedDocument(
    PublicationLocalDocument document,
  ) async {
    if (!mounted) return null;
    PublicationZipEntry? entry;
    String? key;
    if (PublicationFormat.fromName(document.name) == PublicationFormat.zip) {
      entry = await _chooseEntry(await PublicationZip.inspect(document.file));
      if (!mounted || entry == null) return null;
      if (entry.encrypted) {
        key = await publicationPrompt(context, 'ZIP 密码', password: true);
        if (key == null) return null;
      }
    }
    return _withPdfPassword(
      (password) => _module.workflow.importDocument(
        document,
        entry: entry,
        zipPassword: key,
        pdfPassword: password,
      ),
    );
  }

  Future<PublicationZipEntry?> _chooseEntry(
    List<PublicationZipEntry> items,
  ) async {
    if (items.isEmpty) throw const FormatException('压缩包里没有可导入的 EPUB 或 PDF');
    final allowed = items
        .where((entry) => _module.library.policy.textAllowed(entry.path))
        .toList();
    if (allowed.isEmpty) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    if (!mounted) return null;
    return choosePublicationValue(
      context,
      '选择压缩包中的图书',
      allowed,
      (entry) =>
          '${entry.path} · ${publicationSize(entry.bytes)}${entry.encrypted ? ' · 有密码' : ''}',
    );
  }

  Future<void> _share() async {
    _module.library.requireImport('');
    final raw = await publicationPrompt(
      context,
      '粘贴图书分享文本',
      multiline: true,
      limit: 16384,
    );
    if (!mounted || raw == null) return;
    final selected = await choosePublicationValue(
      context,
      '选择领取链接',
      publicationShareInputs(raw),
      (item) => '${item.link.host}${item.link.path}',
    );
    if (!mounted || selected == null) return;
    var code = selected.code;
    if (selected.needsConfirmation) {
      code = await publicationPrompt(context, '确认分享提取码', password: true);
      if (code == null) return;
    }
    final files = await _inspectShare(
      (code, token) => _module.shares.inspect(selected.link, code, token),
      code,
      (newCode) => code = newCode,
    );
    if (!mounted || files == null) return;
    final file = await choosePublicationValue(
      context,
      '选择要下载的图书',
      files,
      (item) => item.name,
    );
    if (!mounted || file == null) return;
    final id = publicationId('share:${selected.link}:${file.id}');
    final edition = PublicationEdition(
      id: id,
      title: p.basenameWithoutExtension(file.name),
      page: selected.link,
      candidates: [
        AcquisitionCandidate(
          source: 'manual',
          link: selected.link,
          format: file.format,
          bytes: file.bytes,
          fileId: file.id,
          page: selected.link,
        ),
      ],
    );
    _tabs.animateTo(2);
    final task = await _module.workflow.add(
      edition,
      file.format,
      shareCode: code,
    );
    if (mounted &&
        (selected.zipPassword != null || selected.pdfPassword != null)) {
      _passwords[task] = (zip: selected.zipPassword, pdf: selected.pdfPassword);
    }
  }

  Future<List<PublicationSharedFile>?> _inspectShare(
    Future<List<PublicationSharedFile>> Function(String?, CancellationToken)
    inspect,
    String? code,
    ValueChanged<String> onCode,
  ) async {
    var supplied = code;
    while (mounted) {
      try {
        final files = await inspect(supplied, CancellationToken());
        if (files.isEmpty) {
          throw const FormatException('分享中没有可导入的 EPUB、PDF 或 ZIP');
        }
        final allowed = files
            .where((file) => _module.library.policy.textAllowed(file.name))
            .toList();
        if (allowed.isEmpty) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
        return allowed;
      } on PublicationFailure catch (error) {
        if (error.problem != PublicationProblem.shareCode || !mounted) rethrow;
        supplied = await publicationPrompt(context, '输入分享提取码', password: true);
        if (supplied == null) return null;
        onCode(supplied);
      }
    }
    return null;
  }

  Future<void> _finish(
    AcquisitionTask task, {
    bool interactive = true,
    bool retainArchive = false,
  }) async {
    final secrets = _passwords.remove(task.id);
    final published = task.candidate.publishedAccess;
    PublicationZipEntry? entry;
    String? key;
    if (task.candidate.format == PublicationFormat.zip) {
      entry = await _chooseEntry(
        await _module.workflow.downloadedEntries(task),
      );
      if (!mounted || entry == null) return;
      if (entry.encrypted) {
        key =
            secrets?.zip ??
            (task.problem == PublicationProblem.zipPassword
                ? null
                : published?.zipPassword) ??
            await publicationPrompt(context, '输入 ZIP 密码', password: true);
        if (key == null) return;
      }
    }
    Future<bool> finish(String? password) async {
      await _module.workflow.finish(
        task,
        entry: entry,
        zipPassword: key,
        pdfPassword: password,
        retainArchive: retainArchive,
      );
      final latest = await _module.store.task(task.id);
      if (latest?.result case final digest?) {
        await _saveToDirectory(digest, password);
      }
      return true;
    }

    final pdf =
        secrets?.pdf ??
        (task.problem == PublicationProblem.pdfPassword
            ? null
            : published?.pdfPassword);
    if (interactive) {
      await _withPdfPassword(finish, initial: pdf);
    } else {
      await finish(pdf);
    }
  }

  Future<void> _saveToDirectory(String digest, String? password) async {
    try {
      await _module.output.autoSave(digest, password: password);
    } on Exception catch (error) {
      _notice('图书已入库。${_message(error)}');
    }
  }

  Future<void> _importRetained(AcquisitionTask task) async {
    final entry = await _chooseEntry(
      await _module.workflow.downloadedEntries(task),
    );
    if (entry == null || !mounted) return;
    final key = entry.encrypted
        ? await publicationPrompt(context, '输入 ZIP 密码', password: true)
        : null;
    if (entry.encrypted && key == null) return;
    final imported = await _withPdfPassword((password) async {
      final digest = await _module.workflow.importRetainedArchive(
        task,
        entry,
        zipPassword: key,
        pdfPassword: password,
      );
      await _saveToDirectory(digest, password);
      return digest;
    });
    if (imported != null) _notice('图书已入库');
  }

  Future<T?> _withPdfPassword<T>(
    Future<T> Function(String?) operation, {
    String? initial,
  }) async {
    var password = initial;
    while (mounted) {
      try {
        return await operation(password);
      } on PublicationFailure catch (error) {
        if (error.problem != PublicationProblem.pdfPassword || !mounted) {
          rethrow;
        }
        password = await publicationPrompt(
          context,
          '输入 PDF 文档密码',
          password: true,
        );
        if (password == null) return null;
      }
    }
    return null;
  }

  Future<void> _read(PublicationHolding item) => _withPdfPassword((
    password,
  ) async {
    final document = await _module.library.open(
      item,
      CancellationToken(),
      password: password,
    );
    try {
      if (!mounted) return;
      final access = _module.reading.access(
        document.book,
        publicationReaderChapters(document.book, document.admission.chapters),
        document.allowed,
        document.admission.hasText,
        password,
      );
      final route = BookPageRoute<void>(
        builder: (_) => RichReaderPage(
          repository: widget.books,
          book: document.book,
          file: document.file,
          platform: widget.platform,
          document: access,
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      await _module.space.unlease(document.lease);
    }
  });

  Future<void> _addLegacy() async {
    final items = await _module.library.legacyBooks();
    if (!mounted) return;
    if (items.isEmpty) {
      _notice('原书库没有可加入的 EPUB 或 PDF');
      return;
    }
    final book = await choosePublicationValue(
      context,
      '选择原书库图书',
      items,
      (item) => item.title,
    );
    if (book != null) await _module.library.attachLegacy(book);
  }

  Future<void> _shelfAction(PublicationHolding item, String action) async {
    switch (action) {
      case 'delete':
        if (await confirmPublicationDelete(context, '删除本地副本', '书目、进度和笔记会保留。')) {
          await _module.library.deleteFile(item);
        }
      case 'remove':
        await _module.library.remove(item);
      case 'keep':
        await _module.library.setKept(item, !item.kept);
      case 'export':
        await _withPdfPassword(
          (password) => _module.output.exportBook(item, password: password),
        );
      case 'save':
        if (!_hasDirectory && await _module.output.pickDirectory() == null) {
          return;
        }
        final saved = await _withPdfPassword(
          (password) =>
              _module.output.autoSave(item.digest, password: password),
        );
        if (saved != null) _notice('已保存到指定目录');
      case 'recover':
        final saved = _tasks
            .where((task) => task.result == item.digest)
            .firstOrNull;
        final choices = [if (saved != null) '重新下载', '关联本地文件'];
        final selection = await choosePublicationValue(
          context,
          '恢复图书副本',
          choices,
          (value) => value,
        );
        if (selection == '重新下载' && saved != null) {
          final edition = saved.edition.withCandidates(saved.candidates);
          await _buy(edition, saved.candidate.format);
        } else if (selection == '关联本地文件') {
          await _importLocal();
        }
    }
  }

  Future<void> _unlistedCopies() async {
    final copies = await _module.library.unlistedCopies();
    if (!mounted) return;
    if (copies.isEmpty) {
      _notice('没有已移除的本地副本');
      return;
    }
    final copy = await choosePublicationValue(
      context,
      '书目移除后保留的副本',
      copies,
      (item) =>
          '${item.edition.title} · ${item.format.label} · ${publicationSize(item.bytes)}',
      confirmSingle: true,
    );
    if (copy == null || !mounted) return;
    final approved = await confirmPublicationDelete(
      context,
      '删除《${copy.edition.title}》的本地副本？',
      '释放 ${publicationSize(copy.bytes)} 托管空间。阅读进度和笔记会保留。',
    );
    if (!approved || !mounted) return;
    await _module.library.deleteFile(copy, onlyUnlisted: true);
    _notice('已删除本地副本');
  }

  Future<void> _taskAction(AcquisitionTask task, String action) async {
    switch (action) {
      case 'pause':
        await _module.workflow.pause(task);
      case 'retry':
        if (requiresPublicationFileChoice(task.candidate)) {
          await _chooseTaskShare(task);
          return;
        }
        final needsCode = task.problem == PublicationProblem.shareCode;
        final code = needsCode
            ? await publicationPrompt(context, '输入分享提取码', password: true)
            : null;
        if (!needsCode || code != null) {
          await _module.workflow.start(
            task.id,
            code: code,
            codeFor: task.candidate.id,
          );
        }
      case 'chooseFile':
        await _chooseTaskShare(task);
      case 'replace':
        await _share();
      case 'import':
        await _finish(task);
      case 'importKeep':
        await _finish(task, retainArchive: true);
      case 'readArchive':
        await _importRetained(task);
      case 'deleteArchive':
        if (await confirmPublicationDelete(context, '删除原 ZIP', '已入库的图书会保留。')) {
          await _module.workflow.deleteRetainedArchive(task);
        }
      case 'remove':
        if (await confirmPublicationDelete(
          context,
          '移除下载任务',
          '任务的临时文件和失败记录会删除。',
        )) {
          await _module.workflow.removeTask(task);
        }
      case 'source':
        await _origin(task.candidate.page ?? task.candidate.link);
      case 'open':
        final item = _holdings
            .where((entry) => entry.digest == task.result && entry.resident)
            .firstOrNull;
        if (item != null) {
          await _read(item);
        } else {
          _notice('本地副本缺失，可从书库重新获取');
        }
    }
  }

  Future<void> _chooseTaskShare(AcquisitionTask task) async {
    if (task.retryAt?.isAfter(DateTime.now()) == true) {
      throw PublicationFailure(
        PublicationProblem.rateLimit,
        retryAt: task.retryAt,
      );
    }
    final pending = [
      for (final (index, candidate) in task.candidates.indexed)
        if (requiresPublicationFileChoice(candidate) &&
            (index == task.selected ||
                task.failures.any(
                  (failure) =>
                      failure.candidate == index &&
                      failure.problem == PublicationProblem.shareFile,
                )))
          candidate,
    ];
    if (pending.isEmpty) return;
    final selected = await choosePublicationValue(
      context,
      '选择领取链接',
      pending,
      (item) => '${item.link.host}${item.link.path}',
    );
    if (!mounted || selected == null) return;
    final edition = task.edition.withCandidates([
      selected,
      ...task.candidates.where((item) => item.id != selected.id),
    ]);
    await _buy(edition, selected.format, alternatives: const []);
  }

  Future<void> _sourceAction(
    PublicationSourceStatus item,
    String action,
  ) async {
    switch (action) {
      case 'check':
        await _module.discovery.check(item.source);
      case 'favorite':
        await _module.discovery.setFavorite(item.source, !item.favorite);
      case 'page':
        await _origin(item.source.endpoint);
      case 'remove':
        await _module.discovery.remove(item.source);
      case 'edit':
        await _sourceConfig(item.source);
      case 'export':
        await _module.output.exportRule(item.source);
    }
  }

  Future<void> _origin(Uri url) async {
    final action = await choosePublicationValue(context, '来源链接', const [
      '复制链接',
      '在系统浏览器查看',
    ], (value) => value);
    if (action == null) return;
    _module.library.requireImport(url.host);
    if (action == '复制链接') {
      await Clipboard.setData(ClipboardData(text: url.toString()));
      _notice('链接已复制');
    } else if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _notice('无法打开系统浏览器');
    }
  }

  Future<void> _quota() async {
    _module.library.requireImport('');
    final input = await publicationPrompt(
      context,
      '托管容量上限（MiB）',
      initial: '${(_usage?.limit ?? (2 << 30)) >> 20}',
      limit: 5,
    );
    if (input == null) return;
    final mib = int.tryParse(input);
    if (mib == null) throw const FormatException('请输入整数容量');
    _module.library.requireImport('');
    await _module.space.setLimit(mib << 20);
  }

  Future<void> _sourceConfig([PublicationSource? initial]) async {
    _module.library.requireImport('');
    final value = await editPublicationRule(
      context,
      _module.discovery,
      initial: initial,
      importFile: _importRuleFile,
    );
    if (!mounted || value == null) return;
    _module.library.requireImport('');
    await _module.discovery.saveConfig(value, id: initial?.id);
  }

  Future<String?> _importRuleFile() async {
    _module.library.requireImport('');
    Future<String> read(File file) async {
      if (await file.length() > 32768) throw const FormatException('规则超过大小限制');
      _module.library.requireImport('');
      return file.readAsString();
    }

    if (_module.workflow.android) {
      return _module.workflow.withAndroidDocument(
        (document) => read(document.file),
        backup: true,
      );
    }
    final selected = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图书书源规则',
          extensions: ['json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    return selected == null ? null : read(File(selected.path));
  }

  Future<void> _restoreBackup() async {
    if (_module.workflow.android) {
      final count = await _module.workflow.withAndroidDocument(
        (document) => _module.output.backup.restore(document.file),
        backup: true,
      );
      if (count != null) _notice('处理了 $count 条书库记录');
      return;
    }
    final backup = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图书备份',
          extensions: ['json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    if (backup == null) return;
    final count = await _module.output.backup.restore(File(backup.path));
    _notice('处理了 $count 条书库记录');
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _message(Object error) => switch (error) {
    PublicationFailure(:final problem, spaceShortfall: final info?) =>
      '${problem.label}\n${publicationSpaceDetails(info)}',
    PublicationFailure(:final problem) => problem.label,
    FormatException(:final message) => message.toString(),
    FileSystemException() || PlatformException() => '文件或目录暂不可用',
    _ => '图书操作未完成，请重试',
  };

  @override
  Widget build(BuildContext context) {
    if (_loadError case final error?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error),
            TextButton(
              onPressed: () => _refresh(initial: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '发现'),
                Tab(text: '书库'),
                Tab(text: '任务'),
                Tab(text: '书源'),
              ],
            ),
            if (_active) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  PublicationCatalogView(
                    input: _query,
                    busy: _searching,
                    editions: _editions,
                    updates: _updates,
                    onSearch: _search,
                    onBrowse: _browse,
                    onMore: _updates.isEmpty || _searchPages >= 5
                        ? null
                        : () => _search(maxPages: 5),
                    onBuy: (book, format) => _run(() => _buy(book, format)),
                    onShare: () => _run(_share),
                    onLocal: () => _run(_importLocal),
                    onPage: (uri) => _run(() => _origin(uri)),
                  ),
                  PublicationShelfView(
                    entries: _holdings,
                    open: (item) => _run(() => _read(item)),
                    action: (item, action) =>
                        _run(() => _shelfAction(item, action)),
                    onLocal: () => _run(_importLocal),
                    onLegacy: () => _run(_addLegacy),
                    onUnlisted: () => _run(_unlistedCopies),
                    exportBackup: () => _run(_module.output.exportBackup),
                    restoreBackup: () => _run(_restoreBackup),
                  ),
                  PublicationTasksView(
                    tasks: _tasks,
                    action: (task, action) =>
                        _run(() => _taskAction(task, action)),
                  ),
                  PublicationSourcesView(
                    sources: _sources,
                    action: (item, action) =>
                        _run(() => _sourceAction(item, action)),
                    toggle: (item, enabled) => _run(() async {
                      await _module.discovery.setEnabled(item.source, enabled);
                      if (enabled) _checkSources();
                    }),
                    onAdd: () => _run(() => _sourceConfig()),
                    onQuota: () => _run(_quota),
                    onDirectory: () => _run(_module.output.pickDirectory),
                    onClearDirectory: () => _run(_module.output.clearDirectory),
                    usage: _usage,
                    hasDirectory: _hasDirectory,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _module.policy.removeListener(_policyChanged);
    _module.legacy.vault.removeListener(_policyChanged);
    _poll?.cancel();
    _sourcePoll?.cancel();
    unawaited(_sourceChanges.cancel());
    _searchToken?.cancel();
    _query.dispose();
    _tabs.dispose();
    super.dispose();
  }
}
