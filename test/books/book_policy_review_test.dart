import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zero_player/app/app_services.dart';
import 'package:zero_player/core/network/cancellation_token.dart';
import 'package:zero_player/core/persistence/app_database.dart';
import 'package:zero_player/core/persistence/installation_metadata.dart';
import 'package:zero_player/features/books/data/book_policy_evidence.dart';
import 'package:zero_player/features/books/data/books_repository.dart';
import 'package:zero_player/features/books/domain/book.dart';
import 'package:zero_player/features/supervision/domain/supervision_rules.dart';

import '../../test_support/verified_temp_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _reviewAndRestart();
  _authorizationAndStaleSnapshots();
  _concurrentObservations();
}

void _reviewAndRestart() {
  test(
    'manual review clears only this adult flag and survives restart',
    () async {
      await _withFixture((f) async {
        await f.seedAdult(f.first);
        await f.seedAdult(f.second);
        await f.services.books.saveSource(f.source, {'enabled': false});
        await expectLater(
          f.services.books.bookPolicyReviewEntries(),
          throwsA(isA<ContentBlocked>()),
        );
        await f.allowReview();
        final entry = (await f.services.books.bookPolicyReviewEntries())
            .singleWhere((item) => item.book.id == f.first.id);
        final original = (await f.evidence.load())[f.first.id]!;
        await f.services.books.clearBookAdultEvidence(entry);
        final saved = (await f.evidence.load())[f.first.id]!;
        expect(saved.adult, isFalse);
        expect(saved.revision, original.revision + 1);
        expect(saved.keywordHashes, original.keywordHashes);
        expect(saved.normalizedTexts, original.normalizedTexts);
        expect(saved.latestText, original.latestText);
        expect(saved.textCoverageIncomplete, isTrue);
        expect((await f.evidence.load())[f.second.id]!.adult, isTrue);
        expect(
          (await f.services.books.sourceEntry(
            BookKind.text,
            f.source.id,
          ))!.enabled,
          isFalse,
        );
        await f.services.settings.update({'filterAdult': true});
        expect(f.services.books.bookAllowed(f.first), isTrue);
        expect(f.services.books.bookAllowed(f.second), isFalse);
        final stillRestrictedMetadata = Book(
          f.first.sourceId,
          f.first.kind,
          f.first.title,
          f.first.author,
          f.first.uri,
          category: '情欲小说',
        );
        expect(stillRestrictedMetadata.id, f.first.id);
        expect(f.services.books.bookAllowed(stillRestrictedMetadata), isFalse);
        expect(
          await f.services.books.readText(
            f.first,
            f.chapter,
            CancellationToken(),
          ),
          '离线测试正文',
        );
        await f.restart();
        expect(f.services.books.bookAllowed(f.first), isTrue);
        expect(f.services.books.bookAllowed(f.second), isFalse);
        expect(
          await f.services.books.readText(
            f.first,
            f.chapter,
            CancellationToken(),
          ),
          '离线测试正文',
        );
        expect(
          (await f.services.books.sourceEntry(
            BookKind.text,
            f.source.id,
          ))!.enabled,
          isFalse,
        );
      });
    },
  );

  test('source restrictions remain independent of a reviewed work', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final entry = (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.books.clearBookAdultEvidence(entry);
      await f.services.books.markSourceRisk(f.source, adult: true);
      await f.services.settings.update({'filterAdult': true});
      expect(f.services.books.bookAllowed(f.first), isFalse);
      expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
    });
  });
}

