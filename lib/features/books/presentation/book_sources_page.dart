import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../app/app_services.dart';
import '../../../core/network/cancellation_token.dart';
import '../../../core/network/document_client.dart';
import '../../supervision/domain/adult_source_evidence.dart';
import '../../supervision/presentation/sensitive_action.dart';
import '../application/book_site_checks.dart';
import '../data/aoaostar_book_catalog.dart';
import '../data/book_import.dart';
import '../data/book_site_inspection.dart';
import '../data/book_site_script_clues.dart';
import '../data/book_source_risk_store.dart';
import '../data/book_store.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';
import '../domain/book_rule_clues.dart';
import '../domain/book_site_audit_clues.dart';
import 'book_links.dart';

enum _SourceAction { catalog, file, link, feed }

final class BookSourcesPage extends StatefulWidget {
  const BookSourcesPage({
    super.key,
    required this.services,
    required this.kind,
    this.afterSourceReadForTesting,
  });
  final AppServices services;
  final BookKind kind;

  /// Allows a test to change policy or source metadata between reads.
  @visibleForTesting
  final Future<void> Function()? afterSourceReadForTesting;
  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

final class _BookSourcesPageState extends State<BookSourcesPage> {
  List<BookSourceEntry> _entries = [];
  bool _busy = false, _favorites = false, _dynamicRules = false;
  bool _historicalAmsi = false, _pageScriptClues = false;
  bool? _enabled;
  String _query = '';
  bool _selecting = false;
  final _selected = <String>{};
  CancellationToken? _token;
  late final BookSiteChecks _siteChecks;
  late String _sitePolicySnapshot;
  Map<String, BookSiteCheck> _siteResults = {};
  String? _siteProgress;
  late final StreamSubscription<void> _sourceChanges;
  Timer? _sourceRefresh;
  int _sourceRevision = 0;
  AppServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _siteChecks = _services.bookSiteChecks;
    _sitePolicySnapshot = bookSitePolicySnapshot(_services.contentPolicy);
    _services.contentPolicy.addListener(_policyChanged);
    _services.books.sourceRiskChanges.addListener(_policyChanged);
    _sourceChanges = _services.books.store.db
        .changesFor(const {'app_meta'})
        .listen((_) => _dataChanged());
    _run(_services.books.ensureCatalog);
  }

  @override
  void dispose() {
    _token?.cancel();
    _sourceRefresh?.cancel();
    unawaited(_sourceChanges.cancel());
    _services.contentPolicy.removeListener(_policyChanged);
    _services.books.sourceRiskChanges.removeListener(_policyChanged);
    super.dispose();
  }

  void _policyChanged() {
    _sourceRevision++;
    final next = bookSitePolicySnapshot(_services.contentPolicy);
    if (next != _sitePolicySnapshot) _token?.cancel();
    _sitePolicySnapshot = next;
    setState(() {
      _entries = [];
      _siteResults = {};
      _selected.clear();
    });
    if (!_busy) _queueRefresh();
  }

  void _dataChanged() {
    _sourceRevision++;
    if (mounted && !_busy) _queueRefresh();
  }

