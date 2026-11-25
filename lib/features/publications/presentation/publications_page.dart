import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/platform_services.dart';
import '../../books/data/books_repository.dart';
import '../../books/presentation/book_page_route.dart';
import '../../books/presentation/rich_reader_page.dart';
import '../application/publication_collections.dart';
import '../application/publication_discovery.dart';
import '../application/publication_module.dart';
import '../application/publication_output.dart';
import '../application/publication_workflow.dart';
import '../data/publication_documents.dart';
import '../data/publication_bookstack_reader.dart';
import '../data/publication_http.dart';
import '../data/publication_kgbook_rows.dart';
import '../data/publication_share.dart';
import '../data/publication_share_provider.dart';
import '../data/publication_sources.dart';
import '../data/publication_website_target.dart';
import '../data/publication_zip.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import '../domain/publication_library.dart';
import '../domain/share_text.dart';
import 'baidu_token_guide.dart';
import 'publication_book_lists_page.dart';
import 'publication_bookstack_page.dart';
import 'publication_catalog_view.dart';
import 'publication_channel_picker.dart';
import 'publication_rule_editor.dart';
import 'publication_dialogs.dart';
import 'publication_management_view.dart';
import 'publication_sources_view.dart';
import 'publication_website_panel.dart';

enum PublicationPageEntry {
  library(1),
  tasks(2),
  sources(3);

  const PublicationPageEntry(this.tab);
  final int tab;
}

class PublicationsPage extends StatefulWidget {
  const PublicationsPage({
    super.key,
    required this.module,
    required this.books,
    required this.platform,
    this.visible = true,
    this.onBack,
    this.entry,
  });
  final PublicationModule module;
  final BooksRepository books;
  final PlatformServices platform;
  final bool visible;
  final VoidCallback? onBack;
  final PublicationPageEntry? entry;
  @override
  State<PublicationsPage> createState() => _PublicationsPageState();
}