void _authorizationAndStaleSnapshots() {
  test('policy ABA and newer evidence invalidate a review snapshot', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final oldPolicy =
          (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.settings.update({'filterAdult': true});
      await f.services.settings.update({'filterAdult': false});
      expect(f.services.books.bookPolicyReviewEntryAllowed(oldPolicy), isFalse);
      await expectLater(
        f.services.books.clearBookAdultEvidence(oldPolicy),
        throwsFormatException,
      );
      final firstReview =
          (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.books.clearBookAdultEvidence(firstReview);
      await f.seedAdult(f.first);
      expect(
        f.services.books.bookPolicyReviewEntryAllowed(firstReview),
        isFalse,
      );
      await expectLater(
        f.services.books.clearBookAdultEvidence(firstReview),
        throwsFormatException,
      );
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      final changedSource =
          (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.books.saveSource(f.source, {'enabled': false});
      await expectLater(
        f.services.books.clearBookAdultEvidence(changedSource),
        throwsFormatException,
      );
    });
  });

  test('a removed shelf entry cannot be reviewed from an old dialog', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.db.write('DELETE FROM app_meta WHERE key=?', [
        'books_shelf:${f.first.id}',
      ]);
      await expectLater(
        f.services.books.clearBookAdultEvidence(snapshot),
        throwsFormatException,
      );
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
    });
  });

  test(
    'disabled filtering alone does not bypass installation verification',
    () async {
      await _withFixture((f) async {
        await f.seedAdult(f.first);
        await f.allowReview();
        await f.services.db.write(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [installationAccessKey, freshInstallationAccess],
        );
        await f.restart();
        expect(f.services.contentPolicy.filterAdult, isFalse);
        await expectLater(
          f.services.books.bookPolicyReviewEntries(),
          throwsFormatException,
        );
        expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      });
    },
  );

  test(
    'supervision, recovery code and damaged evidence cannot be bypassed',
    () async {
      await _withFixture((f) async {
        await f.seedAdult(f.first);
        await f.allowReview();
        final snapshot =
            (await f.services.books.bookPolicyReviewEntries()).single;
        final guard = f.services.supervision;
        final credentials = await guard.prepareCredentials('fixture-password');
        final recovery = credentials.recoveryCode;
        await guard.saveCredentials(credentials);
        expect(guard.enabled, isTrue);
        await expectLater(
          f.services.books.bookPolicyReviewEntries(),
          throwsA(isA<FormatException>()),
        );
        await guard.execute(SensitiveOperation.channels, () async {
          await expectLater(
            f.services.books.clearBookAdultEvidence(snapshot),
            throwsA(isA<FormatException>()),
          );
        }, password: 'fixture-password');
        await expectLater(
          guard.execute(
            SensitiveOperation.channels,
            () async {},
            password: recovery,
            useRecovery: true,
          ),
          throwsFormatException,
        );
        expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      });
    },
  );

  test(
    'a malformed record remains restricted and is not offered for clearing',
    () async {
      await _withFixture((f) async {
        await f.services.db.write(
          'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
          [BookPolicyEvidenceStore.key(f.first.id), '{invalid'],
        );
        await f.services.books.refreshSourceRisks();
        await f.allowReview();
        expect(await f.services.books.bookPolicyReviewEntries(), isEmpty);
        expect((await f.evidence.load())[f.first.id]!.uncertain, isTrue);
        await f.services.settings.update({'filterAdult': true});
        expect(f.services.books.bookAllowed(f.first), isFalse);
      });
    },
  );
}

