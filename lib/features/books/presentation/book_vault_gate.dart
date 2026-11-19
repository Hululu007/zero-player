import 'dart:async';

import 'package:flutter/material.dart';

import '../data/book_store.dart';
import 'book_vault_dialogs.dart';

/// Disposes decrypted pages on revocation, including routes above the shelf.
final class BookVaultGate extends StatefulWidget {
  const BookVaultGate({
    super.key,
    required this.store,
    this.bookId,
    this.private = false,
    required this.builder,
  });
  final BookStore store;
  final String? bookId;
  final bool private;
  final WidgetBuilder builder;

  @override
  State<BookVaultGate> createState() => _BookVaultGateState();
}

final class _BookVaultGateState extends State<BookVaultGate>
    with WidgetsBindingObserver {
  bool _ready = false;
  bool get _private =>
      widget.private ||
      (widget.bookId != null && widget.store.vault.isPrivate(widget.bookId!));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.vault.addListener(_changed);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.store.vault.ensureLoaded();
      if (mounted) setState(() => _ready = true);
    } on Exception {
      // Invalid configuration must never expose a potentially private page.
      if (mounted) setState(() => _ready = false);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (!widget.store.vault.unlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.store.vault.unlocked) return;
        Navigator.of(context).popUntil((route) => route is! PopupRoute);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.store.vault.lock();
    }
  }

  @override
  void dispose() {
    widget.store.vault.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready && (!_private || widget.store.vault.unlocked)) {
      return widget.builder(context);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('私密空间')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            const Text('私密内容已锁定'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                if (await ensureVaultAccess(context, widget.store) && mounted) {
                  await _load();
                }
              },
              child: const Text('验证并解锁'),
            ),
          ],
        ),
      ),
    );
  }
}
