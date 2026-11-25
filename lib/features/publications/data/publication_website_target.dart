import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'publication_http.dart';
import 'publication_kgbook_rows.dart';
import 'publication_share_provider.dart';
import 'publication_sources.dart';

/// A download explicitly refused due to the site's guest quota supplies the
/// entry point. Forms cannot select the source or its origin.
final class PublicationWebsiteTarget {
  PublicationWebsiteTarget._(this.source, this.address, this.task);

  final PublicationSource source;
  final Uri address;
  final AcquisitionTask task;

  String get origin => address.origin;
  PublicationFormat get format => task.candidate.format;
  String get titleForPolicy =>
      '${task.edition.title} ${task.edition.author} ${address.host}';

  static PublicationWebsiteTarget? forTask(
    PublicationSource? source,
    AcquisitionTask task,
  ) {
    final candidate = task.candidate;
    if (source == null ||
        !const {
          AcquisitionState.failed,
          AcquisitionState.paused,
        }.contains(task.state) ||
        !_guestRefusal(task) ||
        source.id != candidate.source ||
        candidate.fileId != null ||
        !publicationSameWebsite(source.endpoint, candidate.link)) {
      return null;
    }
    if (source.configurable) {
      final format = candidate.format.name;
      if (!source.field.containsKey(format) &&
          source.rule?.detail.containsKey(format) != true) {
        return null;
      }
    } else {
      if (source.id != kgbookSource ||
          kgbookBookNumber(candidate.link) == null ||
          kgbookEditionId(candidate.link) != task.edition.id ||
          candidate.page != candidate.link) {
        return null;
      }
    }
    final page = candidate.page;
    return PublicationWebsiteTarget._(
      source,
      page != null && publicationSameWebsite(source.endpoint, page)
          ? page
          : candidate.link,
      task,
    );
  }

  bool allows(Uri uri) => publicationSameWebsite(address, uri);

  void restrict(Uri uri) {
    if (!allows(uri)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }
}

bool _guestRefusal(AcquisitionTask task) {
  if (task.problem != null) {
    return task.problem == PublicationProblem.guestLimit;
  }
  return task.state == AcquisitionState.paused &&
      task.failures
              .where((failure) => failure.candidate == task.selected)
              .lastOrNull
              ?.problem ==
          PublicationProblem.guestLimit;
}

bool publicationSameWebsite(Uri origin, Uri address) {
  if (origin.scheme != 'https' ||
      origin.port != 443 ||
      origin.userInfo.isNotEmpty ||
      address.scheme != 'https' ||
      address.port != 443 ||
      address.host != origin.host ||
      !_publicHost.hasMatch(address.host) ||
      PublicationShareProvider.of(address) != PublicationShareProvider.direct) {
    return false;
  }
  try {
    validatePublicationAddress(address);
    return !Uri.decodeFull(address.toString()).contains(r'\');
  } on Exception {
    return false;
  }
}

final _publicHost = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$',
);
