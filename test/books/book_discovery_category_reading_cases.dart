part of 'book_discovery_category_policy_test.dart';

void _detailsTargetTests() {
  test(
    'details rejects a restricted redirect but allows an ordinary one',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('details-guard.example');
        await f.install(source);
        final book = _readingBook(source);
        f.redirects['/book/1'] = '/adult';
        await expectLater(
          f.repo.details(book, CancellationToken()),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), ['/book/1']);
        f.requests.clear();
        f.redirects['/book/1'] = '/safe';
        await f.repo.details(book, CancellationToken());
        expect(f.requests.map((request) => request.$2.path), [
          '/book/1',
          '/safe',
        ]);
        f.requests.clear();
        f.redirects['/book/1'] = '/adult';
        await f.services.settings.update({'filterAdult': false});
        await f.repo.details(book, CancellationToken());
        expect(f.requests.map((request) => request.$2.path), [
          '/book/1',
          '/adult',
        ]);
      });
    },
  );

  test(
    'encoded redirect targets are stopped before a second request',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('encoded-guard.example');
        await f.install(source);
        final book = _readingBook(source);
        for (final target in ['/%2Fadult', '/%5Cadult']) {
          f.redirects['/book/1'] = target;
          f.requests.clear();
          await expectLater(
            f.repo.details(book, CancellationToken()),
            throwsA(anything),
          );
          expect(f.requests.map((request) => request.$2.path), [
            '/book/1',
          ], reason: target);
        }
        f.redirects['/book/1'] = '/safe';
        f.requests.clear();
        await f.repo.details(book, CancellationToken());
        expect(f.requests.map((request) => request.$2.path), [
          '/book/1',
          '/safe',
        ]);
      });
    },
  );
}