void _concurrentObservations() {
  test('policy changes while the review transaction waits roll back', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      final entered = Completer<void>(), release = Completer<void>();
      f.services.books.beforeBookPolicyReviewWriteForTesting = () async {
        entered.complete();
        await release.future;
      };
      final attempt = f.services.books.clearBookAdultEvidence(snapshot);
      final rejected = expectLater(attempt, throwsFormatException);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        f.services.contentPolicy.refresh();
      } finally {
        release.complete();
      }
      await rejected;
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
    });
  });

  test('policy change after SQL update rolls the transaction back', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      f.services.books.afterBookPolicyReviewWriteForTesting = () async {
        f.services.contentPolicy.refresh();
      };
      await expectLater(
        f.services.books.clearBookAdultEvidence(snapshot),
        throwsFormatException,
      );
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
    });
  });

  test('close after SQL update waits for the review rollback', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      final written = Completer<void>(), release = Completer<void>();
      f.services.books.afterBookPolicyReviewWriteForTesting = () async {
        written.complete();
        await release.future;
      };
      final review = f.services.books.clearBookAdultEvidence(snapshot);
      final rejected = expectLater(review, throwsA(isA<ContentBlocked>()));
      late Future<void> closing;
      var closed = false;
      try {
        await written.future.timeout(const Duration(seconds: 5));
        closing = f.services.books.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
      } finally {
        release.complete();
      }
      await rejected;
      await closing;
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
    });
  });

  test('an in-flight detail must finish before a fresh review', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      f.fake.holdNextResponse();
      final details = f.services.books.details(f.first, CancellationToken());
      await f.fake.requestStarted!.future.timeout(const Duration(seconds: 5));
      try {
        expect(await f.services.books.bookPolicyReviewEntries(), isEmpty);
        await expectLater(
          f.services.books.clearBookAdultEvidence(snapshot),
          throwsFormatException,
        );
      } finally {
        f.fake.releaseResponse();
      }
      await details;
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      expect(f.services.books.bookPolicyReviewEntryAllowed(snapshot), isFalse);
      final current = (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.books.clearBookAdultEvidence(current);
      expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
    });
  });

  test(
    'an identical completed observation invalidates the open review',
    () async {
      await _withFixture((f) async {
        await f.allowReview();
        await f.services.books.details(f.first, CancellationToken());
        final before = (await f.evidence.load())[f.first.id]!;
        final snapshot =
            (await f.services.books.bookPolicyReviewEntries()).single;
        await f.services.books.details(f.first, CancellationToken());
        final after = (await f.evidence.load())[f.first.id]!;
        expect(after.revision, before.revision + 1);
        expect(
          after.withRevision(before.revision).snapshotDigest,
          before.snapshotDigest,
        );
        await expectLater(
          f.services.books.clearBookAdultEvidence(snapshot),
          throwsFormatException,
        );
        expect(after.adult, isTrue);
      });
    },
  );

  test('a review lock rejects a new detail request', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      final entered = Completer<void>(), release = Completer<void>();
      f.services.books.beforeBookPolicyReviewWriteForTesting = () async {
        entered.complete();
        await release.future;
      };
      final review = f.services.books.clearBookAdultEvidence(snapshot);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        await expectLater(
          f.services.books.details(f.first, CancellationToken()),
          throwsA(isA<RequestCancelled>()),
        );
        expect(f.fake.requests, isEmpty);
      } finally {
        release.complete();
      }
      await review;
      expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
      f.services.books.beforeBookPolicyReviewWriteForTesting = null;
      await f.services.books.details(f.first, CancellationToken());
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
    });
  });

  test('a manual probe is registered before requesting book details', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      f.fake.holdNextResponse();
      final probe = f.services.books.probe(f.source, '测试', CancellationToken());
      try {
        await f.fake.requestStarted!.future.timeout(const Duration(seconds: 5));
        expect(await f.services.books.bookPolicyReviewEntries(), isEmpty);
        await expectLater(
          f.services.books.clearBookAdultEvidence(snapshot),
          throwsFormatException,
        );
      } finally {
        f.fake.releaseResponse();
      }
      await probe;
      expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      expect(f.services.books.bookPolicyReviewEntryAllowed(snapshot), isFalse);
    });
  });

  test('policy change after commit preserves the committed review', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      final committed = Completer<void>(), release = Completer<void>();
      f.services.books.afterBookPolicyReviewCommitForTesting = () async {
        committed.complete();
        await release.future;
      };
      final review = f.services.books.clearBookAdultEvidence(snapshot);
      try {
        await committed.future.timeout(const Duration(seconds: 5));
        await f.services.settings.update({'filterAdult': true});
        expect(f.services.books.bookAllowed(f.first), isFalse);
        expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
      } finally {
        release.complete();
      }
      await review;
      expect(f.services.books.bookAllowed(f.first), isTrue);
    });
  });

  test('close waits for an already committed review to publish', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      final committed = Completer<void>(), release = Completer<void>();
      f.services.books.afterBookPolicyReviewCommitForTesting = () async {
        committed.complete();
        await release.future;
      };
      final review = f.services.books.clearBookAdultEvidence(snapshot);
      late Future<void> closing;
      var closed = false;
      try {
        await committed.future.timeout(const Duration(seconds: 5));
        await f.services.settings.update({'filterAdult': true});
        closing = f.services.books.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
      } finally {
        release.complete();
      }
      await review;
      await closing;
      expect(closed, isTrue);
      expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
      expect(f.services.books.bookAllowed(f.first), isTrue);
    });
  });

  test(
    'close before registration prevents writes and notifier access',
    () async {
      await _withFixture((f) async {
        await f.seedAdult(f.first);
        await f.allowReview();
        final snapshot =
            (await f.services.books.bookPolicyReviewEntries()).single;
        final waiting = Completer<void>(), resume = Completer<void>();
        f.services.books.beforeBookPolicyReviewRegistrationForTesting =
            () async {
              waiting.complete();
              await resume.future;
            };
        final attempt = f.services.books.clearBookAdultEvidence(snapshot);
        final rejected = expectLater(attempt, throwsA(isA<ContentBlocked>()));
        try {
          await waiting.future.timeout(const Duration(seconds: 5));
          await f.services.books.close();
        } finally {
          resume.complete();
        }
        await rejected;
        expect((await f.evidence.load())[f.first.id]!.adult, isTrue);
      });
    },
  );

  test('a synchronous registration failure releases the review lock', () async {
    await _withFixture((f) async {
      await f.seedAdult(f.first);
      await f.allowReview();
      final snapshot =
          (await f.services.books.bookPolicyReviewEntries()).single;
      f.services.books.afterBookPolicyReviewRegistrationForTesting = () =>
          throw StateError('fixture synchronous failure');
      await expectLater(
        f.services.books.clearBookAdultEvidence(snapshot),
        throwsStateError,
      );
      f.services.books.afterBookPolicyReviewRegistrationForTesting = null;
      final refreshed =
          (await f.services.books.bookPolicyReviewEntries()).single;
      await f.services.books.clearBookAdultEvidence(refreshed);
      expect((await f.evidence.load())[f.first.id]!.adult, isFalse);
    });
  });
}

