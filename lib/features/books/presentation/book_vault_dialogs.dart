import 'package:flutter/material.dart';

import '../data/book_store.dart';
import '../data/book_vault.dart';

/// Ensures the private space exists and is unlocked, running setup/unlock
/// dialogs as needed. Returns false when the user backs out.
Future<bool> ensureVaultAccess(
  BuildContext context,
  BookStore store, {
  bool reauthenticate = false,
}) async {
  try {
    final vault = store.vault;
    await vault.ensureLoaded();
    if (!context.mounted) return false;
    if (!vault.configured) {
      final created = await showVaultSetupDialog(context, store);
      return created && vault.unlocked;
    }
    if (reauthenticate) vault.lock();
    if (vault.unlocked) return true;
    final unlocked = await showVaultUnlockDialog(context, store);
    return unlocked && vault.unlocked;
  } on Exception catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException ? error.message : '无法访问私密书架，请保留数据后重试',
          ),
        ),
      );
    }
    return false;
  }
}

Future<bool> showVaultSetupDialog(BuildContext context, BookStore store) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _VaultSetupDialog(store: store),
  );
  return result == true;
}

Future<bool> showVaultUnlockDialog(
  BuildContext context,
  BookStore store, {
  String? hint,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _VaultUnlockDialog(store: store, hint: hint),
  );
  return result == true;
}

final class _VaultSetupDialog extends StatefulWidget {
  const _VaultSetupDialog({required this.store});
  final BookStore store;
  @override
  State<_VaultSetupDialog> createState() => _VaultSetupDialogState();
}

final class _VaultSetupDialogState extends State<_VaultSetupDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _hint = TextEditingController();
  bool _biometric = false, _biometricReady = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.store.vault.ensureLoaded().then((_) async {
      final available = await const VaultBiometric().available;
      if (mounted) setState(() => _biometricReady = available);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _hint.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.vault.create(
        _password.text,
        hint: _hint.text,
        biometric: _biometric,
      );
      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '无法创建私密书架，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设置私密书架'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '私密书架独立于普通书架，进入前需要密码或设备指纹验证。书架记录、笔记、离线文字及图片会加密保存。音频和 EPUB/PDF 原文件仍由应用私有目录保存，不加密；密码提示与书籍编号也不加密。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            maxLength: 128,
            decoration: const InputDecoration(labelText: '设置密码（至少 6 位）'),
            onSubmitted: (_) => _create(),
          ),
          TextField(
            controller: _confirm,
            obscureText: true,
            maxLength: 128,
            decoration: const InputDecoration(labelText: '再次输入密码'),
            onSubmitted: (_) => _create(),
          ),
          TextField(
            controller: _hint,
            maxLength: 60,
            decoration: const InputDecoration(labelText: '密码提示（可选）'),
          ),
          if (_biometricReady)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用指纹解锁'),
              subtitle: const Text('使用设备指纹快速进入，密码仍然有效'),
              value: _biometric,
              onChanged: (value) => setState(() => _biometric = value),
            ),
          const Text(
            '忘记密码将无法恢复私密书架中的内容，请妥善保管。',
            style: TextStyle(fontSize: 12),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: Text(_busy ? '创建中…' : '创建'),
      ),
    ],
  );
}

final class _VaultUnlockDialog extends StatefulWidget {
  const _VaultUnlockDialog({required this.store, this.hint});
  final BookStore store;
  final String? hint;
  @override
  State<_VaultUnlockDialog> createState() => _VaultUnlockDialogState();
}

final class _VaultUnlockDialogState extends State<_VaultUnlockDialog> {
  final _password = TextEditingController();
  bool _busy = false, _biometricReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final enabled = widget.store.vault.biometricEnabled;
    if (enabled) {
      const VaultBiometric().available.then((value) {
        if (mounted) setState(() => _biometricReady = value);
      });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.store.vault.unlock(_password.text);
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = '密码不正确');
        _password.clear();
      }
    } on VaultLockedException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockBiometric() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.vault.unlockWithBiometric();
      if (mounted) Navigator.pop(context, true);
    } on VaultLockedException catch (error) {
      if (mounted && error.message != '指纹验证已取消') {
        setState(() => _error = error.message);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '指纹验证未完成');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.hint?.isNotEmpty == true
        ? widget.hint!
        : widget.store.vault.hint;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline),
          SizedBox(width: 8),
          Text('进入私密书架'),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hint.isNotEmpty) ...[
              Text('提示：$hint'),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _password,
              autofocus: !_biometricReady,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
              onSubmitted: (_) => _unlock(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            const Text(
              '密码只用于本机解密，忘记后无法恢复私密书架内容。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        if (_biometricReady)
          TextButton.icon(
            onPressed: _busy ? null : _unlockBiometric,
            icon: const Icon(Icons.fingerprint),
            label: const Text('指纹解锁'),
          ),
        FilledButton(
          onPressed: _busy ? null : _unlock,
          child: Text(_busy ? '验证中…' : '解锁'),
        ),
      ],
    );
  }
}

Future<bool> showVaultPasswordDialog(
  BuildContext context,
  BookStore store, {
  String title = '修改密码',
}) async {
  final vault = store.vault;
  if (!vault.unlocked) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _VaultPasswordDialog(store: store, title: title),
  );
  return result == true;
}

final class _VaultPasswordDialog extends StatefulWidget {
  const _VaultPasswordDialog({required this.store, required this.title});
  final BookStore store;
  final String title;
  @override
  State<_VaultPasswordDialog> createState() => _VaultPasswordDialogState();
}

final class _VaultPasswordDialogState extends State<_VaultPasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_next.text != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.store.vault.changePassword(
        _current.text,
        _next.text,
      );
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = '当前密码不正确');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _current,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: '当前密码'),
          ),
          TextField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
          ),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(labelText: '再次输入新密码'),
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '保存中…' : '保存'),
      ),
    ],
  );
}