void _directoryTargetTests() {
  test('directory validates linked GET and POST targets', () async {
    await _withFixture((f) async {
      final source = _readingSource('toc-guard.example');
      await f.install(source);
      final book = _readingBook(source);
      f.pages['/book/1'] = '<a class="toc" href="/adult">目录</a>';
      await expectLater(
        f.repo.chapters(book, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/book/1']);
      f.requests.clear();
      f.pages['/book/1'] =
          '<a class="chapter" href="/chapter/1">第一章</a><a class="nexttoc" href="/adult">下一页</a>';
      await expectLater(
        f.repo.chapters(book, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/book/1']);
      f.requests.clear();
      f.pages['/book/1'] =
          '''<a class="toc" href='/list,{"method":"POST","body":"kind=adult"}'>目录</a>''';
      await expectLater(
        f.repo.chapters(book, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/book/1']);
      f.requests.clear();
      f.pages['/book/1'] =
          '''<a class="toc" href='/list,{"method":"POST","body":"kind=normal"}'>目录</a>''';
      f.pages['/list'] = '<a class="chapter" href="/chapter/1">第一章</a>';
      final chapters = await f.repo.chapters(book, CancellationToken());
      expect(chapters.map((chapter) => chapter.title), ['第一章']);
      expect(f.requests.map((request) => request.$1), ['GET', 'POST']);
      expect(f.requests.map((request) => request.$2.path), [
        '/book/1',
        '/list',
      ]);
    });
  });
}

void _textAndStoredTargetTests() {
  test(
    'reading and download reject restricted redirects and continuation pages',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('content-guard.example');
        await f.install(source);
        final book = _readingBook(source);
        final chapter = BookChapter(
          '第一章',
          source.endpoint.resolve('/chapter/1'),
        );
        f.redirects['/chapter/1'] = '/adult';
        await expectLater(
          f.repo.readText(book, chapter, CancellationToken()),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
        expect(await f.repo.store.readingCache(book, chapter), isNull);
        f.redirects.clear();
        f.requests.clear();
        f.pages['/chapter/1'] =
            '<p class="body">普通正文</p><a class="next" href="/adult">下一页</a>';
        await expectLater(
          f.repo.readText(book, chapter, CancellationToken()),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
        expect(await f.repo.store.readingCache(book, chapter), isNull);
        f.requests.clear();
        await expectLater(
          f.repo.download(book, chapter, CancellationToken()),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
        expect(await f.repo.store.provenText(book, chapter), isNull);
        f.requests.clear();
        f.pages['/chapter/1'] = '<p class="body">普通正文</p>';
        expect(
          await f.repo.readText(book, chapter, CancellationToken()),
          '普通正文',
        );
        expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
      });
    },
  );

  test(
    'stored and requested chapter targets honor static restrictions',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('stored-chapters.example');
        await f.install(source);
        final book = _readingBook(source);
        final blocked = BookChapter('普通章节', source.endpoint.resolve('/adult'));
        final normal = BookChapter(
          '普通章节二',
          source.endpoint.resolve('/chapter/2'),
        );
        await f.repo.store.saveBook(book, chapters: [blocked, normal]);
        final stored = await f.repo.chapters(book, CancellationToken());
        expect(stored.map((chapter) => chapter.uri.path), ['/chapter/2']);
        await expectLater(
          f.repo.readText(book, blocked, CancellationToken()),
          throwsA(isA<ContentBlocked>()),
        );
        expect(f.requests, isEmpty);
      });
    },
  );
}

void _inFlightPolicyTests() {
  test(
    'filter and source changes cancel an in-flight detail request',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('inflight-details.example');
        await f.install(source);
        final book = _readingBook(source);
        final firstGate = f.hold('/book/1');
        final first = expectLater(
          f.repo.details(book, CancellationToken()),
          throwsA(anything),
        );
        await firstGate.started.future.timeout(const Duration(seconds: 5));
        await f.services.settings.update({'filterAdult': false});
        await f.services.settings.update({'filterAdult': true});
        firstGate.release();
        await first.timeout(const Duration(seconds: 5));
        final secondGate = f.hold('/book/1');
        final second = expectLater(
          f.repo.details(book, CancellationToken()),
          throwsA(anything),
        );
        await secondGate.started.future.timeout(const Duration(seconds: 5));
        await f.repo.saveSource(source, {'enabled': false});
        await f.repo.saveSource(source, {'enabled': true});
        secondGate.release();
        await second.timeout(const Duration(seconds: 5));
      });
    },
  );

  test('filter changes cancel in-flight text before it is cached', () async {
    await _withFixture((f) async {
      final source = _readingSource('inflight-content.example');
      await f.install(source);
      final book = _readingBook(source);
      final chapter = BookChapter('第一章', source.endpoint.resolve('/chapter/1'));
      f.pages['/chapter/1'] = '<p class="body">普通正文</p>';
      final gate = f.hold('/chapter/1');
      final running = expectLater(
        f.repo.readText(book, chapter, CancellationToken()),
        throwsA(anything),
      );
      await gate.started.future.timeout(const Duration(seconds: 5));
      await f.services.settings.update({'filterAdult': false});
      await f.services.settings.update({'filterAdult': true});
      gate.release();
      await running.timeout(const Duration(seconds: 5));
      expect(await f.repo.store.readingCache(book, chapter), isNull);
    });
  });

  test(
    'policy changes cancel a probe without persisting stale health',
    () async {
      await _withFixture((f) async {
        final source = _readingSource('probe-inflight.example');
        await f.install(source);
        final before = (await f.repo.sourceEntry(BookKind.text, source.id))!;
        final gate = f.hold('/normal');
        final running = expectLater(
          f.repo.probe(source, '', CancellationToken()),
          throwsA(isA<RequestCancelled>()),
        );
        await gate.started.future.timeout(const Duration(seconds: 5));
        await f.services.settings.update({'filterAdult': false});
        await f.services.settings.update({'filterAdult': true});
        gate.release();
        await running.timeout(const Duration(seconds: 5));
        final after = (await f.repo.sourceEntry(BookKind.text, source.id))!;
        expect(after.health, before.health);
        expect(after.checkedAt, before.checkedAt);
      });
    },
  );
}

