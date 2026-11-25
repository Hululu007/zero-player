import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';

typedef PublicationListingPage = ({
  List<PublicationEdition> books,
  bool hasNext,
});

/// Uses a site's reviewed listing and search URLs. Only the parser interprets
/// the response. URLs in the response cannot schedule further requests.
final class PublicListingCatalogue implements ProgressivePublicationCatalogue {
  const PublicListingCatalogue(
    this.http, {
    required this.address,
    required this.parse,
    this.requestBody,
    this.requestForm,
    this.referer,
    this.maxBytes = 640 << 10,
    this.deadline = const Duration(seconds: 10),
    this.allowEmptyBrowse = false,
    this.searchLocally = false,
    this.completeRange = false,
    this.encoding = utf8,
    this.legacyQueryEncoding = false,
  }) : assert(requestBody == null || requestForm == null),
       assert(!completeRange || (requestBody == null && requestForm == null));

  final PublicationHttp http;
  final Uri Function(String query, int page) address;
  final PublicationListingPage Function(String body) parse;
  final Map<String, Object?> Function(String query, int page)? requestBody;
  final Map<String, String> Function(String query, int page)? requestForm;
  final Uri? referer;
  final int maxBytes;
  final Duration deadline;
  final bool allowEmptyBrowse;
  final bool searchLocally;
  final bool completeRange;
  final Encoding encoding;
  final bool legacyQueryEncoding;

  @override
  Future<void> check(CancellationToken token) async {
    final books = await search('', token, maxPages: 1, allowed: (_) => true);
    if (books.isEmpty && !allowEmptyBrowse) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
  }

  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  }) async {
    final results = <String, PublicationEdition>{};
    final seen = <String>{};
    for (var index = 1; index <= maxPages.clamp(1, 5); index++) {
      final Uri target = address(searchLocally ? '' : query, index);
      final PublicationListingPage page;
      try {
        page = parse(
          await publicListingText(
            http,
            target,
            token,
            maxBytes: maxBytes,
            deadline: deadline,
            completeRange: completeRange,
            encoding: encoding,
            legacyQueryEncoding: legacyQueryEncoding,
            json: requestBody?.call(query, index),
            form: requestForm?.call(query, index),
            referer: referer,
          ),
        );
      } on Exception catch (error) {
        token.check();
        if (results.isEmpty || !isPublicationNetworkFailure(error)) rethrow;
        break;
      }
      final before = results.length;
      var fresh = false;
      for (final book in page.books) {
        if (!seen.add(book.id)) continue;
        fresh = true;
        final matches = searchLocally
            ? book.matches(query, filter: filter)
            : filter?.matches(book) != false;
        if (matches && allowed('${book.title} ${book.author}')) {
          results[book.id] = book;
        }
      }
      if (!page.hasNext ||
          (page.books.isNotEmpty && !fresh) ||
          results.length >= 60) {
        break;
      }
      if (before != results.length && index < maxPages) {
        await onProgress?.call(results.values.take(60).toList());
      }
    }
    return results.values.take(60).toList();
  }
}

Future<String> publicListingText(
  PublicationHttp http,
  Uri address,
  CancellationToken token, {
  int maxBytes = 640 << 10,
  Duration deadline = const Duration(seconds: 10),
  bool completeRange = false,
  Encoding encoding = utf8,
  bool legacyQueryEncoding = false,
  Map<String, Object?>? json,
  Map<String, String>? form,
  Uri? referer,
}) {
  assert(!completeRange || (json == null && form == null));
  void scope(Uri target) {
    if (target != address) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  if (!completeRange) {
    return http.text(
      address,
      token,
      maxBytes: maxBytes,
      allowGzip: true,
      deadline: deadline,
      scope: scope,
      json: json,
      form: form,
      referer: referer,
      encoding: encoding,
      legacyQueryEncoding: legacyQueryEncoding && address.hasQuery,
    );
  }
  return withPublicationRequestDeadline(token, deadline, (request) async {
    final payload = await http.open(
      address,
      request,
      scope: scope,
      redirect: false,
      range: 'bytes=0-${maxBytes - 1}',
      referer: referer,
      legacyQueryEncoding: legacyQueryEncoding && address.hasQuery,
    );
    int? length;
    if (payload.response.statusCode == 206) {
      final range = _completedRange.firstMatch(
        payload.response.headers.value('content-range') ?? '',
      );
      final end = int.tryParse(range?[1] ?? '');
      length = int.tryParse(range?[2] ?? '');
      if (end == null ||
          length == null ||
          end + 1 != length ||
          length > maxBytes) {
        await discardPublicationResponse(payload);
        throw const PublicationFailure(PublicationProblem.invalid);
      }
    }
    final body = await http.readText(
      payload,
      request,
      maxBytes: maxBytes,
      scope: scope,
      acceptedStatuses: const {200, 206},
      encoding: encoding,
    );
    if (length != null && encoding.encode(body).length != length) {
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    return body;
  });
}

final _completedRange = RegExp(r'^bytes 0-([0-9]+)/([0-9]+)$');

Uri? publicListingLink(Uri base, String? raw, RegExp path) {
  if (raw == null || raw.length > 512) return null;
  final input = Uri.tryParse(raw.trim());
  if (input == null) return null;
  final link = base.resolveUri(input);
  return link.scheme == base.scheme &&
          const {'http', 'https'}.contains(link.scheme) &&
          link.origin == base.origin &&
          link.userInfo.isEmpty &&
          !link.hasQuery &&
          !link.hasFragment &&
          path.hasMatch(link.path)
      ? link
      : null;
}
