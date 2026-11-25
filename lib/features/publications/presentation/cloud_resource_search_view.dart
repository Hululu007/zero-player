import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../data/cloud_resource_search.dart';
import '../data/publication_share_provider.dart';
import '../data/publication_store.dart';
import '../domain/publication.dart';
import 'cloud_search_share_preview.dart';
import 'publication_dialogs.dart';

final class CloudResourceSearchView extends StatefulWidget {
  const CloudResourceSearchView({
    super.key,
    required this.search,
    required this.store,
    required this.allowed,
    required this.open,
    required this.parse,
    required this.pasteShare,
    this.inspect,
    this.manageAccounts,
  });

  final CloudResourceSearch search;
  final PublicationStore store;
  final bool Function(String) allowed;
  final void Function(Uri link, String label) open;
  final void Function(Uri link, String? code) parse;
  final VoidCallback pasteShare;
  final VoidCallback? manageAccounts;
  final CloudSearchInspect? inspect;

  @override
  State<CloudResourceSearchView> createState() =>
      _CloudResourceSearchViewState();
}

final class _CloudResourceSearchViewState
    extends State<CloudResourceSearchView> {
  final _input = TextEditingController();
  final _results = <String, Map<String, CloudSearchHit>>{};
  final _errors = <String, String>{};
  CancellationToken? _current;
  String _query = '';
  bool _panHubBrowser = false;
  bool _authenticating = false;
  CloudSearchEngine _engine = CloudSearchEngine.all;
  String? _platform;
  bool _files = false;
  bool _groupByPlatform = true;
  final _collapsed = <(bool, String)>{};
  PanHubCursor? _panHubCursor;
  int _haiSouPage = 1;
  bool _haiSouMore = false;

  bool _includes(CloudSearchEngine engine) =>
      _engine == CloudSearchEngine.all || _engine == engine;

  @override
  void initState() {
    super.initState();
    unawaited(_readDefault());
  }

  @override
  void dispose() {
    _current?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _readDefault() async {
    try {
      final saved = await widget.store.preference(cloudSearchPreference);
      if (mounted && _query.isEmpty && _engine == CloudSearchEngine.all) {
        setState(() => _engine = CloudSearchEngine.fromPreference(saved));
      }
    } on Exception {
      // The aggregate search remains available when preferences cannot be read.
    }
  }

  Future<void> _saveDefault() async {
    try {
      await widget.store.setPreference(cloudSearchPreference, _engine.name);
      if (mounted) _notice('已保存默认搜索工具');
    } on Exception {
      if (mounted) _notice('无法保存默认搜索工具');
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _configureHaiSou() async {
    final key = await publicationPrompt(
      context,
      '设置海搜 API Key',
      instructions: '使用海搜开放接口签发的 Key。Key 只保存在本次运行中。',
      password: true,
      limit: 256,
    );
    if (!mounted || key == null) return;
    try {
      setState(() => widget.search.configureHaiSou(key.trim()));
      if (_input.text.trim().isNotEmpty) unawaited(_load(_input.text));
    } on FormatException catch (error) {
      _notice(error.message);
    }
  }

  Future<void> _load(
    String raw, {
    CloudSearchEngine? more,
    CloudSearchEngine? retry,
  }) async {
    final query = raw.trim();
    if (query.isEmpty || !widget.allowed(query)) return;
    FocusScope.of(context).unfocus();
    _current?.cancel();
    final token = CancellationToken();
    final platform = _platform;
    final files = _files;
    setState(() {
      _current = token;
      _query = query;
      final only = more ?? retry;
      if (only == null) {
        _results.clear();
        _errors.clear();
        _panHubBrowser = false;
        _panHubCursor = null;
        _haiSouPage = 1;
        _haiSouMore = false;
      } else {
        _errors.remove(only.label);
      }
    });
    bool current() =>
        mounted &&
        identical(_current, token) &&
        !token.isCancelled &&
        widget.allowed(query);
    void append(String name, List<CloudSearchHit> rows) {
      if (!current() || rows.isEmpty) return;
      final merged = _results.putIfAbsent(name, () => {});
      var changed = false;
      for (final hit in rows) {
        final key = hit.key;
        final old = merged[key];
        if (old != null && (old.code != null || hit.code == null)) continue;
        merged[key] = hit;
        changed = true;
      }
      if (changed) setState(() {});
    }

    Future<void> source(
      CloudSearchEngine engine,
      Future<List<CloudSearchHit>> Function() request, {
      bool streamed = false,
    }) async {
      final only = more ?? retry;
      if (only == null ? !_includes(engine) : only != engine) return;
      try {
        final rows = await request();
        if (!streamed) append(engine.label, rows);
      } on PanHubBrowserRequired {
        if (current()) setState(() => _panHubBrowser = true);
      } on Exception catch (error) {
        if (current()) {
          setState(
            () => _errors[engine.label] = switch (error) {
              PublicationFailure(:final problem) => problem.label,
              FormatException(:final message) when error.source == null =>
                message,
              _ => '暂时无法读取',
            },
          );
        }
      }
    }

    try {
      await Future.wait([
        source(
          CloudSearchEngine.curated,
          () => widget.search.curated(query, token),
        ),
        source(
          CloudSearchEngine.navigation,
          () => widget.search.navigation(query, token),
        ),
        source(
          CloudSearchEngine.panHub,
          () => widget.search.panHub(
            query,
            token,
            platform: platform,
            cursor: retry == null ? _panHubCursor : null,
            onPartial: (rows) => append(CloudSearchEngine.panHub.label, rows),
            onContinuation: (cursor) {
              if (current()) setState(() => _panHubCursor = cursor);
            },
          ),
          streamed: true,
        ),
        source(
          CloudSearchEngine.panHubPublic,
          () => widget.search.panHubPublic(query, token, platform: platform),
        ),
        if (widget.search.haiSouConfigured ||
            _engine == CloudSearchEngine.haiSou)
          source(CloudSearchEngine.haiSou, () async {
            final next = more == null ? 1 : _haiSouPage + 1;
            final result = await widget.search.haiSou(
              query,
              token,
              platform: platform,
              page: next,
              files: files,
            );
            if (current()) {
              setState(() {
                _haiSouPage = next;
                _haiSouMore = result.more;
              });
            }
            return result.rows;
          }),
      ]);
    } finally {
      if (mounted && identical(_current, token)) {
        setState(() => _current = null);
      }
    }
  }

  void _changeFilters(VoidCallback change) {
    setState(change);
    if (_query.isNotEmpty) unawaited(_load(_query));
  }

  void _cancel() {
    _current?.cancel();
    setState(() => _current = null);
  }

  void _openPanHub() {
    final query = _input.text.trim();
    if (widget.allowed(query)) {
      widget.open(panHubSearchPage(query, platform: _platform), 'PanHub');
    }
  }

  void _openHaiSou() {
    final query = _input.text.trim();
    if (widget.allowed(query)) {
      widget.open(haiSouSearchPage(query), '海搜');
    }
  }

  Future<void> _signInPanHub() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);
    try {
      final code = await publicationPrompt(
        context,
        'PanHub 站方验证',
        instructions: '向微信公众账号「神族九帝」发送「验证码」，输入收到的六位验证码。',
        password: true,
        limit: 6,
      );
      if (code == null || !mounted) return;
      await widget.search.signInPanHub(code);
      if (mounted) unawaited(_load(_input.text));
    } on RequestCancelled {
      return;
    } on Exception catch (error) {
      if (mounted) {
        final message = switch (error) {
          PublicationFailure(:final problem) => problem.label,
          _ => 'PanHub 验证未完成，请核对验证码后重试',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  void _clearPanHub() {
    _current?.cancel();
    widget.search.clearPanHubSession();
    setState(() {
      _current = null;
      _results.remove(CloudSearchEngine.panHub.label);
      _panHubCursor = null;
      _panHubBrowser = true;
    });
  }

  Widget _resultTile(CloudSearchHit hit) {
    final provider = PublicationShareProvider.of(hit.link);
    final parse = hit.reference == null && provider.listsFiles;
    void open() => widget.open(hit.link, hit.title);
    void download() => widget.parse(hit.link, hit.code);
    if (hit.reference == null &&
        provider.previewsFiles &&
        widget.inspect != null) {
      return CloudSearchSharePreview(
        hit: hit,
        inspect: widget.inspect!,
        allowed: widget.allowed,
        download: parse ? download : null,
        open: open,
      );
    }
    return ListTile(
      title: Text(hit.title),
      subtitle: Text(
        hit.reference != null
            ? '${hit.source} · 在原站领取'
            : '${hit.source} · ${hit.link.host}${hit.code == null ? '' : ' · 含提取码'}',
      ),
      trailing: Icon(parse ? Icons.cloud_download_outlined : Icons.open_in_new),
      onTap: parse ? download : open,
    );
  }

  @override
  Widget build(BuildContext context) {
    final unique = <String, CloudSearchHit>{};
    for (final engine in CloudSearchEngine.values.skip(1)) {
      for (final hit
          in _results[engine.label]?.values ?? const <CloudSearchHit>[]) {
        if ((_platform != null && hit.platform != _platform) ||
            !widget.allowed('${hit.title} ${hit.link.host}')) {
          continue;
        }
        final previous = unique[hit.key];
        if (previous == null) {
          unique[hit.key] = hit;
        } else if (previous.code == null && hit.code != null) {
          unique[hit.key] = CloudSearchHit(
            title: previous.title,
            link: previous.link,
            source: previous.source,
            platform: previous.platform,
            reference: previous.reference,
            code: hit.code,
          );
        }
      }
    }
    final results = <String, List<CloudSearchHit>>{};
    for (final hit in unique.values) {
      final group = _groupByPlatform
          ? cloudSearchPlatforms[hit.platform] ?? hit.platform ?? '其他'
          : hit.source;
      (results[group] ??= []).add(hit);
    }
    final rows = <Object>[
      for (final entry in results.entries) ...[
        (name: entry.key, count: entry.value.length),
        if (!_collapsed.contains((_groupByPlatform, entry.key))) ...entry.value,
      ],
    ];
    final rowPositions = <String, int>{
      for (final (index, row) in rows.indexed)
        if (row is CloudSearchHit) row.key: index + 1,
    };
    final websites = [
      (
        '猫狸盘搜',
        Uri.https(
          'www.alipansou.com',
          _query.isEmpty ? '/' : '/search',
          _query.isEmpty ? null : {'k': _query},
        ),
      ),
      ('爱网盘', Uri.https('www.iwangpan.cc', '/')),
      ('大力盘', Uri.https('www.dalipan.com', '/')),
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: rows.length + 2,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? rowPositions[key.value] : null,
      itemBuilder: (context, index) {
        if (index == rows.length + 1 && _current == null) {
          return Wrap(
            spacing: 8,
            children: [
              if (_panHubCursor != null)
                OutlinedButton(
                  onPressed: () =>
                      _load(_query, more: CloudSearchEngine.panHub),
                  child: const Text('继续搜索 PanHub'),
                ),
              if (_haiSouMore)
                OutlinedButton(
                  onPressed: () =>
                      _load(_query, more: CloudSearchEngine.haiSou),
                  child: const Text('加载更多海搜结果'),
                ),
            ],
          );
        }
        if (index > rows.length) return const SizedBox.shrink();
        if (index > 0) {
          final row = rows[index - 1];
          if (row case (name: final String name, count: final int count)) {
            final key = (_groupByPlatform, name);
            final expanded = !_collapsed.contains(key);
            return Semantics(
              expanded: expanded,
              child: ListTile(
                title: Text(
                  name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$count'),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
                onTap: () => setState(() {
                  if (expanded) {
                    _collapsed.add(key);
                  } else {
                    _collapsed.remove(key);
                  }
                }),
              ),
            );
          }
          final hit = row as CloudSearchHit;
          return Padding(
            key: ValueKey(hit.key),
            padding: const EdgeInsetsDirectional.only(start: 20),
            child: _resultTile(hit),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _input,
              maxLength: 80,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '搜索网盘资源',
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () => _load(_input.text),
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: _load,
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<CloudSearchEngine>(
                  value: _engine,
                  items: [
                    for (final item in CloudSearchEngine.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: (value) {
                    if (value != null && value != _engine) {
                      _changeFilters(() => _engine = value);
                    }
                  },
                ),
                DropdownButton<String>(
                  value: _platform ?? '',
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部网盘')),
                    for (final item in cloudSearchPlatforms.entries)
                      DropdownMenuItem(
                        value: item.key,
                        child: Text(item.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _changeFilters(
                        () => _platform = value.isEmpty ? null : value,
                      );
                    }
                  },
                ),
                if (_includes(CloudSearchEngine.haiSou))
                  FilterChip(
                    label: const Text('海搜按文件名'),
                    selected: _files,
                    onSelected: (value) => _changeFilters(() => _files = value),
                  ),
                IconButton(
                  tooltip: _groupByPlatform ? '按搜索工具分组' : '按网盘分组',
                  onPressed: () =>
                      setState(() => _groupByPlatform = !_groupByPlatform),
                  icon: const Icon(Icons.group_work_outlined),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: '搜索设置',
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _saveDefault,
                      child: const Text('设为默认搜索工具'),
                    ),
                    PopupMenuItem(
                      value: _configureHaiSou,
                      child: const Text('设置海搜 API Key'),
                    ),
                    if (widget.search.haiSouConfigured)
                      PopupMenuItem(
                        value: () {
                          _changeFilters(
                            () => widget.search.configureHaiSou(null),
                          );
                        },
                        child: const Text('清除海搜 API Key'),
                      ),
                    if (widget.manageAccounts case final VoidCallback manage)
                      PopupMenuItem(value: manage, child: const Text('网盘账号管理')),
                    PopupMenuItem(
                      value: widget.pasteShare,
                      child: const Text('粘贴网盘分享'),
                    ),
                  ],
                ),
              ],
            ),
            if (_current != null) ...[
              const LinearProgressIndicator(),
              TextButton(onPressed: _cancel, child: const Text('取消搜索')),
            ],
            for (final engine in CloudSearchEngine.values)
              if (_errors[engine.label] case final error?)
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${engine.label} · $error'),
                    TextButton(
                      onPressed: _current == null
                          ? () => _load(_query, retry: engine)
                          : null,
                      child: const Text('重试'),
                    ),
                  ],
                ),
            if (_panHubBrowser) const Text('PanHub 需要站方验证。也可打开原站查询。'),
            if (_engine == CloudSearchEngine.haiSou &&
                !widget.search.haiSouConfigured)
              TextButton(
                onPressed: _configureHaiSou,
                child: const Text('设置海搜 API Key'),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (widget.allowed('PanHub ${panHubHome.host}'))
                  TextButton.icon(
                    onPressed: _openPanHub,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('在 PanHub 实时搜索'),
                  ),
                if (widget.allowed('海搜 ${haiSouHome.host}'))
                  TextButton.icon(
                    onPressed: _openHaiSou,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('在海搜网页搜索'),
                  ),
                if (_panHubBrowser && !widget.search.panHubSignedIn)
                  TextButton(
                    onPressed: _authenticating ? null : _signInPanHub,
                    child: Text(_authenticating ? '正在验证' : 'PanHub 站方验证'),
                  ),
                if (widget.search.panHubSignedIn)
                  TextButton(
                    onPressed: _clearPanHub,
                    child: const Text('清除 PanHub 登录'),
                  ),
                for (final (name, link) in websites)
                  if (widget.allowed('$name ${link.host}'))
                    TextButton.icon(
                      onPressed: () => widget.open(link, name),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(name),
                    ),
              ],
            ),
            if (_query.isNotEmpty && _current == null && results.isEmpty)
              Text(
                _errors.isEmpty && !_panHubBrowser ? '没有匹配的结果' : '当前没有可显示的结果',
              ),
          ],
        );
      },
    );
  }
}
