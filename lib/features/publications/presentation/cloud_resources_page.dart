import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/platform/video_files.dart';
import '../application/publication_module.dart';
import '../application/cloud_resource_download.dart';
import '../data/cloud_navhub_catalog.dart';
import '../data/cloud_resource_catalog.dart';
import '../data/cloud_shared_catalogs.dart';
import '../data/cloud_shared_file.dart';
import '../data/publication_http.dart';
import '../data/publication_share_provider.dart';
import '../domain/publication.dart';
import '../domain/share_text.dart';
import 'baidu_token_guide.dart';
import 'cloud_drive_accounts_dialog.dart';
import 'cloud_resource_catalog_view.dart';
import 'cloud_resource_search_view.dart';
import 'publication_dialogs.dart';

final class CloudResourcesPage extends StatefulWidget {
  const CloudResourcesPage({
    super.key,
    required this.module,
    required this.onOpenLibrary,
    required this.onOpenTasks,
    this.wrapList,
  });

  final PublicationModule module;
  final VoidCallback? onOpenLibrary, onOpenTasks;
  final Widget Function(Widget)? wrapList;

  @override
  State<CloudResourcesPage> createState() => _CloudResourcesPageState();
}

final class _CloudResourcesPageState extends State<CloudResourcesPage> {
  final _linkField = TextEditingController();
  final _codeField = TextEditingController();
  final _progressClock = Stopwatch();
  late Future<CloudResourceCatalog> _catalogData = _mergedCatalog();
  final _catalogUpdates = <String, CloudResourceEntry>{};
  final _catalogErrors = <String, String>{};
  final _refreshingCatalogs = <String>{};
  ({Uri link, String? code})? _share;
  Uri? _attemptedShareLink;
  List<CloudShareItem> _files = const [];
  final _selected = <CloudShareItem>{};
  List<String> _folder = const [];
  bool _truncated = false;
  String? _inspectedCode;
  String? _message;
  String? _savedPath;
  List<({CloudShareItem item, String path})> _savedFiles = const [];
  String? _operation;
  int _received = 0;
  int? _total;
  int _tab = 0;
  bool _searchOpened = false;
  bool _catalogOpened = false;

  bool get _busy => _operation != null;
  bool get _codeChanged =>
      _share != null && _codeField.text.trim() != _inspectedCode;
  bool get _canDownload => !_busy && !_codeChanged;
  PublicationModule get _module => widget.module;

  @override
  void dispose() {
    _module.cloudResources.cancel();
    _linkField.dispose();
    _codeField.dispose();
    super.dispose();
  }

  void _invalidate() {
    _share = null;
    _attemptedShareLink = null;
    _inspectedCode = null;
    _files = const [];
    _selected.clear();
    _folder = const [];
    _truncated = false;
    _message = null;
    _savedPath = null;
    _savedFiles = const [];
  }