Future<void> _withFixture(Future<void> Function(_Fixture) action) async {
  final temp = await VerifiedTempDirectory.create('book-policy-review-');
  final file = File(path.join(temp.directory.path, 'book-review.sqlite'));
  final fake = _FakeClient();
  await HttpOverrides.runZoned(() async {
    final fixture = _Fixture(temp.directory, file, fake);
    try {
      await fixture.initialize();
      await action(fixture);
    } finally {
      try {
        fixture.fake.releaseResponse();
        await fixture.services.close();
      } finally {
        await temp.delete();
      }
    }
  }, createHttpClient: (_) => fake);
  expect(
    fake.requests.every((uri) => uri.host == 'book-review.example'),
    isTrue,
  );
}

final class _Fixture {
  _Fixture(this.root, this.database, this.fake);
  final Directory root;
  final File database;
  final _FakeClient fake;
  late AppServices services;
  late BookSource source;
  late Book first, second;
  late BookChapter chapter;
  BookPolicyEvidenceStore get evidence => BookPolicyEvidenceStore(services.db);

  Future<void> initialize() async {
    services = AppServices.scoped(root, AppDatabase(database));
    await services.db.write(
      'INSERT OR REPLACE INTO app_meta(key,value) VALUES(?,?)',
      [installationAccessKey, upgradedInstallationAccess],
    );
    await services.settings.load();
    await services.supervision.load();
    source = BookSource.fromJson({
      'name': '普通混合书源',
      'kind': 'text',
      'format': 'html',
      'url': 'https://book-review.example/',
      'legado': {
        'search': '/search?key={{key}}',
        'rules': {
          'searchList': '.bookbox',
          'searchTitle': 'a@text',
          'searchLink': 'a@href',
          'infoCategory': '.kind@text',
          'content': '#body@text',
        },
      },
    });
    await services.books.importSources([source]);
    await services.books.saveSource(source, {'enabled': true});
    first = Book(
      source.id,
      source.kind,
      '普通测试一',
      '作者',
      source.endpoint.resolve('/book/1'),
    );
    second = Book(
      source.id,
      source.kind,
      '普通测试二',
      '作者',
      source.endpoint.resolve('/book/2'),
    );
    chapter = BookChapter('第一章', source.endpoint.resolve('/chapter/1'));
    await services.books.store.saveBook(first, chapters: [chapter]);
    await services.books.store.saveBook(second, chapters: [chapter]);
    await services.books.store.saveText(first, chapter, '离线测试正文');
  }

  Future<void> seedAdult(Book book) async {
    await evidence.merge(
      book.id,
      BookPolicyEvidence(
        adult: true,
        keywordHashes: {
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        },
        normalizedTexts: {'普通作品作者'},
        latestText: '普通作品作者',
        textCoverageIncomplete: true,
      ),
      () {},
    );
    await services.books.refreshSourceRisks();
  }

  Future<void> allowReview() =>
      services.settings.update({'filterAdult': false});

  Future<void> restart() async {
    await services.close();
    services = AppServices.scoped(root, AppDatabase(database));
    await services.settings.load();
    await services.supervision.load();
    await services.books.ensureSourceRiskLoaded();
  }
}

final class _FakeClient implements HttpClient {
  final requests = <Uri>[];
  Completer<void>? requestStarted, _release;

  void holdNextResponse() {
    requestStarted = Completer<void>();
    _release = Completer<void>();
  }

  void releaseResponse() {
    final release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    requests.add(uri);
    if (method != 'GET' ||
        uri.host != 'book-review.example' ||
        !{'/book/1', '/search'}.contains(uri.path)) {
      throw const SocketException('all external network is disabled');
    }
    return _FakeRequest(uri, this);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this.client);
  @override
  final Uri uri;
  final _FakeClient client;
  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  Future<HttpClientResponse> close() async {
    final started = client.requestStarted;
    final release = client._release;
    if (started != null && release != null && uri.path == '/book/1') {
      if (!started.isCompleted) started.complete();
      try {
        await release.future;
      } finally {
        client.requestStarted = null;
        client._release = null;
      }
    }
    return _FakeResponse(
      uri.path == '/search'
          ? '<div class="bookbox"><a href="/book/1">普通测试一</a></div>'
          : '<div class="kind">情欲小说</div>',
    );
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeResponse(this.body);
  final String body;
  @override
  int get statusCode => 200;
  @override
  final HttpHeaders headers = _FakeHeaders()
    ..set('content-type', 'text/html; charset=utf-8');
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeHeaders implements HttpHeaders {
  final values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = [value.toString()];
  @override
  String? value(String name) => values[name.toLowerCase()]?.firstOrNull;
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
