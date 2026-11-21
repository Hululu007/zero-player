import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/features/publications/data/publication_documents.dart';
import 'package:zero_player/features/publications/data/publication_transfer.dart';
import 'package:zero_player/features/publications/domain/publication.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import 'local_book_fixtures.dart';

void registerPublicationPdfAdmissionTests(
  Future<void> Function(Future<void> Function(AppServices)) withServices,
) {
  testWidgets(
    'PDF admission checks the last page and stops a cancelled scan',
    (_) => withServices(_pageAdmission),
  );
  testWidgets(
    'locking the private shelf revokes an open publication PDF',
    (_) => withServices(_vaultAdmission),
  );
  testWidgets(
    'a policy change at PDF publication rolls back the earlier scan',
    (_) => withServices(_policyAdmission),
  );
}

Future<void> _pageAdmission(AppServices services) async {
  final module = services.publications;
  const name = 'Reference.pdf';
  final bytes = samplePdf(secondPageText: 'AV');
  final file = await File('${services.root.path}/$name').writeAsBytes(bytes);
  final checkedPages = <String>[];
  await expectLater(
    admitPublication(
      file,
      PublicationFormat.pdf,
      name,
      CancellationToken(),
      authorize: (text) {
        if (text == '第 1 页' || text == '第 2 页') checkedPages.add(text);
        module.library.requireImport(text);
      },
    ),
    throwsA(_blocked),
  );
  expect(checkedPages, ['第 1 页', '第 2 页']);
  await expectLater(module.workflow.importLocal(file), throwsA(_blocked));
  expect(await module.library.holdings(), isEmpty);
  expect(await file.readAsBytes(), bytes);

  final token = CancellationToken();
  checkedPages.clear();
  await expectLater(
    admitPublication(
      file,
      PublicationFormat.pdf,
      name,
      token,
      authorize: (text) {
        if (text == '第 1 页' || text == '第 2 页') checkedPages.add(text);
        if (text == '第 1 页') token.cancel();
      },
    ),
    throwsA(isA<RequestCancelled>()),
  );
  expect(checkedPages, ['第 1 页']);
  expect(await module.library.holdings(), isEmpty);
}

Future<void> _vaultAdmission(AppServices services) async {
  final module = services.publications;
  final books = services.books;
  final bytes = samplePdf();
  final file = await File(
    '${services.root.path}/Vault reference.pdf',
  ).writeAsBytes(bytes);
  final current = await books.importLocal(file);
  await module.library.attachLegacy(current);
  final before = (await module.library.holdings()).single;
  final opened = await module.library.open(before, CancellationToken());
  try {
    expect(opened.allowed(), isTrue);
    await books.store.vault.create('local-fixture-password');
    await books.store.moveToVault(current);
    books.store.vault.lock();
    expect(opened.allowed(), isFalse);
    expect(await module.library.holdings(), isEmpty);
    await expectLater(
      module.library.open(before, CancellationToken()),
      throwsA(_blocked),
    );
    expect(await file.readAsBytes(), bytes);
  } finally {
    await module.space.unlease(opened.lease);
  }
}

Future<void> _policyAdmission(AppServices services) async {
  final module = services.publications;
  await module.workflow.initialize();
  final guard = services.supervision;
  const password = 'admission-fixture-password';
  final credentials = await guard.prepareCredentials(password);
  expect(guard.enabled, isFalse);

  const name = 'Policy reference.pdf';
  final bytes = samplePdf();
  final original = await File(
    '${services.root.path}/$name',
  ).writeAsBytes(bytes);
  final id = publicationId('publication-policy-admission');
  final stage = module.workflow.transfer.part(id);
  await stage.parent.create(recursive: true);
  await module.space.reserve(id, bytes.length);
  await original.copy(stage.path);
  await module.space.checkpoint(id, bytes.length);
  final token = CancellationToken();
  final digest = await publicationFileDigest(original, token);
  final target = module.space.managedFile(digest, PublicationFormat.pdf);

  var policyChanged = false;
  await expectLater(
    module.library.importStaged(
      stage,
      name,
      PublicationFormat.pdf,
      id,
      token,
      confirmSource: () async {
        expect(await target.exists(), isTrue);
        expect(await services.db.rows('SELECT digest FROM publication_files'), [
          {'digest': digest},
        ]);
        await guard.saveCredentials(credentials);
        expect(guard.enabled, isTrue);
        policyChanged = true;
      },
    ),
    throwsA(_blocked),
  );
  expect(policyChanged, isTrue);
  expect(await module.library.holdings(), isEmpty);
  expect(await services.db.rows('SELECT * FROM publication_files'), isEmpty);
  expect(await services.db.rows('SELECT * FROM publication_imports'), isEmpty);
  expect(await target.exists(), isFalse);
  expect(await stage.readAsBytes(), bytes);
  expect((await module.space.usage()).used, bytes.length);

  // Persist supervision independently of the rolled-back import transaction.
  await guard.execute(
    SensitiveOperation.supervision,
    () => guard.setEnabled(true),
    password: password,
  );
  await expectLater(module.workflow.importLocal(original), throwsA(_blocked));
  expect(await module.library.holdings(), isEmpty);
  expect(await original.readAsBytes(), bytes);
}

final _blocked = isA<PublicationFailure>().having(
  (failure) => failure.problem,
  'problem',
  PublicationProblem.blocked,
);
