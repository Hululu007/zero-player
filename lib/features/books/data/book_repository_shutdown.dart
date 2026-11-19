part of 'books_repository.dart';

/// Drain in-flight work before disposing dependencies, even if a cancellation
/// callback fails. Preserve and report the first failure after all cleanup.
Future<void> _closeBooksRepository(BooksRepository books) async {
  Object? firstError;
  StackTrace? firstStack;

  void record(Object error, StackTrace stack) {
    firstError ??= error;
    firstStack ??= stack;
  }

  void synchronousStep(void Function() action) {
    try {
      action();
    } catch (error, stack) {
      record(error, stack);
    }
  }

  Future<void> step(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      record(error, stack);
    }
  }

  // Register shutdown and cancel in the same event-loop segment; waiting for
  // one batch must not delay cancelling another already registered scan.
  synchronousStep(() => books._sourceRiskChanges.value++);
  final siteScan = books._siteScanLease;
  if (siteScan != null) synchronousStep(siteScan.token.cancel);
  for (final token in books._supervisedScans.toList()) {
    synchronousStep(token.cancel);
  }
  if (siteScan != null) await step(() => siteScan.done.future);
  await step(() async {
    await Future.wait(books._supervisedScanDone.map((done) => done.future));
  });
  await step(() async {
    await Future.wait(
      books._pendingEvidenceMutations.map((done) => done.future),
    );
  });
  await step(() => books.policy.removeListener(books._coverPolicyChanged));
  await step(() => books.policy.removeListener(books._discoveryPolicyChanged));
  await step(
    () => books._sourceRiskChanges.removeListener(books._discoveryRiskChanged),
  );
  await step(() => books._downloadGuard?.dispose());
  await step(books._bookPolicy.dispose);
  await step(books._sourceRiskChanges.dispose);
  await step(books._http.close);
  await step(books.audioFiles.close);
  synchronousStep(books.readingCleanup.dispose);
  synchronousStep(books.store.vault.dispose);
  await step(books.coverCache.waitForIdle);

  if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
}
