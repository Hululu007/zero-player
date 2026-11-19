import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/features/books/data/book_store.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/books/presentation/book_vault_gate.dart';

void main() {
  testWidgets(
    'backgrounding a reader locks and disposes all private content and dialogs',
    (tester) async {
      final db = AppDatabase.memory();
      final store = BookStore(db);
      final book = Book(
        'local',
        BookKind.text,
        '私密标题',
        '',
        Uri.parse('book:private'),
      );
      await tester.runAsync(() async {
        await store.saveBook(book);
        await store.vault.create('secret-123');
        await store.moveToVault(book);
      });
      var disposed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: BookVaultGate(
            store: store,
            bookId: book.id,
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BookVaultGate(
                      store: store,
                      bookId: book.id,
                      builder: (context) =>
                          _Secret(onDispose: () => disposed++),
                    ),
                  ),
                ),
                child: const Text('阅读私密标题'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读私密标题'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('私密正文'), findsOneWidget);
      await tester.tap(find.text('私密正文'));
      await tester.pumpAndSettle();
      expect(find.text('私密选文'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(store.vault.unlocked, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('私密正文'), findsNothing);
      expect(find.text('私密选文'), findsNothing);
      expect(find.text('阅读私密标题'), findsNothing);
      expect(disposed, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      store.vault.dispose();
      await tester.runAsync(db.close);
    },
  );
}

class _Secret extends StatefulWidget {
  const _Secret({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_Secret> createState() => _SecretState();
}

class _SecretState extends State<_Secret> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('私密选文')),
        ),
      ),
      child: const Text('私密正文'),
    ),
  );
}
