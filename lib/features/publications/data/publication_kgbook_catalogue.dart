import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_kgbook_download.dart';
import 'publication_kgbook_rows.dart';

export 'publication_kgbook_rows.dart' show kgbookSource, parseKgbookCatalogue;

final kgbookCatalogueEndpoint = kgbookListing(kgbookUpdates);

final class KgbookCatalogue
    implements
        ProgressivePublicationCatalogue,
        DownloadablePublicationCatalogue,
        ResourcePublicationCatalogue {
  KgbookCatalogue(this.http) : _downloads = KgbookDownloads(http);

  final PublicationHttp http;
  final KgbookDownloads _downloads;
  final _freshPages = <Uri, ({KgbookPage page, DateTime expires})>{};

  @override
  Future<void> check(CancellationToken token) async {
    await _page(kgbookCatalogueEndpoint, token, recheck: true);
  }

  @override
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  ) => _downloads.resources(page, token);

  @override
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  ) => _downloads.resolve(candidate, token);

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    bool matches(PublicationEdition book) =>
        book.matches(query, filter: filter) &&
        allowed('${book.title} ${book.author}');
    http.authorize(kgbookCatalogueEndpoint);
    if (query.isNotEmpty) {
      final index = await (_index ??= _loadIndex());
      token.check();
      final hits = index.where(matches).toList();
      if (hits.isNotEmpty) return hits;
    }

    final found = <String, PublicationEdition>{};
    Uri? next = kgbookCatalogueEndpoint;
    try {
      for (var i = 0; i < maxPages && next != null; i++) {
        final page = await _page(next, token);
        token.check();
        final before = found.length;
        for (final edition in page.editions.where(matches)) {
          found.putIfAbsent(edition.id, () => edition);
        }
        next = page.next;
        if (onProgress != null &&
            found.length != before &&
            next != null &&
            i + 1 < maxPages) {
          await onProgress(found.values.toList());
        }
      }
    } on Exception catch (error) {
      if (!_listingUnavailable(error)) rethrow;
      if (found.isNotEmpty) return found.values.toList();
      if (query.isNotEmpty) rethrow;
      final index = await (_index ??= _loadIndex());
      token.check();
      return index.where(matches).take(20 * maxPages).toList();
    }
    return found.values.toList();
  }

  Future<List<PublicationEdition>>? _index;

  Future<List<PublicationEdition>> _loadIndex() async {
    final raw = await rootBundle.loadString(kgbookIndexAsset);
    final data = jsonDecode(raw);
    if (data is! List || data.isEmpty || data.length > 10000) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return [
      for (final row in data)
        if (row case [String path, String title, String author, String format])
          ?kgbookEdition(path, title, author, format),
    ];
  }

  Future<KgbookPage> _page(
    Uri address,
    CancellationToken token, {
    bool recheck = false,
  }) async {
    token.check();
    http.authorize(address);
    final cached = _freshPages[address];
    if (!recheck && cached != null && cached.expires.isAfter(DateTime.now())) {
      return cached.page;
    }
    _freshPages.remove(address);
    void restrict(Uri target) {
      if (!kgbookPublicAddress(target) ||
          (target.path != address.path &&
              !(address.path.endsWith('/') &&
                  target.path == '${address.path}index.html'))) {
        throw const PublicationFailure(PublicationProblem.unsupported);
      }
    }

    return withPublicationRequestDeadline(token, publicationCatalogueDeadline, (
      request,
    ) async {
      final response = await http.open(
        address,
        request,
        scope: restrict,
        interactive: currentRequestPriority != RequestPriority.background,
        acceptGzip: true,
      );
      final body = await http.readText(
        response,
        request,
        maxBytes: 256 << 10,
        allowGzip: true,
        scope: restrict,
      );
      final page = parseKgbookCatalogue(body, address);
      if (page.editions.isEmpty) {
        throw const PublicationFailure(PublicationProblem.invalid);
      }
      final now = DateTime.now();
      final expires = kgbookFreshUntil(response.response.headers, now);
      if (expires != null) {
        _freshPages[address] = (page: page, expires: expires);
      }
      return page;
    });
  }
}

bool _listingUnavailable(Exception error) =>
    isPublicationNetworkFailure(error) ||
    error is PublicationFailure &&
        const {
          PublicationProblem.missing,
          PublicationProblem.invalid,
          PublicationProblem.challenge,
          PublicationProblem.rateLimit,
        }.contains(error.problem);