void _nonLegadoTargetTests() {
  test('non-Legado HTML uses the same target guard', () async {
    await _withFixture((f) async {
      final source = BookSource.fromJson({
        'name': '普通静态阅读源',
        'url': 'https://plain-reading.example/',
        'kind': 'text',
        'format': 'html',
        'search': '/search/{key}',
        'discoveryCategories': [
          {'title': '肉文', 'url': '/adult'},
          {'title': '普通', 'url': '/normal'},
        ],
        'rules': {
          'list': '.bookbox',
          'title': 'a@text',
          'book': 'a@href',
          'infoDescription': '.description@text',
          'toc': '.toc@href',
          'chapters': '.chapter',
          'chapterTitle': '@text',
          'chapterUrl': '@href',
          'content': '.body@text',
          'nextContent': '.next@href',
        },
      });
      await f.install(source);
      final book = _readingBook(source);
      f.redirects['/book/1'] = '/adult';
      await expectLater(
        f.repo.details(book, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/book/1']);
      f.requests.clear();
      f.redirects.clear();
      f.pages['/book/1'] = '<a class="toc" href="/adult">目录</a>';
      await expectLater(
        f.repo.chapters(book, CancellationToken()),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/book/1']);
      f.requests.clear();
      f.pages['/chapter/1'] =
          '<p class="body">普通正文</p><a class="next" href="/adult">下一页</a>';
      await expectLater(
        f.repo.readText(
          book,
          BookChapter('第一章', source.endpoint.resolve('/chapter/1')),
          CancellationToken(),
        ),
        throwsA(anything),
      );
      expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
    });
  });
}

void _comicTargetTests() {
  test(
    'comic image extraction, redirects and downloads reject restricted targets',
    () async {
      await _withFixture((f) async {
        final source = _mediaSource('comic-guard.example', BookKind.comic);
        await f.install(source);
        final book = _mediaBook(source);
        final chapter = BookChapter(
          '第一话',
          source.endpoint.resolve('/chapter/1'),
        );
        f.pages['/chapter/1'] = '<img src="/adult">';
        await expectLater(
          f.repo.chapterImages(book, chapter, CancellationToken()),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), ['/chapter/1']);
        f.requests.clear();
        f.pages['/chapter/1'] = '<img src="/safe-redirect.png">';
        f.redirects['/safe-redirect.png'] = '/adult';
        final redirectImages = await f.repo.chapterImages(
          book,
          chapter,
          CancellationToken(),
        );
        await expectLater(
          f.repo.chapterImageBytes(
            book,
            redirectImages.single,
            CancellationToken(),
            chapter: chapter,
          ),
          throwsA(anything),
        );
        expect(f.requests.map((request) => request.$2.path), [
          '/chapter/1',
          '/safe-redirect.png',
        ]);
        expect(
          await f.repo.store.readingImage(book, redirectImages.single),
          isNull,
        );
        f.requests.clear();
        f.pages['/chapter/1'] = '<img src="/safe.png">';
        f.media['/safe.png'] = (
          ContentType('image', 'png'),
          [137, 80, 78, 71, 1, 2, 3],
        );
        await f.repo.download(book, chapter, CancellationToken());
        expect(
          (await f.repo.store.offlineImageAddresses(
            book,
            chapter,
          ))!.single.path,
          '/safe.png',
        );
        expect(f.requests.map((request) => request.$2.path), [
          '/chapter/1',
          '/safe.png',
        ]);

        final second = BookChapter(
          '第二话',
          source.endpoint.resolve('/chapter/2'),
        );
        f.pages['/chapter/2'] = '<img src="/slow.png">';
        f.media['/slow.png'] = (
          ContentType('image', 'png'),
          [137, 80, 78, 71, 9],
        );
        final gate = f.hold('/slow.png');
        final pending = expectLater(
          f.repo.download(book, second, CancellationToken()),
          throwsA(anything),
        );
        await gate.started.future.timeout(const Duration(seconds: 5));
        await f.services.settings.update({'filterAdult': false});
        await f.services.settings.update({'filterAdult': true});
        gate.release();
        await pending.timeout(const Duration(seconds: 5));
        expect(await f.repo.store.offlineImageAddresses(book, second), isNull);
        await f.services.settings.update({'filterAdult': false});
        f.requests.clear();
        final unfiltered = BookChapter(
          '第三话',
          source.endpoint.resolve('/chapter/3'),
        );
        f.pages['/chapter/3'] = '<img src="/adult">';
        f.media['/adult'] = (ContentType('image', 'png'), [137, 80, 78, 71, 5]);
        final images = await f.repo.chapterImages(
          book,
          unfiltered,
          CancellationToken(),
        );
        expect(
          await f.repo.chapterImageBytes(
            book,
            images.single,
            CancellationToken(),
            chapter: unfiltered,
          ),
          [137, 80, 78, 71, 5],
        );
        expect(f.requests.map((request) => request.$2.path), [
          '/chapter/3',
          '/adult',
        ]);
      });
    },
  );
}

void _audioTargetTests() {
  test(
    'audio resolution and download guard every target and redirect',
    () async {
      await _withFixture((f) async {
        final source = _mediaSource('audio-guard.example', BookKind.audio);
        await f.install(source);
        final book = _mediaBook(source);
        final chapter = BookChapter(
          '第一章',
          source.endpoint.resolve('/audio-page'),
        );
        final repo = BooksRepository(
          f.services.db,
          f.services.root,
          f.services.offline,
          f.services.contentPolicy,
          (_, _, _) async {},
        );
        try {
          await repo.ensureSourceRiskLoaded();
          f.pages['/audio-page'] = '<audio src="/adult"></audio>';
          await expectLater(
            repo.download(book, chapter, CancellationToken()),
            throwsA(anything),
          );
          expect(f.requests.map((request) => request.$2.path), ['/audio-page']);
          expect(await repo.store.provenAudio(book, chapter), isNull);
          f.requests.clear();
          f.pages['/audio-page'] = '<audio src="/media-redirect.mp3"></audio>';
          f.redirects['/media-redirect.mp3'] = '/adult';
          await expectLater(
            repo.download(book, chapter, CancellationToken()),
            throwsA(anything),
          );
          expect(f.requests.map((request) => request.$2.path), [
            '/audio-page',
            '/media-redirect.mp3',
          ]);
          expect(await repo.store.provenAudio(book, chapter), isNull);
          f.requests.clear();
          f.pages['/audio-page'] = '<audio src="/safe.mp3"></audio>';
          f.media['/safe.mp3'] = (
            ContentType('audio', 'mpeg'),
            [73, 68, 51, ...List<int>.filled(125, 0)],
          );
          await repo.download(book, chapter, CancellationToken());
          expect(await repo.store.provenAudio(book, chapter), isNotNull);
          expect(f.requests.map((request) => request.$2.path), [
            '/audio-page',
            '/safe.mp3',
          ]);

          final second = BookChapter(
            '第二章',
            source.endpoint.resolve('/audio-page-2'),
          );
          f.pages['/audio-page-2'] = '<audio src="/slow.mp3"></audio>';
          f.media['/slow.mp3'] = (
            ContentType('audio', 'mpeg'),
            [73, 68, 51, ...List<int>.filled(125, 0)],
          );
          final gate = f.hold('/slow.mp3');
          final pending = expectLater(
            repo.download(book, second, CancellationToken()),
            throwsA(anything),
          );
          await gate.started.future.timeout(const Duration(seconds: 5));
          await f.services.settings.update({'filterAdult': false});
          await f.services.settings.update({'filterAdult': true});
          gate.release();
          await pending.timeout(const Duration(seconds: 5));
          expect(await repo.store.provenAudio(book, second), isNull);
          await f.services.settings.update({'filterAdult': false});
          f.requests.clear();
          final unfiltered = BookChapter(
            '第三章',
            source.endpoint.resolve('/audio-page-3'),
          );
          f.pages['/audio-page-3'] = '<audio src="/adult"></audio>';
          f.media['/adult'] = (
            ContentType('audio', 'mpeg'),
            [73, 68, 51, ...List<int>.filled(125, 0)],
          );
          await repo.download(book, unfiltered, CancellationToken());
          expect(await repo.store.provenAudio(book, unfiltered), isNotNull);
          expect(f.requests.map((request) => request.$2.path), [
            '/audio-page-3',
            '/adult',
          ]);
        } finally {
          await repo.close();
        }
      });
    },
  );
}

void _mediaProbeTargetTests() {
  test('media probes reject restricted image and audio redirects', () async {
    await _withFixture((f) async {
      for (final kind in [BookKind.comic, BookKind.audio]) {
        final base = _mediaSource('probe-${kind.name}.example', kind);
        final spec = base.legado!.toJson();
        final source = BookSource.fromJson({
          ...base.toJson(),
          'legado': {
            ...spec,
            'search': '/search?key={{key}}',
            'rules': {
              ...(spec['rules'] as Map),
              'searchList': '.bookbox',
              'searchTitle': '.bookname a@text',
              'searchLink': '.bookname a@href',
              'chapters': '.chapter',
              'chapterTitle': '@text',
              'chapterUrl': '@href',
            },
          },
        });
        await f.install(source);
        f.pages['/book/1'] = '<a class="chapter" href="/chapter/1">第一章</a>';
        final mediaPath = kind == BookKind.comic ? '/probe.png' : '/probe.mp3';
        f.pages['/chapter/1'] = kind == BookKind.comic
            ? '<img src="$mediaPath">'
            : '<audio src="$mediaPath"></audio>';
        f.redirects[mediaPath] = '/adult';
        f.requests.clear();
        await f.repo.probe(source, '星际', CancellationToken());
        expect(f.requests.map((request) => request.$2.path), [
          '/search',
          '/book/1',
          '/chapter/1',
          mediaPath,
        ]);
      }
    });
  });
}