class _PublicationsPageState extends State<PublicationsPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: _tabIndex,
  );
  final _catalog = GlobalKey<PublicationCatalogViewState>();
  final _passwords = <String, ({String? zip, String? pdf})>{};
  List<PublicationHolding> _holdings = [];
  List<AcquisitionTask> _tasks = [];
  int _hiddenHoldings = 0, _hiddenTasks = 0;
  List<PublicationSourceStatus> _sources = [];
  List<PublicationGroup> _groups = [];
  PublicationChannelGroups _channelGroups = {};
  (String, int)? _channelRequest;
  (PublicationEdition, int)? _discoveryRequest;
  ({int used, int reserved, int limit})? _usage;
  Timer? _poll;
  late final StreamSubscription<void> _sourceChanges;
  late final StreamSubscription<void> _taskChanges;
  int _policyRevision = 0;
  int _discoverySearchSerial = 0;
  late int _tabIndex = widget.entry?.tab ?? 0;
  int? _returnTab;
  int _sourceRead = 0;
  String? _loadError;
  bool _loaded = false,
      _active = false,
      _refreshing = false,
      _refreshPending = false,
      _hasDirectory = false;
  bool _resumed = true;
  CancellationToken? _shareInspection;
  String? _activeLabel;
  PublicationModule get _module => widget.module;

  @override
  void initState() {
    super.initState();
    _module.workflow.enableAutomaticImport(_module.output);
    WidgetsBinding.instance.addObserver(this);
    _tabs.addListener(_tabChanged);
    _module.policy.addListener(_policyChanged);
    _module.legacy.vault.addListener(_policyChanged);
    _sourceChanges = _module.store.db
        .changesFor(const {'publication_source_settings'})
        .listen((_) => unawaited(_refreshSources().catchError((Object _) {})));
    _taskChanges = _module.store.db
        .changesFor({'publication_tasks', 'publication_shelf'})
        .listen((_) {
          if (_hasOngoingTasks) return;
          if (widget.visible && _resumed && !_refreshing) {
            unawaited(_refresh());
          } else if (widget.visible && _resumed) {
            _refreshPending = true;
          }
        });
    _visibility();
    unawaited(_refresh(initial: true));
  }

  @override
  void didUpdateWidget(covariant PublicationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible &&
        (!oldWidget.visible || oldWidget.entry != widget.entry)) {
      if (widget.entry?.tab case final index?) {
        if (oldWidget.visible) {
          _openTab(index);
        } else {
          _returnTab = null;
          _tabs.animateTo(index);
        }
      }
    }
    if (oldWidget.visible != widget.visible) _visibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _resumed = state == AppLifecycleState.resumed);
    _visibility();
  }

  void _tabChanged() {
    if (_tabIndex == _tabs.index) return;
    setState(() => _tabIndex = _tabs.index);
    if (_tabIndex == 3) _checkSources();
  }

  void _openTab(int index) {
    if (_tabs.index == index) return;
    _returnTab = _tabs.index;
    _tabs.animateTo(index);
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_tabs.index == 0 && _catalog.currentState?.goBack() == true) return;
    final previous = _returnTab;
    _returnTab = null;
    if (previous != null && previous != _tabs.index) {
      _tabs.animateTo(previous);
    } else if (widget.entry?.tab == _tabs.index && widget.onBack != null) {
      widget.onBack!();
    } else if (_tabs.index != 0) {
      _tabs.animateTo(0);
    } else {
      widget.onBack?.call();
    }
  }

  void _visibility() {
    _poll?.cancel();
    if (!widget.visible || !_resumed) {
      _shareInspection?.cancel();
      return;
    }
    if (_loaded) {
      unawaited(_refresh());
      _checkSources();
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_hasOngoingTasks) {
        unawaited(_refresh());
      }
    });
  }

  bool get _hasOngoingTasks => _tasks.any(
    (task) => switch (task.state) {
      AcquisitionState.resolving ||
      AcquisitionState.downloading ||
      AcquisitionState.importing => true,
      AcquisitionState.waiting => task.problem == null,
      AcquisitionState.downloaded =>
        task.problem == null && task.candidate.format != PublicationFormat.zip,
      _ => false,
    },
  );

  void _checkSources() {
    if (!mounted ||
        !_loaded ||
        !widget.visible ||
        !_resumed ||
        _tabIndex != 3) {
      return;
    }
    unawaited(_module.discovery.checkDue().catchError((Object _) {}));
  }

  Future<void> _refreshSources() async {
    final read = ++_sourceRead;
    final sources = await _module.discovery.sources();
    if (!mounted || read != _sourceRead) return;
    final previous = {for (final item in _sources) item.source.id: item};
    setState(() => _sources = sources);
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
    _shareInspection?.cancel();
    _passwords.clear();
    if (!mounted) return;
    setState(() {
      _policyRevision++;
      _holdings = [];
      _tasks = [];
      _hiddenHoldings = 0;
      _hiddenTasks = 0;
      _groups = [];
      _discoveryRequest = null;
      _channelRequest = null;
    });
    unawaited(_refresh());
  }

  Future<void> _refresh({bool initial = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    final revision = _policyRevision;
    try {
      await _module.workflow.initialize();
      final (
        shelf,
        storedTasks,
        usage,
        directory,
        groups,
        channelGroups,
        _,
      ) = await (
        _module.library.shelfVisibility(),
        _module.store.tasks(),
        _module.space.usage(),
        _module.store.preference(PublicationOutput.directoryPreference),
        _module.collections.groups(),
        initial ? _readChannelGroups() : Future.value(null),
        initial ? _refreshSources() : Future<void>.value(),
      ).wait;
      final tasks = storedTasks
          .where(
            (task) =>
                !_module.policy.supervision.enabled &&
                !_module.policy.supervision.corrupted &&
                _module.policy.textAllowed(
                  '${task.edition.title} ${task.edition.author}',
                ),
          )
          .toList();
      if (!mounted || revision != _policyRevision) return;
      setState(() {
        _holdings = shelf.entries;
        _hiddenHoldings = shelf.hidden;
        _tasks = tasks;
        _hiddenTasks = storedTasks.length - tasks.length;
        _groups = groups;
        if (channelGroups != null) _channelGroups = channelGroups;
        _usage = usage;
        _hasDirectory = directory?.isNotEmpty == true;
        _loaded = true;
        _loadError = null;
      });
      if (initial) _checkSources();
      scheduleBaiduTaskTokenGuide(
        context,
        _module,
        tasks,
        () => widget.visible && _resumed && !_active && _tabIndex == 2,
      );
    } catch (error) {
      if (mounted && revision == _policyRevision) {
        setState(() => _loadError = _message(error));
      }
    } finally {
      _refreshing = false;
      if (mounted && (revision != _policyRevision || _refreshPending)) {
        _refreshPending = false;
        unawaited(_refresh(initial: !_loaded));
      }
    }
  }

  Future<PublicationChannelGroups> _readChannelGroups() async {
    final saved = await _module.store.preference(
      publicationChannelGroupsPreference,
    );
    if (saved == null) return {};
    try {
      final data = jsonDecode(saved);
      if (data is Map<String, dynamic>) {
        return {
          for (final entry in data.entries)
            if (entry.value is List)
              entry.key: (entry.value as List).whereType<String>().toSet(),
        };
      }
    } on FormatException {
      return {};
    }
    return {};
  }

  Future<void> _manageChannelGroups() async {
    final groups = await managePublicationChannelGroups(
      context,
      _channelGroups,
      _sources
          .where((item) => _module.discovery.manageable(item.source))
          .toList(),
    );
    if (groups == null || !mounted) return;
    await _module.store.setPreference(
      publicationChannelGroupsPreference,
      jsonEncode(groups.map((key, ids) => MapEntry(key, ids.toList()))),
    );
    if (mounted) setState(() => _channelGroups = groups);
  }

  void _enterChannel(String id) {
    setState(() {
      _discoveryRequest = null;
      _channelRequest = (id, ++_discoverySearchSerial);
    });
    _openTab(0);
  }

  Future<void> _run(Future<void> Function() action, {String? label}) async {
    if (!mounted) return;
    if (_active) {
      _notice(_activeLabel ?? '正在处理上一项操作');
      return;
    }
    setState(() {
      _active = true;
      _activeLabel = label;
    });
    try {
      await action();
    } on RequestCancelled {
      _notice('图书操作已中止');
    } catch (error) {
      _notice(_message(error));
    } finally {
      if (mounted) {
        setState(() {
          _active = false;
          _activeLabel = null;
        });
      }
      if (mounted) await _refresh();
    }
  }

  Future<void> _buy(
    PublicationEdition edition,
    PublicationFormat format, {
    List<PublicationEdition> alternatives = const [],
  }) async {
    final local = _localEdition(edition, format);
    if (local != null) {
      await _read(local);
      return;
    }
    final task = await _module.workflow.acquireFromCatalog(
      edition,
      format,
      _selectSourceFile,
      alternatives: alternatives,
    );
    if (task != null) _taskAdded();
  }

  Future<void> _openResource(
    PublicationEdition book,
    PublicationResource resource,
    bool external, {
    List<PublicationResource>? options,
  }) async {
    final text = '${book.title} ${book.author} ${resource.link.host}';
    _module.library.requireImport(text);
    validatePublicationAddress(resource.link);
    if (resource.link.scheme != 'https' ||
        resource.link.port != 443 ||
        !await _module.discovery.isEnabled(resource.source)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    if (!mounted || !widget.visible) return;
    if (resource.lookupRequired && !external) {
      await _openCatalogueResources(book, resource);
      return;
    }
    final format = resource.format;
    if (resource.source == kgbookSource &&
        format != null &&
        resource.link == book.page &&
        kgbookBookNumber(resource.link) != null &&
        kgbookEditionId(resource.link) == book.id) {
      final candidate = AcquisitionCandidate(
        source: resource.source,
        link: resource.link,
        page: resource.link,
        format: format,
      );
      await _buy(book.withCandidates([candidate]), format);
      return;
    }
    if (external) {
      await _openPublishedLink(resource, text);
      return;
    }
    try {
      await _downloadResource(book, resource);
    } catch (error) {
      if (!mounted ||
          !widget.visible ||
          error is RequestCancelled ||
          (error is PublicationFailure &&
              error.problem == PublicationProblem.blocked)) {
        rethrow;
      }
      final alternatives = {
        for (final item in options ?? book.resources)
          if (!item.lookupRequired) item.link: item,
      }.values.toList();
      final selected = await choosePublicationValue(
        context,
        _message(error),
        alternatives,
        (item) => '打开${item.label}',
        confirmSingle: true,
      );
      if (mounted && selected != null) {
        await _openPublishedLink(
          selected,
          '${book.title} ${book.author} ${selected.link.host}',
        );
      }
    }
  }

  PublicationSource? _enabledWebsiteSource(String id) => _sources
      .where((item) => item.source.id == id && item.enabled && !item.paused)
      .firstOrNull
      ?.source;

  PublicationWebsiteTarget? _websiteTask(AcquisitionTask task) =>
      PublicationWebsiteTarget.forTask(
        _enabledWebsiteSource(task.candidate.source),
        task,
      );

  Uri? _kgbookBrowserPage(AcquisitionTask task) {
    final candidate = task.candidate;
    final page = candidate.page;
    if (task.state != AcquisitionState.failed ||
        !const {
          PublicationProblem.emptyResponse,
          PublicationProblem.timeout,
          PublicationProblem.network,
          PublicationProblem.invalid,
          PublicationProblem.challenge,
          PublicationProblem.guestLimit,
        }.contains(task.problem) ||
        candidate.source != kgbookSource ||
        candidate.fileId != null ||
        page == null ||
        candidate.link != page ||
        kgbookBookNumber(page) == null ||
        kgbookEditionId(page) != task.edition.id) {
      return null;
    }
    return page;
  }

  Future<void> _website(PublicationWebsiteTarget target) async {
    if (!mounted || !widget.visible || !_resumed) return;
    final downloaded = await showPublicationWebsite(
      context,
      _module.websites,
      target,
      _module.workflow.downloadFromWebsite,
    );
    if (mounted && downloaded) _openTab(2);
  }

  Future<void> _openCatalogueResources(
    PublicationEdition book,
    PublicationResource entry,
  ) async {
    final token = _shareInspection = CancellationToken();
    setState(() => _activeLabel = '正在查找《${book.title}》的下载入口');
    var heading = '选择下载入口';
    List<PublicationResource> options;
    try {
      options = await withPublicationRequestDeadline(
        token,
        const Duration(seconds: 28),
        (request) =>
            _module.workflow.loadCatalogueResources(book, entry, request),
      );
      token.check();
    } on RequestCancelled {
      rethrow;
    } on Exception catch (error) {
      if (error is PublicationFailure &&
          error.problem == PublicationProblem.blocked) {
        rethrow;
      }
      heading = _message(error);
      options = [
        PublicationResource(
          source: entry.source,
          link: entry.link,
          label: '原站详情',
        ),
      ];
    } finally {
      if (mounted && identical(_shareInspection, token)) {
        setState(() => _shareInspection = null);
      }
    }
    if (!mounted || !widget.visible) return;
    final selected = await choosePublicationValue(
      context,
      heading,
      options,
      (item) => switch (item) {
        PublicationResource(source: kgbookSource, format: _?) => item.label,
        PublicationResource(canListFiles: true) => '查看${item.label}文件',
        _ => '打开${item.label}',
      },
      confirmSingle: true,
    );
    if (selected != null && mounted && widget.visible) {
      await _openResource(
        book,
        selected,
        !selected.canListFiles,
        options: options,
      );
    }
  }

  Future<void> _downloadResource(
    PublicationEdition book,
    PublicationResource resource,
  ) async {
    var code = resource.code;
    final files = await _inspectShare(
      resource.link,
      (supplied, token) => _module.workflow.inspectCatalogueResource(
        book,
        resource,
        supplied,
        token,
      ),
      code,
      (newCode) => code = newCode,
    );
    if (!mounted || files == null) return;
    final file = await choosePublicationShareFile(context, files);
    if (!mounted || file == null) return;
    final access = await choosePublicationDownloadAccess(
      context,
      resource.link,
    );
    if (access == null || !mounted) return;
    final candidate = AcquisitionCandidate(
      source: resource.source,
      link: resource.link,
      format: file.format,
      page: book.page,
      bytes: file.bytes,
      fileId: file.id,
      sharedFileName: file.name,
      publishedAccess: (
        link: resource.link,
        code: resource.code,
        zipPassword: null,
        pdfPassword: null,
        needsConfirmation: false,
      ),
    );
    await _module.workflow.add(
      book.withCandidates([candidate]),
      file.format,
      shareCode: code,
      baiduAccessToken: access.token,
    );
    _taskAdded();
  }

  Future<void> _openPublishedLink(
    PublicationResource resource,
    String text,
  ) async {
    validatePublicationAddress(resource.link);
    _module.discovery.http.authorize(resource.link);
    if (resource.link.scheme != 'https' ||
        resource.link.port != 443 ||
        !await _module.discovery.isEnabled(resource.source)) {
      throw const PublicationFailure(PublicationProblem.blocked);
    }
    if (!mounted) return;
    if (isBaiduPublicationShare(resource.link)) {
      await showBaiduPublicationShare(context, resource.link, resource.code, (
        url,
      ) async {
        if (!await _module.discovery.isEnabled(resource.source) || !mounted) {
          return;
        }
        _module.library.requireImport(text);
        if (url == null) {
          await _importLocal();
          return;
        }
        _module.discovery.http.authorize(url);
        if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
          _notice('无法打开百度网盘分享页');
        }
      });
      return;
    }
    final code = resource.code;
    final query = resource.link.queryParameters;
    if (code != null && query['pwd'] != code && query['p'] != code) {
      final action = await choosePublicationValue(
        context,
        resource.label,
        const ['复制提取码并打开', '在系统浏览器打开'],
        (value) => value,
      );
      if (action == null || !mounted) return;
      _module.library.requireImport(text);
      if (!await _module.discovery.isEnabled(resource.source)) return;
      if (action == '复制提取码并打开') {
        await Clipboard.setData(ClipboardData(text: code));
      }
    }
    _module.library.requireImport(text);
    _module.discovery.http.authorize(resource.link);
    if (!await launchUrl(resource.link, mode: LaunchMode.externalApplication)) {
      _notice('无法打开系统浏览器');
    }
  }

  PublicationHolding? _localEdition(
    PublicationEdition edition,
    PublicationFormat format,
  ) => _holdings
      .where(
        (item) =>
            item.resident &&
            (item.format == format ||
                (format == PublicationFormat.azw && item.format.isKindle)) &&
            edition.confirmsSameEdition(item.edition),
      )
      .firstOrNull;

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
      candidate.link,
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
    final file = await choosePublicationShareFile(context, files);
    return file == null ? null : (file: file, code: code);
  }

  Future<void> _importLocal() async {
    _module.library.requireImport('');
    final digest = _module.workflow.android
        ? await _module.workflow.withAndroidDocument(_importSelectedDocument)
        : await _pickDesktopDocument();
    if (!mounted || digest == null) return;
    _openTab(1);
    _notice('图书已入库');
  }

  Future<String?> _pickDesktopDocument() async {
    final item = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: '电子书和 ZIP',
          extensions: PublicationFormat.values
              .map((format) => format.name)
              .toList(),
          mimeTypes: PublicationFormat.values
              .map((format) => format.mimeType)
              .toList(),
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

  Future<PublicationZipEntry?> _chooseEntry(List<PublicationZipEntry> items) =>
      mounted
      ? choosePublicationZipEntry(
          context,
          items,
          _module.library.policy.textAllowed,
        )
      : Future.value();

  Future<void> _share({AcquisitionTask? replacing}) async {
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
      selected.link,
      (code, token) => _module.shares.inspect(selected.link, code, token),
      code,
      (newCode) => code = newCode,
    );
    if (!mounted || files == null) return;
    final options = replacing == null
        ? files
        : files
              .where((file) => file.format == replacing.candidate.format)
              .toList();
    if (options.isEmpty) {
      _notice(
        replacing == null
            ? '分享中没有可下载的电子书'
            : '分享中没有 ${replacing.candidate.format.label} 文件',
      );
      return;
    }
    final file = await choosePublicationShareFile(context, options);
    if (!mounted || file == null) return;
    final access = await choosePublicationDownloadAccess(
      context,
      selected.link,
    );
    if (access == null || !mounted) return;
    final pdf = file.format == PublicationFormat.zip
        ? null
        : selected.pdfPassword;
    final String task;
    if (replacing == null) {
      task = await _module.workflow.addSharedFile(
        selected.link,
        file,
        code: code,
        baiduAccessToken: access.token,
        pdfPassword: pdf,
      );
      if (mounted) _openTab(2);
    } else {
      task = replacing.id;
      await _module.workflow.replaceTaskCandidate(
        replacing,
        AcquisitionCandidate(
          source: 'manual',
          link: selected.link,
          page: selected.link,
          format: file.format,
          fileId: file.id,
          bytes: file.bytes,
          sharedFileName: file.name,
        ),
        code: code,
        baiduAccessToken: access.token,
        pdfPassword: pdf,
      );
      _passwords.remove(task);
    }
    if (mounted &&
        file.format == PublicationFormat.zip &&
        (selected.zipPassword != null || selected.pdfPassword != null)) {
      _passwords[task] = (zip: selected.zipPassword, pdf: selected.pdfPassword);
    }
  }

  Future<List<PublicationSharedFile>?> _inspectShare(
    Uri link,
    Future<List<PublicationSharedFile>> Function(String?, CancellationToken)
    inspect,
    String? code,
    ValueChanged<String> onCode,
  ) async {
    var supplied = code;
    while (mounted) {
      final token = _shareInspection = CancellationToken();
      setState(() => _activeLabel = '正在读取 ${link.host} 的分享文件');
      try {
        final files = await withPublicationRequestDeadline(
          token,
          const Duration(seconds: 32),
          (request) => inspect(supplied, request),
        );
        token.check();
        if (files.isEmpty) {
          throw const FormatException('分享中没有可导入的电子书或 ZIP');
        }
        final allowed = files
            .where((file) => _module.library.policy.textAllowed(file.name))
            .toList();
        if (allowed.isEmpty) {
          throw const PublicationFailure(PublicationProblem.blocked);
        }
        return allowed;
      } on PublicationFailure catch (error) {
        if (!mounted) rethrow;
        if (error.problem != PublicationProblem.shareCode) {
          await showBaiduTokenGuideOnce(
            context,
            _module,
            link,
            error.problem,
            visible: () => widget.visible && _resumed,
          );
          rethrow;
        }
        supplied = await publicationPrompt(context, '输入分享提取码', password: true);
        if (supplied == null) return null;
        onCode(supplied);
      } finally {
        if (mounted && identical(_shareInspection, token)) {
          setState(() => _shareInspection = null);
        }
      }
    }
    return null;
  }

  Future<void> _finish(
    AcquisitionTask task, {
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
    await _withPdfPassword(finish, initial: pdf);
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
        bothEdges: true,
        builder: (_) => RichReaderPage(
          repository: widget.books,
          book: document.book,
          file: document.file,
          platform: widget.platform,
          document: access,
          preparedSections: document.admission.richSections,
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
      case 'group':
        await _moveToGroup(item);
      case 'finished':
        await _module.collections.setFinished(item, !item.finished);
      case 'delete':
        if (await confirmPublicationDelete(context, '删除本地副本', '书目、进度和笔记会保留。')) {
          await _module.library.deleteFile(item);
        }
      case 'remove':
        if (!await confirmPublicationDelete(
              context,
              '从书库移除《${item.edition.title}》？',
              '本地文件、阅读进度和笔记会保留。',
              action: '移除书目',
            ) ||
            !mounted) {
          return;
        }
        await _module.library.remove(item);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('已从书库移除'),
              action: SnackBarAction(
                label: '撤销',
                onPressed: () =>
                    _run(() => _module.library.restoreRemoved(item)),
              ),
            ),
          );
        }
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

  Future<void> _moveToGroup(PublicationHolding item) async {
    final group = await choosePublicationValue(
      context,
      '移动到分组',
      [(id: '', name: '未分组'), ..._groups],
      (group) => group.name,
      confirmSingle: true,
    );
    if (group != null) {
      await _module.collections.move(item, group.id.isEmpty ? null : group);
    }
  }

  Future<void> _manageGroups() async {
    final group = await choosePublicationValue(
      context,
      '管理书库分组',
      [(id: '', name: '新建分组'), ..._groups],
      (group) => group.name,
      confirmSingle: true,
    );
    if (!mounted || group == null) return;
    final existing = group.id.isNotEmpty;
    if (existing) {
      final action = await choosePublicationValue(context, group.name, [
        '重命名',
        '删除分组',
      ], (action) => action);
      if (!mounted || action == null) return;
      if (action == '删除分组') {
        if (await confirmPublicationDelete(
          context,
          '删除分组「${group.name}」？',
          '组内图书会移到未分组。',
        )) {
          await _module.collections.deleteGroup(group);
        }
        return;
      }
    }
    final name = await publicationPrompt(
      context,
      existing ? '重命名分组' : '新建分组',
      initial: existing ? group.name : '',
      limit: 100,
    );
    if (name != null) {
      await _module.collections.saveGroup(name, id: existing ? group.id : null);
    }
  }

  Future<void> _showBookLists() async {
    final book = await Navigator.of(context, rootNavigator: true).push(
      BookPageRoute<PublicationEdition>(
        bothEdges: true,
        builder: (_) => PublicationBookListsPage(
          module: _module,
          onPage: (uri) async {
            try {
              await _origin(uri);
            } catch (error) {
              _notice(_message(error));
            }
          },
        ),
      ),
    );
    if (!mounted || book == null) return;
    setState(() {
      _channelRequest = null;
      _discoveryRequest = (book, ++_discoverySearchSerial);
    });
    _openTab(0);
  }

  Future<void> _addToList(PublicationEdition book) async {
    final lists = await _module.collections.lists();
    if (!mounted) return;
    if (lists.isEmpty) {
      final name = await publicationPrompt(context, '新建书单并添加图书', limit: 100);
      if (name == null) return;
      await _module.collections.createList(name, books: [book]);
    } else {
      final list = await choosePublicationValue(
        context,
        '添加到书单',
        lists,
        (item) => item.name,
        confirmSingle: true,
      );
      if (list == null) return;
      await _module.collections.add(list, book);
    }
    _notice('已添加到书单');
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
    final action = await choosePublicationValue(
      context,
      copy.edition.title,
      const ['恢复到书库', '删除本地副本'],
      (action) => action,
    );
    if (!mounted || action == null) return;
    if (action == '恢复到书库') {
      await _module.library.restoreRemoved(copy);
      _notice('已恢复到书库');
      return;
    }
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
        await retryPublicationDownload(context, _module.workflow, task);
      case 'chooseFile':
        await _chooseTaskShare(task);
      case 'replace':
        await _share(replacing: task);
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
      case 'browserDownload':
        if (_kgbookBrowserPage(task) case final Uri page) {
          await _openPublishedLink(
            PublicationResource(
              source: kgbookSource,
              link: page,
              label: '苦瓜书盘',
            ),
            '${task.edition.title} ${task.edition.author} ${page.host}',
          );
        }
      case 'importBrowserDownload':
        if (_kgbookBrowserPage(task) != null) await _importLocal();
      case 'website':
        final website = _websiteTask(task);
        if (website != null) await _website(website);
      case 'browser':
        final candidate = task.candidate;
        await _openPublishedLink(
          PublicationResource(
            source: candidate.source,
            link: candidate.link,
            label: '网盘分享',
            code: candidate.publishedAccess?.code,
          ),
          '${task.edition.title} ${task.edition.author} ${candidate.link.host}',
        );
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
    final selection = await _selectSourceFile(selected);
    if (!mounted || selection == null) return;
    final access = await choosePublicationDownloadAccess(
      context,
      selected.link,
    );
    if (!mounted || access == null) return;
    await _module.workflow.replaceTaskCandidate(
      task,
      selected.withSharedFile(selection.file),
      code: selection.code,
      baiduAccessToken: access.token,
    );
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
        final page = item.source.website ?? item.source.endpoint;
        _module.library.requireImport('${item.source.name} ${page.host}');
        await _origin(page);
      case 'remove':
        if (!await confirmPublicationDelete(
              context,
              '移除书源「${item.source.name}」？',
              '自定义规则将被移除。可先取消并从书源菜单导出规则。',
              action: '移除书源',
            ) ||
            !mounted) {
          return;
        }
        await _module.discovery.remove(item.source);
      case 'edit':
        await _sourceConfig(item.source);
      case 'export':
        await _module.output.exportRule(item.source);
    }
  }

  Future<void> _manageSources(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) await _refreshSources();
    } catch (error) {
      _notice(_message(error));
    }
  }

  Future<void> _toggleSources(List<PublicationSource> sources, bool enabled) =>
      _manageSources(() async {
        await _module.discovery.setEnabledBatch(sources, enabled);
        if (enabled) _checkSources();
      });

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
    if (mib == null || mib < 64 || mib > 65536) {
      throw const FormatException('请输入 64 至 65536 之间的整数容量（MiB）');
    }
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
    if (initial == null) _notice('书源已保存，可在书源列表中启用');
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
    final backupService = _module.output.backup;
    Future<void> restore(File file) async {
      final summary = await backupService.restoreWithSummary(file);
      _notice(
        '新增 ${summary.added} 条 · 已有 ${summary.existing} 条 · 缺少本地文件 ${summary.missing} 条',
      );
    }

    if (_module.workflow.android) {
      await _module.workflow.withAndroidDocument(
        (document) => restore(document.file),
        backup: true,
      );
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
    await restore(File(backup.path));
  }

  void _taskAdded() => _notice(
    '图书下载任务已创建',
    action: SnackBarAction(label: '查看任务', onPressed: () => _openTab(2)),
  );

  void _notice(String message, {SnackBarAction? action}) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message), action: action));
    }
  }

  String _message(Object error) => switch (error) {
    PublicationFailure(:final problem, spaceShortfall: final info?) =>
      '${problem.label}\n${publicationSpaceDetails(info)}',
    PublicationFailure(:final problem) => problem.label,
    FormatException(:final message) => message.toString(),
    TimeoutException() => PublicationProblem.timeout.label,
    SocketException() || HttpException() => PublicationProblem.network.label,
    FileSystemException() || PlatformException() => '文件或目录暂不可用',
    _ => '图书操作未完成，请重试',
  };

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop:
        !widget.visible ||
        (widget.onBack == null &&
            _tabIndex == 0 &&
            _catalog.currentState?.hasHistory != true),
    onPopInvokedWithResult: (popped, _) {
      if (!popped && widget.visible) _back();
    },
    child: BookBackGesture(onBack: _back, child: _body()),
  );

  Widget _body() {
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
            Row(
              children: [
                if (widget.onBack != null)
                  IconButton(
                    tooltip: '返回上一级',
                    onPressed: _back,
                    icon: const BackButtonIcon(),
                  ),
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    tabs: const [
                      Tab(text: '发现'),
                      Tab(text: '书库'),
                      Tab(text: '任务'),
                      Tab(text: '书源'),
                    ],
                  ),
                ),
              ],
            ),
            if (_active) ...[
              const LinearProgressIndicator(minHeight: 2),
              if (_activeLabel case final label?)
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          semanticsLabel: label,
                        ),
                      ),
                    ),
                    if (_shareInspection case final token?)
                      TextButton(
                        onPressed: token.cancel,
                        child: const Text('取消'),
                      ),
                  ],
                ),
            ],
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _discoverTab(),
                  PublicationShelfView(
                    entries: _holdings,
                    hiddenCount: _hiddenHoldings,
                    open: (item) => _run(() => _read(item)),
                    action: (item, action) =>
                        _run(() => _shelfAction(item, action)),
                    onLocal: () => _run(_importLocal),
                    onLegacy: () => _run(_addLegacy),
                    onUnlisted: () => _run(_unlistedCopies),
                    exportBackup: () => _run(_module.output.exportBackup),
                    restoreBackup: () => _run(_restoreBackup),
                    groups: _groups,
                    onGroups: () => _run(_manageGroups),
                    onLists: () => _run(_showBookLists),
                  ),
                  PublicationTasksView(
                    tasks: _tasks,
                    hiddenCount: _hiddenTasks,
                    websiteAvailable: (task) => _websiteTask(task) != null,
                    browserDownloadAvailable: (task) =>
                        _kgbookBrowserPage(task) != null,
                    action: (task, action) {
                      if (action == 'cancelImport') {
                        if (!_module.workflow.cancelImport(task)) {
                          unawaited(_refresh());
                        }
                        return;
                      }
                      unawaited(_run(() => _taskAction(task, action)));
                    },
                  ),
                  PublicationSourcesView(
                    sources: _sources,
                    onGroups: () => _run(_manageChannelGroups),
                    onBrowse: _enterChannel,
                    onAccounts: _module.discovery.allowed('')
                        ? () => _run(
                            () => showPublicationWebsiteAccounts(
                              context,
                              _module.websites,
                            ),
                          )
                        : null,
                    manageable: _module.discovery.manageable,
                    action: (item, action) =>
                        _manageSources(() => _sourceAction(item, action)),
                    toggle: (item, enabled) =>
                        _toggleSources([item.source], enabled),
                    batchToggle: _toggleSources,
                    batchCheck: (sources) => _manageSources(
                      () => _module.discovery.checkBatch(sources),
                    ),
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

  Future<void> _readOnline(PublicationEdition book) async {
    final page = book.page;
    if (page == null || publicationBookStackId(page) == null) return;
    _module.library.requireImport('${book.title} ${book.author}');
    await Navigator.of(context).push<void>(
      BookPageRoute<void>(
        builder: (_) => PublicationBookStackPage(
          module: _module,
          title: book.title,
          page: page,
          openOriginal: (uri) => unawaited(
            _origin(uri).catchError((Object error) {
              if (mounted) _notice(_message(error));
            }),
          ),
        ),
      ),
    );
  }

  Widget _discoverTab() => PublicationCatalogView(
    key: _catalog,
    module: _module,
    sources: _sources,
    visible: widget.visible && _resumed && _tabIndex == 0,
    policyRevision: _policyRevision,
    searchRequest: _discoveryRequest,
    channelRequest: _channelRequest,
    channelGroups: _channelGroups,
    onManageGroups: () => _run(_manageChannelGroups),
    onReadOnline: (book) => _run(() => _readOnline(book)),
    isLocal: (book, format) => _localEdition(book, format) != null,
    onLists: () => _run(_showBookLists),
    onAddToList: (book) => _run(() => _addToList(book)),
    onManage: () => _openTab(3),
    onBuy: (book, format, alternatives) => _run(
      () => _buy(book, format, alternatives: alternatives),
      label: '正在准备 ${format.label}',
    ),
    onShare: () => _run(_share, label: '正在处理图书分享'),
    onResource: (book, resource, external) => _run(
      () => _openResource(book, resource, external),
      label: '正在处理 ${resource.label}',
    ),
    onLocal: () => _run(_importLocal),
    onPage: (uri) => _run(() => _origin(uri)),
  );

  @override
  void dispose() {
    _shareInspection?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _module.policy.removeListener(_policyChanged);
    _module.legacy.vault.removeListener(_policyChanged);
    _poll?.cancel();
    unawaited(_sourceChanges.cancel());
    unawaited(_taskChanges.cancel());
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    super.dispose();
  }
}
