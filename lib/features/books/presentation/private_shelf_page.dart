import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_services.dart';
import '../../../core/network/cancellation_token.dart';
import '../data/book_store.dart';
import '../data/book_vault.dart';
import '../domain/book.dart';
import 'book_detail_page.dart';
import 'book_page_route.dart';
import 'book_shelf_view.dart';
import 'book_vault_dialogs.dart';
import 'book_vault_gate.dart';
import 'book_download_management_page.dart';

/// Encrypted shelf page. The vault key only lives while this route is active;
/// leaving, locking or backgrounding the page clears it.
final class PrivateShelfPage extends StatefulWidget {
  const PrivateShelfPage({
    super.key,
    required this.services,
    required this.kind,
  });
  final AppServices services;
  final BookKind kind;

  @override
  State<PrivateShelfPage> createState() => _PrivateShelfPageState();
}

final class _PrivateShelfPageState extends State<PrivateShelfPage>
    with WidgetsBindingObserver {
  List<BookShelfEntry> _entries = [];
  bool _loading = true, _checking = false, _locked = false;
  String? _error;
  CancellationToken? _token;
  int _sequence = 0;

  AppServices get _services => widget.services;
  BookStore get _store => _services.books.store;
  BookVault get _vault => _store.vault;
  bool get _audio => widget.kind == BookKind.audio;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vault.addListener(_vaultChanged);
    _locked = !_vault.unlocked;
    unawaited(_reload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _token?.cancel();
    _vault.removeListener(_vaultChanged);
    _vault.lock();
    super.dispose();
  }

  void _vaultChanged() {
    if (!mounted || _vault.unlocked) return;
    _sequence++;
    _token?.cancel();
    setState(() {
      _entries = [];
      _locked = true;
      _checking = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _vault.lock();
    }
  }

  Future<void> _reload() async {
    if (!_vault.unlocked) {
      if (mounted) setState(() => _locked = true);
      return;
    }
    final sequence = ++_sequence;
    try {
      await _services.books.ensureSourceRiskLoaded();
      final all = await _store.vaultShelf();
      if (!mounted || sequence != _sequence || !_vault.unlocked) return;
      setState(() {
        _entries = all
            .where(
              (entry) =>
                  entry.book.kind == widget.kind &&
                  _services.books.bookAllowed(entry.book),
            )
            .toList();
        _loading = false;
        _error = null;
        _locked = false;
      });
    } on Exception {
      if (mounted && sequence == _sequence) {
        setState(() {
          _loading = false;
          _error = '无法读取私密书架';
        });
      }
    }
  }

  Future<void> _open(Book book) async {
    await Navigator.of(context).push(
      BookPageRoute<void>(
        builder: (_) => BookDetailPage(services: _services, initial: book),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _checkUpdates(List<BookShelfEntry> entries) async {
    if (entries.isEmpty || _checking) return;
    final token = _token = CancellationToken();
    setState(() => _checking = true);
    try {
      await _services.books.checkShelfUpdates(entries, token);
      if (mounted && !token.isCancelled) await _reload();
    } on Exception {
      // Cached catalogs remain visible; the next attempt retries.
    } finally {
      if (mounted && identical(_token, token)) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _lock({bool pop = true}) async {
    final tasks = _services.bookDownloads.activeTasks
        .where((task) => _vault.isPrivate(task.book.id))
        .toList();
    if (tasks.isNotEmpty) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('锁定私密书架？'),
          content: const Text('私密书架中有正在下载的作品，锁定后下载会暂停。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('锁定'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      for (final task in tasks) {
        task.pause();
      }
    }
    _token?.cancel();
    _vault.lock();
    if (!mounted) return;
    if (pop) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _entries = [];
        _locked = true;
      });
    }
  }

  Future<void> _unlockHere() async {
    final unlocked = await showVaultUnlockDialog(context, _store);
    if (unlocked && mounted) await _reload();
  }

  Future<void> _changePassword() async {
    final changed = await showVaultPasswordDialog(context, _store);
    if (changed && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('私密书架密码已更新')));
    }
  }

  Future<void> _editHint() async {
    final controller = TextEditingController(text: _vault.hint);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('密码提示'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: '提示文字（不要填写密码）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) await _vault.setHint(value);
  }

  Future<void> _toggleBiometric(bool value) async {
    try {
      if (value) {
        final enabled = await _vault.enableBiometric();
        if (!mounted) return;
        if (!enabled) {
          _toast('指纹未完成设置，请检查设备指纹与锁屏密码');
        }
      } else {
        await _vault.disableBiometric();
      }
      if (mounted) setState(() {});
    } on FormatException catch (error) {
      if (mounted) _toast(error.message);
    } on Exception {
      if (mounted) _toast('指纹设置未完成');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.lock_outline, size: 20),
            const SizedBox(width: 8),
            Text(
              _audio
                  ? '私密听书'
                  : widget.kind == BookKind.comic
                  ? '私密漫画'
                  : '私密书架',
            ),
          ],
        ),
        actions: [
          if (!_locked)
            IconButton(
              tooltip: '私密下载管理',
              icon: const Icon(Icons.download),
              onPressed: () => Navigator.of(context).push(
                BookPageRoute<void>(
                  builder: (_) => BookVaultGate(
                    store: _store,
                    private: true,
                    builder: (_) => BookDownloadManagementPage(
                      services: _services,
                      private: true,
                    ),
                  ),
                ),
              ),
            ),
          if (!_locked)
            IconButton(
              tooltip: '锁定',
              onPressed: () => _lock(),
              icon: const Icon(Icons.lock),
            ),
          PopupMenuButton<String>(
            tooltip: '私密书架设置',
            onSelected: (value) async {
              switch (value) {
                case 'password':
                  await _changePassword();
                case 'hint':
                  await _editHint();
                case 'biometric':
                  await _toggleBiometric(!_vault.biometricEnabled);
                case 'lock':
                  await _lock();
              }
            },
            itemBuilder: (_) => [
              if (!_locked) ...[
                const PopupMenuItem(value: 'password', child: Text('修改密码')),
                const PopupMenuItem(value: 'hint', child: Text('编辑密码提示')),
                PopupMenuItem(
                  value: 'biometric',
                  child: Text(_vault.biometricEnabled ? '关闭指纹解锁' : '启用指纹解锁'),
                ),
                const PopupMenuItem(value: 'lock', child: Text('立即锁定')),
              ],
            ],
          ),
        ],
      ),
      body: _locked ? _lockedView() : _shelfView(),
    );
  }

  Widget _lockedView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline, size: 48),
        const SizedBox(height: 12),
        const Text('私密书架已锁定'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _unlockHere,
          icon: const Icon(Icons.lock_open),
          label: const Text('解锁'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
      ],
    ),
  );

  Widget _shelfView() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: TextButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
          label: Text('$_error，重试'),
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, size: 16),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '书架、笔记、离线文字与图片已加密；音频及 EPUB/PDF 原文件不加密',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              TextButton(onPressed: () => _lock(), child: const Text('锁定')),
            ],
          ),
        ),
        Expanded(
          child: BookShelfView(
            private: true,
            repository: _services.books,
            kind: widget.kind,
            entries: _entries,
            checking: _checking,
            onOpen: _open,
            onRefresh: () => _checkUpdates(_entries),
            onCheckUpdates: _checkUpdates,
            onFollowChanged: () => unawaited(_reload()),
            downloads: _services.bookDownloads,
            pauseDownload: _services.bookDownloads.pause,
            cancelDownload: (book) async {
              await _services.bookDownloads.removePlan(book);
            },
          ),
        ),
      ],
    );
  }
}
