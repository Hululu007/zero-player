import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'publication_http.dart';

final _indexWhitespace = RegExp(r'\s+');

Future<List<PublicationEdition>> searchPublicationIndex(
  List<PublicationEdition> books,
  String query,
  CancellationToken token, {
  required int limit,
  required bool Function(String) allowed,
  PublicationFieldSearch? filter,
}) async {
  final isbn = filter == null ? normalizedIsbn(query) : '';
  final words = filter == null && isbn.isEmpty && query.isNotEmpty
      ? query.toLowerCase().split(_indexWhitespace)
      : const <String>[];
  final result = <PublicationEdition>[];
  token.check();
  for (final (index, book) in books.indexed) {
    if (index != 0 && index % 512 == 0) {
      await Future<void>.delayed(Duration.zero);
      token.check();
    }
    final matches =
        filter?.matches(book) ??
        (isbn.isNotEmpty
            ? book.isbn == isbn
            : words.isEmpty || words.every(book.searchable.contains));
    if (matches && allowed('${book.title} ${book.author}')) {
      result.add(book);
      if (result.length == limit) break;
    }
  }
  return result;
}

abstract interface class PublicationCatalogue {
  Future<void> check(CancellationToken token);

  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
  });
}

abstract interface class DownloadablePublicationCatalogue
    implements PublicationCatalogue {
  Future<PublicationDownload> download(
    AcquisitionCandidate candidate,
    CancellationToken token,
  );
}

abstract interface class SharedPublicationCatalogue
    implements PublicationCatalogue {
  void restrictShare(Uri? page, Uri link);
}

abstract interface class ResourcePublicationCatalogue
    implements PublicationCatalogue {
  Future<List<PublicationResource>> loadResources(
    Uri page,
    CancellationToken token,
  );
}

abstract interface class ProgressivePublicationCatalogue
    implements PublicationCatalogue {
  @override
  Future<List<PublicationEdition>> search(
    String query,
    CancellationToken token, {
    required int maxPages,
    required bool Function(String) allowed,
    PublicationFieldSearch? filter,
    Future<void> Function(List<PublicationEdition>)? onProgress,
  });
}