  Future<void> _run(String operation, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _operation = operation;
      _message = null;
      _savedPath = null;
      _savedFiles = const [];
      _total = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _errorMessage(error));
      if (error case PublicationFailure(:final problem)) {
        final link =
            _share?.link ??
            publicationShareInputs(_linkField.text).singleOrNull?.link;
        if (link != null) {
          await showBaiduTokenGuideOnce(context, _module, link, problem);
        }
      }
    } finally {
      if (mounted) setState(() => _operation = null);
    }
  }

  Future<CloudShareListing> _previewShare(
    Uri link,
    String? code,
    CancellationToken token,
  ) {
    _module.library.requireImport(link.host);
    return _module.shares.inspectTree(link, code, token, preview: true);
  }

  Future<void> _inspect() => _run('正在解析分享', () async {
    final share = _requestedShare();
    _attemptedShareLink = share.link;
    if (isBaiduPublicationShare(share.link)) {
      _module.library.requireImport(share.link.host);
      _module.shares.http.authorize(
        baiduPublicationSharePage(share.link, share.code),
      );
    }
    final listing = await _module.cloudResources.inspectTree(
      share.link,
      share.code,
    );
    if (!mounted) return;
    final sameShare = _share?.link == share.link;
    final selected = {if (sameShare) ..._selected.map(_fileKey)};
    setState(() {
      _share = share;
      _inspectedCode = _codeField.text.trim();
      _files = listing.files;
      _selected
        ..clear()
        ..addAll(_files.where((item) => selected.contains(_fileKey(item))));
      if (!sameShare || !_files.any((item) => item.inside(_folder))) {
        _folder = const [];
      }
      _truncated = listing.truncated;
      if (_files.isEmpty) _message = '没有可访问的文件';
    });
  });

  (String?, String, String) _fileKey(CloudShareItem item) =>
      (item.file.id, item.file.name, item.folders.join('/'));

  ({Uri link, String? code}) _requestedShare() {
    final input = _readInput();
    final typedCode = _codeField.text.trim();
    if (typedCode.isEmpty && input.needsConfirmation) {
      throw const FormatException('发现多个提取码，请在提取码栏中填写正确的值');
    }
    if (typedCode.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9]{1,32}$').hasMatch(typedCode)) {
      throw const FormatException('提取码应由字母或数字组成');
    }
    return (link: input.link, code: typedCode.isEmpty ? input.code : typedCode);
  }

  Future<void> _manageAccounts() async {
    void authorize() => _module.library.requireImport('网盘账号管理');
    if (_module.policy.supervision.enabled ||
        _module.policy.supervision.corrupted) {
      return;
    }
    await showCloudDriveAccounts(context, _module.cloudAccounts, authorize);
    if (mounted) setState(() {});
  }

  Future<({String? token})?> _downloadAccess(Uri link) async {
    if (PublicationShareProvider.of(link) == PublicationShareProvider.tianyi &&
        _module.cloudAccounts.tianyi == null) {
      await _manageAccounts();
      if (!mounted || _module.cloudAccounts.tianyi == null) return null;
    }
    final token = _module.cloudAccounts.baiduToken;
    if (token != null && isBaiduPublicationShare(link)) return (token: token);
    return choosePublicationDownloadAccess(context, link);
  }

  Future<void> _addToLibrary(PublicationSharedFile file) =>
      _run('正在创建图书下载任务', () async {
        final share = _share;
        if (share == null) return;
        final access = await _downloadAccess(share.link);
        if (access == null || !mounted) return;
        await _module.workflow.addSharedFile(
          share.link,
          file,
          code: share.code,
          baiduAccessToken: access.token,
        );
        if (mounted) widget.onOpenTasks?.call();
      });

  Future<void> _save(List<CloudShareItem> items) => _run('选择目录并检查空间', () async {
    final share = _share;
    if (share == null || items.isEmpty) return;
    final access = await _downloadAccess(share.link);
    if (access == null || !mounted) return;
    _progressClock
      ..reset()
      ..start();
    final result = await _module.cloudResources.saveBatch(
      share.link,
      share.code,
      items,
      _progress,
      baiduAccessToken: access.token,
    );
    if (!mounted || result == null) return;
    final completed = result.saved.length;
    final failure = result.failure;
    setState(() {
      _selected.removeAll(result.saved);
      if (failure != null) {
        _selected.addAll(items.where((item) => !result.saved.contains(item)));
      }
      _message = failure == null
          ? '已下载 $completed 个文件'
          : '已保存 $completed / ${items.length} 个文件。\n'
                '${items[completed].file.name}：${_errorMessage(failure)}';
      _savedPath = result.destination;
      _savedFiles = [
        for (final (index, item) in result.saved.indexed)
          (item: item, path: result.savedPaths[index]),
      ];
    });
    if (failure case PublicationFailure(:final problem)) {
      await showBaiduTokenGuideOnce(context, _module, share.link, problem);
    }
  });

  Future<void> _openSaved(String destination, {bool folder = false}) async {
    final files = _savedFiles
        .where(
          (entry) =>
              _allowed(entry.item.file.name) &&
              entry.item.folders.every(_allowed),
        )
        .toList();
    if (files.isEmpty) return;
    final file = await choosePublicationValue(
      context,
      folder ? '选择要定位的文件' : '选择要打开的文件',
      files,
      (entry) => [...entry.item.folders, entry.item.file.name].join(' / '),
    );
    if (!mounted || file == null) return;
    try {
      _module.library.requireImport(file.item.file.name);
      for (final name in file.item.folders) {
        _module.library.requireImport(name);
      }
      if (Platform.isAndroid) {
        await VideoFiles.openCloudResource(destination, file.path);
      } else if (folder && Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', file.path]);
      } else if (!await launchUrl(
        folder ? Uri.directory(p.dirname(file.path)) : Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      )) {
        throw const FormatException('无法打开已保存的文件');
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开已保存的文件或目录');
    }
  }

  void _progress(CloudBatchProgress progress) {
    if (!mounted) return;
    final (
      index: index,
      count: count,
      name: name,
      received: received,
      total: total,
    ) = progress;
    if (received != 0 &&
        received != total &&
        _progressClock.elapsedMilliseconds < 100) {
      return;
    }
    _progressClock.reset();
    setState(() {
      final stage = received == 0 && total < 0
          ? '正在准备'
          : received == total
          ? '正在保存'
          : '正在下载';
      _operation = '$stage ${index + 1} / $count · $name';
      _received = received;
      _total = total < 0 ? null : total;
    });
  }

  Future<void> _select(Uri link, [String? code]) async {
    if (_busy) return;
    setState(() {
      _tab = 0;
      _linkField.text = link.toString();
      _codeField.text = code ?? '';
      _invalidate();
    });
    await _inspect();
  }

  Future<void> _pasteSearchShare() async {
    if (_busy) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted || _busy) return;
    if (text == null || text.isEmpty || text.length > 16384) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先复制一条网盘分享链接或分享文本')));
      return;
    }
    setState(() {
      _tab = 0;
      _linkField.text = text;
      _codeField.clear();
      _invalidate();
    });
    await _inspect();
  }

  PublicationShareInput _readInput() =>
      publicationShareInputs(_linkField.text).singleOrNull ??
      (throw const FormatException('请一次输入一个分享链接'));

  Future<void> _openSharePage() async {
    try {
      final parsed = _readInput();
      if (isBaiduPublicationShare(parsed.link)) {
        final share = _requestedShare();
        await _open(baiduPublicationSharePage(share.link, share.code), '百度网盘');
        return;
      }
      final original = Uri.tryParse(_linkField.text.trim());
      final link =
          original != null &&
              original.scheme == parsed.link.scheme &&
              original.host == parsed.link.host &&
              original.port == parsed.link.port &&
              original.path == parsed.link.path
          ? original
          : parsed.link;
      await _open(link, '分享页');
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    }
  }

  Future<void> _open(Uri link, String name) async {
    try {
      _module.library.requireImport('$name ${link.host}');
      validatePublicationAddress(link);
      _module.shares.http.authorize(link);
      if (await launchUrl(link, mode: LaunchMode.externalApplication)) return;
      throw const FormatException('无法打开浏览器');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }

  bool _allowed(String text) => _module.policy.textAllowed(text);

  Future<CloudResourceCatalog> _mergedCatalog() async {
    final (builtin, nav, shared) = await (
      CloudResourceCatalog.load(),
      _module.cloudNavHub.load().then<CloudResourceEntry?>(
        (value) => value,
        onError: (Object _) => null,
      ),
      Future.wait(CloudSharedCatalog.values.map(_module.cloudCatalogs.load)),
    ).wait;
    return CloudResourceCatalog(builtin.source, [
      ...builtin.categories,
      ...shared,
      nav ?? CloudResourceEntry('导航森林', navHubHome, const []),
    ]);
  }

  Future<void> _refreshCatalog(String name) async {
    if (_refreshingCatalogs.contains(name)) return;
    setState(() {
      _refreshingCatalogs.add(name);
      _catalogErrors.remove(name);
    });
    try {
      _module.library.requireImport(name);
      final shared = CloudSharedCatalog.named(name);
      final entry = shared == null
          ? await _module.cloudNavHub.refresh()
          : await _module.cloudCatalogs.refresh(shared);
      if (!mounted) return;
      setState(() => _catalogUpdates[name] = entry);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _catalogErrors[name] = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _refreshingCatalogs.remove(name));
    }
  }

  void _selectTab(int tab) {
    setState(() {
      _tab = tab;
      if (tab == 1) _searchOpened = true;
    });
    if (tab == 2 && !_catalogOpened) {
      _catalogOpened = true;
      unawaited(_syncMissingCatalogs());
    }
  }

  Future<void> _syncMissingCatalogs() async {
    try {
      final catalog = await _catalogData;
      if (!mounted) return;
      for (final entry in catalog.categories) {
        if (entry.name == '导航森林' ||
            (entry.rows.isEmpty &&
                CloudSharedCatalog.named(entry.name) != null)) {
          unawaited(_refreshCatalog(entry.name));
        }
      }
    } on Exception {
      // The resource library shows initial load failures in its own view.
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _module.policy,
    builder: (context, _) {
      final supervision = _module.policy.supervision;
      if (supervision.enabled || supervision.corrupted) {
        return const Center(child: Text('当前内容策略限制此操作'));
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.cloud_download_outlined),
                  label: Text('链接下载'),
                ),
                ButtonSegment(value: 1, label: Text('搜索发现')),
                ButtonSegment(
                  value: 2,
                  icon: Icon(Icons.folder_outlined),
                  label: Text('资源库'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => _selectTab(selection.single),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _segment(0, _downloadView()),
                _segment(
                  1,
                  _searchOpened
                      ? CloudResourceSearchView(
                          search: _module.cloudSearch,
                          store: _module.store,
                          allowed: _allowed,
                          open: _open,
                          parse: _select,
                          pasteShare: _pasteSearchShare,
                          inspect: _previewShare,
                          manageAccounts: _manageAccounts,
                        )
                      : const SizedBox.shrink(),
                ),
                _segment(
                  2,
                  _catalogOpened
                      ? CloudResourceCatalogView(
                          catalog: _catalogData,
                          onRetry: () {
                            setState(() => _catalogData = _mergedCatalog());
                            unawaited(_syncMissingCatalogs());
                          },
                          allowed: _allowed,
                          open: _open,
                          parse: _select,
                          updates: Map.unmodifiable(_catalogUpdates),
                          refreshing: _refreshingCatalogs,
                          errors: _catalogErrors,
                          onRefresh: _refreshCatalog,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _segment(int index, Widget child) => TickerMode(
    enabled: _tab == index,
    child: ExcludeFocus(
      excluding: _tab != index,
      child: widget.wrapList?.call(child) ?? child,
    ),
  );

  Widget _downloadView() {
    final provider = PublicationShareProvider.of(_share?.link ?? Uri());
    final browserOnly = provider.previewsFiles && !provider.listsFiles;
    final allowed = _files
        .where(
          (item) => _allowed(item.file.name) && item.folders.every(_allowed),
        )
        .toList();
    final inside = allowed.where((item) => item.inside(_folder)).toList();
    final selected = allowed.where(_selected.contains).toList();
    final folders = <String, List<CloudShareItem>>{};
    final files = <CloudShareItem>[];
    for (final item in inside) {
      if (item.folders.length == _folder.length) {
        files.add(item);
      } else {
        (folders[item.folders[_folder.length]] ??= []).add(item);
      }
    }
    final rows = folders.entries.toList(growable: false);
    return ListView.builder(
      key: ValueKey(_folder.join('/')),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: rows.length + files.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _downloadControls(),
              if (_truncated) const Text('目录较大，已显示部分文件。'),
              if (browserOnly) const Text('下载请打开原分享。'),
              if (allowed.isNotEmpty)
                _selectionControls(inside, selected, canDownload: !browserOnly),
            ],
          );
        }
        if (index <= rows.length) {
          final folder = rows[index - 1];
          return _folderTile(
            folder.key,
            folder.value,
            canDownload: !browserOnly,
          );
        }
        final item = files[index - rows.length - 1];
        return browserOnly
            ? ListTile(title: Text(item.file.name))
            : _fileTile(item);
      },
    );
  }

  Widget _selectionControls(
    List<CloudShareItem> inside,
    List<CloudShareItem> selected, {
    required bool canDownload,
  }) {
    final all = inside.isNotEmpty && inside.every(_selected.contains);
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_folder.isNotEmpty)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => setState(
                    () => _folder = _folder.sublist(0, _folder.length - 1),
                  ),
            icon: const Icon(Icons.arrow_upward),
            label: const Text('上一级'),
          ),
        if (_folder.isNotEmpty)
          PopupMenuButton<int>(
            tooltip: '跳转到上层目录',
            onSelected: (depth) =>
                setState(() => _folder = _folder.sublist(0, depth)),
            enabled: !_busy,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: Text('分享根目录')),
              for (var index = 0; index < _folder.length - 1; index++)
                PopupMenuItem(value: index + 1, child: Text(_folder[index])),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _folder.join(' / '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        if (canDownload)
          TextButton(
            onPressed: _busy || inside.isEmpty || _truncated && !all
                ? null
                : () => _mark(inside, !all),
            child: Text(all ? '取消全选当前目录' : '全选当前目录'),
          ),
        if (canDownload && selected.isNotEmpty) ...[
          FilledButton.tonalIcon(
            onPressed: _canDownload ? () => _save(selected) : null,
            icon: const Icon(Icons.download_outlined),
            label: Text('下载所选（${selected.length}）'),
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(_selected.clear),
            child: const Text('清空选择'),
          ),
        ],
      ],
    );
  }

  void _mark(List<CloudShareItem> files, bool selected) => setState(() {
    if (selected) {
      _selected.addAll(files);
    } else {
      _selected.removeAll(files);
    }
  });

  Widget _folderTile(
    String name,
    List<CloudShareItem> files, {
    required bool canDownload,
  }) {
    final marked = files.where(_selected.contains).length;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: !canDownload
          ? const Icon(Icons.folder_outlined)
          : Checkbox(
              value: marked == 0
                  ? false
                  : marked == files.length
                  ? true
                  : null,
              tristate: true,
              semanticLabel: '选择文件夹 $name',
              onChanged: _busy || _truncated
                  ? null
                  : (_) => _mark(files, marked != files.length),
            ),
      title: Text(name),
      subtitle: Text('${files.length} 个文件'),
      trailing: !canDownload
          ? null
          : IconButton(
              tooltip: '下载文件夹',
              onPressed: _canDownload && !_truncated
                  ? () => _save(files)
                  : null,
              icon: const Icon(Icons.folder_copy_outlined),
            ),
      onTap: _busy ? null : () => setState(() => _folder = [..._folder, name]),
    );
  }

  Widget _downloadControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _linkField,
        decoration: const InputDecoration(
          labelText: '网盘分享链接',
          hintText: '粘贴网盘链接或含提取码的分享文本',
        ),
        enabled: !_busy,
        keyboardType: TextInputType.url,
        maxLines: 2,
        onChanged: (_) => setState(_invalidate),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _codeField,
        decoration: const InputDecoration(labelText: '提取码（如需要）'),
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.go,
        onChanged: (_) => setState(() => _message = null),
        onSubmitted: (_) => _inspect(),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _inspect,
            icon: const Icon(Icons.link),
            label: const Text('解析分享'),
          ),
          if (!_busy && _linkField.text.trim().isNotEmpty)
            TextButton.icon(
              onPressed: _openSharePage,
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开分享页'),
            ),
          if (!_busy)
            TextButton.icon(
              onPressed: _manageAccounts,
              icon: const Icon(Icons.manage_accounts_outlined),
              label: const Text('网盘账号'),
            ),
          if (_busy)
            TextButton(
              onPressed: _module.cloudResources.cancel,
              child: const Text('取消'),
            ),
        ],
      ),
      if (_codeChanged) const Text('提取码已修改，重新解析后可继续下载。'),
      if (_busy) ...[
        const SizedBox(height: 12),
        Text(_allowed(_operation!) ? _operation! : '正在处理网盘文件'),
        const Text('关闭此页会取消当前操作，已保存的文件会保留。'),
        if (_total case final int total)
          Text(
            '${_bytes(_received)} / ${_bytes(total)}'
            '${total > 0 ? ' · ${(_received * 100 ~/ total).clamp(0, 100)}%' : ''}',
          )
        else if (_received > 0)
          Text('已接收 ${_bytes(_received)}'),
        LinearProgressIndicator(
          value: _total == null
              ? null
              : _total == 0
              ? 1
              : _received / _total!,
        ),
      ],
      if (_message case final String message) ...[
        const SizedBox(height: 12),
        Text(
          _allowed(message) ? message : '网盘操作未完成',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ],
      if (_savedPath case final String path when _savedFiles.isNotEmpty) ...[
        if (!Platform.isAndroid) SelectableText(path),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => _openSaved(path),
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开文件'),
            ),
            if (!Platform.isAndroid)
              TextButton.icon(
                onPressed: () => _openSaved(path, folder: true),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开文件夹'),
              ),
          ],
        ),
      ],
      if ((_share?.link ?? _attemptedShareLink) case final Uri link
          when widget.onOpenLibrary != null &&
              _message != null &&
              _savedPath == null &&
              isBaiduPublicationShare(link))
        TextButton.icon(
          onPressed: _busy ? null : widget.onOpenLibrary,
          icon: const Icon(Icons.library_books_outlined),
          label: const Text('前往书库导入已下载的图书'),
        ),
    ],
  );

  Widget _fileTile(CloudShareItem item) {
    final file = item.file;
    final provider = PublicationShareProvider.of(_share?.link ?? Uri());
    final canAddToLibrary =
        widget.onOpenTasks != null &&
        (!_module.workflow.android ||
            (provider != PublicationShareProvider.tianyi &&
                (provider != PublicationShareProvider.mobile139 ||
                    _module.cloudAccounts.mobile == null)));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: _selected.contains(item),
        semanticLabel: '选择文件 ${file.name}',
        onChanged: _busy ? null : (value) => _mark([item], value == true),
      ),
      title: Text(file.name),
      subtitle: Text(file.bytes == null ? '下载前获取大小' : _bytes(file.bytes!)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sharedPublication(file) case final book? when canAddToLibrary)
            IconButton(
              tooltip: '下载并加入书库',
              icon: const Icon(Icons.library_add_outlined),
              onPressed: _canDownload ? () => _addToLibrary(book) : null,
            ),
          IconButton(
            tooltip: '选择目录并下载',
            icon: const Icon(Icons.download_outlined),
            onPressed: _canDownload ? () => _save([item]) : null,
          ),
        ],
      ),
    );
  }

  String _errorMessage(Object error) => switch (error) {
    PublicationFailure(
      problem: PublicationProblem.diskFull,
      spaceShortfall: final space?,
    ) =>
      '剩余空间不足，需要 ${_bytes(space.requiredBytes)}，可用 ${_bytes(space.availableBytes)}',
    PublicationFailure(:final problem) => problem.label,
    RequestCancelled() => '已取消',
    FormatException(:final message) => message,
    PlatformException(code: 'publication_directory_permission') =>
      PublicationProblem.directoryPermission.label,
    PlatformException(code: 'publication_destination_conflict') =>
      PublicationProblem.destinationConflict.label,
    PlatformException(code: 'publication_disk_full') =>
      PublicationProblem.diskFull.label,
    FileSystemException() ||
    PlatformException() => PublicationProblem.storage.label,
    _ => '网盘操作未完成，请重试',
  };

  String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MiB';
    return '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';
  }
}
