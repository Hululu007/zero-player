import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

/// Fixtures explicitly authorize their synthetic comic source; production
/// admission is never bypassed just to exercise media decoding and budgets.
Future<void> authorizeComicFixture(
  AppServices services,
  BookSource source,
) async {
  if (source.kind != BookKind.comic) return;
  final guard = services.supervision;
  await guard.load();
  const password = 'comic-fixture-password';
  if (!guard.configured) {
    await guard.saveCredentials(await guard.prepareCredentials(password));
    await guard.execute(
      SensitiveOperation.supervision,
      () => guard.setEnabled(false),
      password: password,
    );
  }
  await guard.execute(
    SensitiveOperation.supervision,
    () => services.books.comicAccess.approve(source),
    password: password,
  );
}