  void _queueRefresh() {
    if (_sourceRefresh != null) return;
    _sourceRefresh = Timer(const Duration(milliseconds: 100), () {
      _sourceRefresh = null;
      if (mounted && !_busy) _run(() async {});
    });
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool protected = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (protected) {
        await runSensitive(
          context,
          _services.supervision,
          SensitiveOperation.channels,
          action,
        );
      } else {
        await action();
      }
    } on FormatException catch (error) {
      _notice(error.message);
    } on RemoteFailure catch (error) {
      _notice(error.message);
    } catch (_) {
      _notice('操作未完成，请重试');
    } finally {
      try {
        await _reloadSources();
      } catch (_) {
        _notice('无法读取来源清单');
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reloadSources() async {
    for (var attempt = 0; attempt < 4 && mounted; attempt++) {
      final revision = _sourceRevision;
      final policy = bookSitePolicySnapshot(_services.contentPolicy);
      final entries = await _services.books.sources(widget.kind);
      await widget.afterSourceReadForTesting?.call();
      final siteResults = await _siteChecks.load(entries);
      final latest = await _services.books.sources(widget.kind);
      if (!mounted) return;
      if (revision != _sourceRevision ||
          policy != bookSitePolicySnapshot(_services.contentPolicy) ||
          !_sameEntries(entries, latest)) {
        continue;
      }
      // No asynchronous work between the final policy check and setState.
      final allowed = latest.where(_services.books.sourceEntryAllowed).toList();
      setState(() {
        _entries = allowed;
        _siteResults = siteResults;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _entries = [];
        _siteResults = {};
      });
      _queueRefresh();
    }
  }

  bool _sameEntries(List<BookSourceEntry> first, List<BookSourceEntry> second) {
    if (first.length != second.length) return false;
    String signature(BookSourceEntry entry) => jsonEncode([
      entry.source.toJson(),
      entry.source.builtin,
      entry.enabled,
      entry.favorite,
      entry.group,
      entry.health,
      entry.checkedAt,
      entry.subscriptionId,
      entry.fromCatalog,
    ]);
    final previous = {
      for (final entry in first) entry.source.id: signature(entry),
    };
    return second.every(
      (entry) => previous[entry.source.id] == signature(entry),
    );
  }

  Future<String?> _prompt(
    String label, {
    String initial = '',
    int limit = 80,
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextFormField(
          initialValue: initial,
          maxLength: limit,
          autofocus: true,
          onChanged: (text) => value = text,
          onFieldSubmitted: (text) => Navigator.pop(context, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _import() => _run(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Legado 书源或备份',
          extensions: ['json', 'txt', 'zip'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    final token = _token = CancellationToken();
    final path = file.path;
    final parsed = await readBookSourceFile(path);
    token.check();
    if (!mounted) return;
    final result = await _services.books.importSources(
      parsed.sources,
      token: token,
    );
    _importNotice(parsed, result);
  }, protected: true);

  Future<void> _importAddress() async {
    final address = await _prompt('Legado 导入链接、来源 JSON 或源仓库详情页', limit: 4096);
    if (!mounted || address == null || address.isEmpty) return;
    final url = Uri.tryParse(address);
    if (url != null &&
        url.scheme == 'https' &&
        url.userInfo.isEmpty &&
        ((url.host == 'github.com' &&
                const {
                  '/aoaostar/legado',
                  '/aoaostar/legado/',
                  '/aoaostar/legado/tree/release',
                }.contains(url.path)) ||
            (url.host == 'legado.aoaostar.com' &&
                const {'', '/'}.contains(url.path)))) {
      await _importCatalog();
      return;
    }
    await _subscribe(address);
  }

  Future<void> _importCatalog() => _run(() async {
    final catalog = await AoaoStarBookCatalog.load();
    if (!mounted) return;
    final packId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('aoaostar/legado 书源包'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('书源包随应用提供。新增渠道默认停用，可检测后启用。'),
                const Divider(),
                for (final pack in catalog.packs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(pack.name),
                    subtitle: Text('${pack.count} 条原始记录'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, pack.id),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'all'),
            child: Text('导入全部 ${catalog.packs.length} 包'),
          ),
        ],
      ),
    );
    if (!mounted || packId == null) return;
    final token = _token = CancellationToken();
    setState(() {});
    try {
      final result = await _services.books.importCatalog(
        catalog,
        token,
        packId: packId == 'all' ? null : packId,
      );
      _importNotice(result.parsed, result.changes);
    } finally {
      setStateIfMounted(() => _token = null);
    }
  }, protected: true);

  Future<void> _subscribe(String address) => _run(() async {
    final token = _token = CancellationToken();
    setStateIfMounted(() {});
    try {
      final result = await _services.books.subscribe(address, token);
      _importNotice(result.parsed, result.changes);
    } finally {
      setStateIfMounted(() => _token = null);
    }
  }, protected: true);

  void _importNotice(BookSourceImport parsed, BookImportChanges changes) {
    _notice(
      [
        '新增 ${changes.added}',
        if (changes.updated > 0) '更新 ${changes.updated}',
        '重复 ${changes.duplicates + parsed.duplicates}',
        if (parsed.rejected > 0) '不兼容 ${parsed.rejected}${parsed.issueSummary}',
        if (changes.skipped > 0) '受黑名单、内容策略或容量限制 ${changes.skipped}',
      ].join('，'),
    );
  }

  Future<void> _subscriptions() async {
    final entries = await _services.books.subscriptions();
    if (!mounted) return;
    final choice =
        await showDialog<({BookSourceSubscription entry, bool refresh})>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('书源订阅'),
            content: SizedBox(
              width: 520,
              height: 280,
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  _services.contentPolicy,
                  _services.books.sourceRiskChanges,
                ]),
                builder: (context, _) {
                  final policy = _services.contentPolicy;
                  final shown =
                      !_services.books.sourceRisksReady ||
                          policy.supervision.enabled ||
                          policy.supervision.corrupted
                      ? <BookSourceSubscription>[]
                      : entries
                            .where(
                              (entry) =>
                                  policy.textAllowed(
                                    '${entry.url.host} ${entry.url.path}',
                                  ) &&
                                  !(policy.filterAdult &&
                                      knownAdultHost(entry.url.host)),
                            )
                            .toList();
                  if (shown.isEmpty) {
                    return const Center(child: Text('没有可显示的订阅链接'));
                  }
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final entry = shown[index];
                      return ListTile(
                        title: Text(entry.url.host),
                        subtitle: Text(
                          '${entry.url.path}\n最近核对 ${entry.count} 个源',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<bool>(
                          tooltip: '订阅操作',
                          onSelected: (refresh) => Navigator.pop(context, (
                            entry: entry,
                            refresh: refresh,
                          )),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: true, child: Text('刷新订阅')),
                            PopupMenuItem(value: false, child: Text('移除订阅链接')),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
    if (!mounted || choice == null) return;
    if (choice.refresh) {
      await _subscribe(choice.entry.url.toString());
    } else {
      await _run(
        () => _services.books.removeSubscription(choice.entry),
        protected: true,
      );
    }
  }

  Future<void> _addFeed() async {
    final url = await _prompt('RSS / Atom 地址', limit: 2048);
    if (!mounted || url == null || url.isEmpty) return;
    final name = await _prompt('订阅名称');
    if (!mounted || name == null || name.isEmpty) return;
    final host = widget.kind == BookKind.audio
        ? await _prompt('音频 CDN 域名（同站可留空）', limit: 250)
        : '';
    if (!mounted || host == null) return;
    await _run(() async {
      final source = BookSource.fromJson({
        'name': name,
        'url': url,
        'kind': widget.kind.name,
        'format': 'feed',
        'group': '订阅',
        if (host.isNotEmpty) 'mediaHosts': [host],
      });
      final result = await _services.books.importSources([source]);
      _notice(
        result.added == 1
            ? '已添加，请检测后启用'
            : result.duplicates == 1
            ? '已有该订阅'
            : '该来源受内容策略限制',
      );
    }, protected: true);
  }

  Future<void> _probe(BookSource source) async {
    final query = source.format == BookFormat.feed
        ? ''
        : await _prompt('检测用书名', initial: source.sample);
    if (!mounted || query == null) return;
    await _run(() async {
      final token = _token = CancellationToken();
      try {
        await _services.books.probe(source, query, token);
      } finally {
        if (identical(token, _token)) setStateIfMounted(() => _token = null);
      }
    }, protected: true);
  }

  Future<void> _scanSites(List<BookSourceEntry> entries) => _run(() async {
    final token = _token = CancellationToken();
    setStateIfMounted(() => _siteProgress = '网页抽查 0 / ${entries.length}');
    try {
      final summary = await _services.bookSiteMonitor.whileManual(
        token,
        () => _siteChecks.run(
          entries,
          token,
          onProgress: (checked, total) =>
              setStateIfMounted(() => _siteProgress = '网页抽查 $checked / $total'),
        ),
      );
      _notice(
        '网页抽查 ${summary.checked} 项，博彩强线索隔离 ${summary.quarantined} 项，'
        '成人强线索标记 ${summary.adult} 项；跳过 ${summary.skipped} 项，'
        '未完成 ${summary.failed} 项，其余仍需人工复核',
      );
    } on RequestCancelled {
      _notice('网页抽查已取消或因策略变化中止，已完成的结果和风险记录保留');
    } finally {
      if (identical(token, _token)) {
        setStateIfMounted(() {
          _token = null;
          _siteProgress = null;
        });
      }
    }
  }, protected: true);

  Future<void> _scanVisibleSites() async {
    final entries = _selecting
        ? _entries
              .where((entry) => _selected.contains(entry.source.id))
              .toList()
        : _visibleEntries();
    if (entries.isEmpty) {
      _notice('没有可检查的来源');
      return;
    }
    if (entries.length > 100) _notice('本次最多检查 100 项，请缩小筛选范围继续');
    await _scanSites(entries.take(100).toList());
  }

  Future<void> _sourceRisks() => _run(() async {
    final risks = await _services.books.sourceRiskEntries();
    if (!mounted) return;
    final selected = await showDialog<BookSourceRiskEntry>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('风险记录'),
        content: SizedBox(
          width: 520,
          height: 300,
          child: Column(
            children: [
              const Text('列表受当前内容策略限制；同域关联项请复核产生记录的来源。'),
              const SizedBox(height: 8),
              Expanded(
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    _services.contentPolicy,
                    _services.books.sourceRiskChanges,
                  ]),
                  builder: (context, _) {
                    final shown = risks
                        .where(_services.books.sourceRiskEntryAllowed)
                        .toList();
                    if (shown.isEmpty) {
                      return const Center(child: Text('没有可显示的风险记录'));
                    }
                    return ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, index) {
                        final risk = shown[index];
                        return ListTile(
                          title: Text(risk.name),
                          subtitle: Text(
                            [
                              risk.host,
                              if (risk.adult) '成人线索',
                              if (risk.quarantined) '已隔离',
                              if (risk.fixedQuarantine) '内置隔离',
                            ].join(' · '),
                          ),
                          trailing: risk.fixedQuarantine || risk.version <= 0
                              ? null
                              : TextButton(
                                  onPressed: () => Navigator.pop(context, risk),
                                  child: const Text('人工复核'),
                                ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除风险记录'),
        content: const Text('请在安全环境中人工复核后再解除。解除后，同域历史书籍和来源可能重新可用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认解除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _services.books.clearSourceRisk(selected);
      _notice('已解除该条风险记录；其他同域记录仍可能生效');
    }
  }, protected: true);

  void setStateIfMounted(VoidCallback update) {
    if (mounted) setState(update);
  }

  Future<void> _blacklist() async {
    final blocked = await _services.books.store.blockedSources();
    if (!mounted) return;
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('书源黑名单'),
        content: SizedBox(
          width: 440,
          height: 280,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              _services.contentPolicy,
              _services.books.sourceRiskChanges,
            ]),
            builder: (context, _) {
              final policy = _services.contentPolicy;
              final shown =
                  !_services.books.sourceRisksReady ||
                      policy.supervision.enabled ||
                      policy.supervision.corrupted
                  ? <MapEntry<String, String>>[]
                  : blocked.entries
                        .where((entry) => policy.textAllowed(entry.value))
                        .toList();
              if (shown.isEmpty) return const Center(child: Text('暂无可显示的屏蔽书源'));
              return ListView(
                children: [
                  for (final entry in shown)
                    ListTile(
                      title: Text(entry.value),
                      trailing: TextButton(
                        onPressed: () => Navigator.pop(context, entry.key),
                        child: const Text('解除屏蔽'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (mounted && id != null) {
      await _run(() => _services.books.unblockSource(id), protected: true);
    }
  }

  Future<void> _batch(bool enabled) async {
    final ids = Set<String>.of(_selected);
    await _run(() async {
      await _services.books.setSourcesEnabled(widget.kind, ids, enabled);
      setStateIfMounted(() {
        _selected.clear();
        _selecting = false;
      });
    }, protected: true);
  }

  Widget _selectionTools(List<BookSourceEntry> visible) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Wrap(
      spacing: 8,
      children: [
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _selected.addAll(visible.map((entry) => entry.source.id));
                }),
          child: const Text('全选筛选结果'),
        ),
        TextButton(
          onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
          child: Text('清空 ${_selected.length} 项'),
        ),
        TextButton(
          onPressed: _busy || _selected.isEmpty ? null : () => _batch(true),
          child: const Text('一键启用'),
        ),
        TextButton(
          onPressed: _busy || _selected.isEmpty ? null : () => _batch(false),
          child: const Text('一键停用'),
        ),
      ],
    ),
  );

  Widget _restoreControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        children: [
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    () => _services.books.restoreDefaultSources(widget.kind),
                    protected: true,
                  ),
            icon: const Icon(Icons.restore),
            label: const Text('一键还原默认渠道'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _scanVisibleSites,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('网页抽查'),
          ),
          TextButton.icon(
            onPressed: _busy || _services.supervision.enabled
                ? null
                : _sourceRisks,
            icon: const Icon(Icons.gpp_maybe_outlined),
            label: const Text('风险记录'),
          ),
        ],
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '启用后台检测时，每 30 分钟抽查最多 20 个已启用源；'
          '已采样页面 7 天复查；未确认结果的重试间隔从 30 分钟递增至 24 小时，排队可能更久。'
          '监管期间仅检查策略允许的可信内置文字源，不检查外部书源。'
          '只查首页部分静态文字、跳转和内联脚本写法，不执行网页脚本，也不验证解析、木马或安全性。'
          '网页脚本线索、来源规则“动态求值”和历史检出仅供复核，不代表恶意或安全。',
        ),
      ),
    ],
  );

  List<BookSourceEntry> _visibleEntries() {
    final query = _query.trim().toLowerCase();
    final list =
        _entries
            .where(
              (entry) =>
                  (!_favorites || entry.favorite) &&
                  (!_dynamicRules || bookSourceHasDynamicCode(entry.source)) &&
                  (!_pageScriptClues ||
                      _siteResults[entry.source.id]
                              ?.pendingScriptClues
                              .isNotEmpty ==
                          true) &&
                  (!_historicalAmsi ||
                      bookSourceHasHistoricalAmsiClue(entry.source)) &&
                  (_enabled == null || entry.enabled == _enabled) &&
                  '${entry.source.name} ${entry.group} ${entry.source.endpoint.host}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort((a, b) {
            if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
            if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
            return a.source.name.compareTo(b.source.name);
          });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final list = _visibleEntries();
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (widget.kind) {
          BookKind.text => '网络小说渠道',
          BookKind.audio => '听书源',
          BookKind.comic => '网络漫画渠道',
        }),
        actions: [
          IconButton(
            tooltip: _selecting ? '退出批量选择' : '批量选择',
            icon: Icon(_selecting ? Icons.close : Icons.checklist),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _selecting = !_selecting;
                    _selected.clear();
                  }),
          ),
          IconButton(
            tooltip: '书源黑名单',
            icon: const Icon(Icons.block),
            onPressed: _busy || _services.supervision.enabled
                ? null
                : _blacklist,
          ),
          if (_token != null)
            IconButton(
              tooltip: '取消操作',
              onPressed: () => _token?.cancel(),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          PopupMenuButton<_SourceAction>(
            tooltip: '导入书源',
            enabled: !_busy,
            icon: const Icon(Icons.add),
            onSelected: (action) => switch (action) {
              _SourceAction.catalog => _importCatalog(),
              _SourceAction.file => _import(),
              _SourceAction.link => _importAddress(),
              _SourceAction.feed => _addFeed(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _SourceAction.catalog,
                child: Text('内置 Legado 书源包'),
              ),
              const PopupMenuItem(
                value: _SourceAction.file,
                child: Text('导入来源文件'),
              ),
              const PopupMenuItem(
                value: _SourceAction.link,
                child: Text('导入 Legado 链接'),
              ),
              if (widget.kind != BookKind.comic)
                const PopupMenuItem(
                  value: _SourceAction.feed,
                  child: Text('添加 RSS / Atom'),
                ),
            ],
          ),
          IconButton(
            tooltip: '管理书源订阅',
            onPressed: _busy ? null : _subscriptions,
            icon: const Icon(Icons.subscriptions_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_siteProgress != null) Text(_siteProgress!),
          _restoreControls(),
          _filters(),
          if (_selecting) _selectionTools(list),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('没有符合条件的来源'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, index) => _tile(list[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filters() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            hintText: '筛选名称、分组或域名',
            prefixIcon: const Icon(Icons.filter_alt_outlined),
            suffixIcon: IconButton(
              tooltip: '仅收藏源',
              isSelected: _favorites,
              onPressed: () => setState(() => _favorites = !_favorites),
              icon: const Icon(Icons.star_outline),
              selectedIcon: const Icon(Icons.star),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            for (final (value, label) in const [
              (null, '全部'),
              (true, '已启用'),
              (false, '已停用'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _enabled == value,
                onSelected: (_) => setState(() => _enabled = value),
              ),
            FilterChip(
              label: const Text('动态求值'),
              selected: _dynamicRules,
              onSelected: (value) => setState(() => _dynamicRules = value),
            ),
            FilterChip(
              label: const Text('网页脚本线索'),
              selected: _pageScriptClues,
              onSelected: (value) => setState(() => _pageScriptClues = value),
            ),
            FilterChip(
              label: const Text('历史检出'),
              selected: _historicalAmsi,
              onSelected: (value) => setState(() => _historicalAmsi = value),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _sourceActions(BookSourceEntry entry) {
    final source = entry.source;
    return PopupMenuButton<String>(
      tooltip: '来源操作',
      enabled: !_busy,
      onSelected: (value) async {
        switch (value) {
          case 'copy':
            await copyBookLink(context, source.endpoint);
          case 'probe':
            await _probe(source);
          case 'group':
            final group = await _prompt(
              '分组名称',
              initial: entry.group,
              limit: 60,
            );
            if (mounted && group != null) {
              await _run(
                () => _services.books.saveSource(source, {'group': group}),
                protected: true,
              );
            }
          case 'remove':
            await _run(
              () => _services.books.removeSource(source),
              protected: true,
            );
          case 'block':
            await _run(
              () => _services.books.blockSource(source),
              protected: true,
            );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copy', child: Text('复制渠道链接')),
        const PopupMenuItem(value: 'probe', child: Text('解析检测（执行来源规则）')),
        const PopupMenuItem(value: 'group', child: Text('修改分组')),
        const PopupMenuItem(value: 'remove', child: Text('删除书源')),
        const PopupMenuItem(value: 'block', child: Text('屏蔽并加入黑名单')),
      ],
    );
  }

  Widget _tile(BookSourceEntry entry) {
    final source = entry.source;
    final siteCheck = _siteResults[source.id];
    if (_selecting) {
      return CheckboxListTile(
        value: _selected.contains(source.id),
        title: Text(source.name),
        subtitle: Text(
          '${entry.enabled ? '已启用' : '已停用'} · ${source.endpoint.host}',
        ),
        onChanged: _busy
            ? null
            : (value) => setState(() {
                if (value == true) {
                  _selected.add(source.id);
                } else {
                  _selected.remove(source.id);
                }
              }),
      );
    }
    return ListTile(
      leading: IconButton(
        tooltip: entry.favorite ? '取消收藏源' : '收藏源',
        icon: Icon(entry.favorite ? Icons.star : Icons.star_outline),
        onPressed: _busy
            ? null
            : () => _run(
                () => _services.books.saveSource(source, {
                  'favorite': !entry.favorite,
                }),
                protected: true,
              ),
      ),
      title: Text(source.name),
      subtitle: Text(
        [
          if (source.builtin) '内置',
          if (entry.fromCatalog) 'aoaostar/legado',
          if (source.legado != null) 'Legado',
          if (bookSourceHasDynamicCode(source)) '规则含动态求值，待复核',
          if (bookSourceHasHistoricalAmsiClue(source)) '2026-11-15 首页防护检出，待复核',
          if (entry.group.isNotEmpty) entry.group,
          source.endpoint.host,
          if (entry.health.isNotEmpty) '解析：${entry.health}',
          if (siteCheck != null)
            '网页：${siteCheck.inspection.label} · ${siteCheck.inspection.finding == BookSiteFinding.sourceChanged ? '上次检查于 ' : ''}${_siteTime(siteCheck.checkedAt)}${siteCheck.isDue(DateTime.now()) ? '（已过期）' : ''}',
          if (siteCheck != null)
            for (final clue in siteCheck.historicalScriptClues.entries)
              '历史网页脚本待复核：${_scriptClueLabel(clue.key)}（上次发现 ${_siteTime(clue.value)}）',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: entry.enabled,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () =>
                        _services.books.saveSource(source, {'enabled': value}),
                    protected: true,
                  ),
          ),
          _sourceActions(entry),
        ],
      ),
    );
  }

  String _siteTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _scriptClueLabel(BookPageScriptClue clue) => switch (clue) {
    BookPageScriptClue.crossOriginRedirect => '跨源跳转写法',
    BookPageScriptClue.decodedDynamicEvaluation => '解码后动态求值写法',
  };
}
