import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'lanzou_public_share.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';
import 'publication_sources.dart';
import 'quark_public_share.dart';
import 'uc_public_share.dart';

bool requiresPublicationFileChoice(AcquisitionCandidate candidate) =>
    candidate.source != 'manual' &&
    candidate.fileId == null &&
    candidate.sharedFileName == null &&
    PublicationShareProvider.of(candidate.link).listsFiles;

final class PublicationShareResolver {
  PublicationShareResolver(this.http)
    : _lanzou = LanzouPublicShare(http),
      _quark = QuarkPublicShare(http),
      _uc = UcPublicShare(http);
  final PublicationHttp http;
  final LanzouPublicShare _lanzou;
  final QuarkPublicShare _quark;
  final UcPublicShare _uc;

  Future<List<PublicationSharedFile>> inspect(
    Uri target,
    String? code,
    CancellationToken token,
  ) async {
    http.authorize(target);
    validatePublicationAddress(target, allowLoopback: http.allowLoopback);
    return switch (PublicationShareProvider.of(target)) {
      PublicationShareProvider.quark => _quark.inspect(target, code, token),
      PublicationShareProvider.uc => _uc.inspect(target, code, token),
      PublicationShareProvider.lanzou => [
        for (final file in await _lanzou.inspect(target, code, token))
          if (PublicationFormat.fromName(file.name)
              case final PublicationFormat format)
            (name: file.name, id: file.id, format: format, bytes: null),
      ],
      PublicationShareProvider.direct => [
        if (PublicationFormat.fromName(target.path)
            case final PublicationFormat format)
          (
            name: publicationLabel(target.pathSegments.last),
            id: null,
            format: format,
            bytes: null,
          ),
      ],
      final provider => throw _unsupported(provider),
    };
  }

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    PublicationSource? source,
    String? code,
    CancellationToken token,
  ) async {
    final link = candidate.link;
    validatePublicationAddress(link, allowLoopback: http.allowLoopback);
    http.authorize(link);
    if (source?.configurable == true) source!.restrict(link);
    if (requiresPublicationFileChoice(candidate)) {
      throw const PublicationFailure(PublicationProblem.shareFile);
    }
    if (code == null && candidate.publishedAccess?.needsConfirmation == true) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final provider = PublicationShareProvider.of(link);
    if (provider == PublicationShareProvider.quark) {
      return _quark.resolve(candidate, code, token);
    }
    if (provider == PublicationShareProvider.uc) {
      return _uc.resolve(candidate, code, token);
    }
    if (provider == PublicationShareProvider.lanzou) {
      return _lanzou.resolve(candidate, code, token);
    }
    if (provider != PublicationShareProvider.direct) {
      throw _unsupported(provider);
    }
    if (source?.configurable == true) {
      return PublicationDownload(link, scope: source!.restrict);
    }
    if (source?.kind == PublicationSourceKind.releases) {
      return PublicationDownload(
        link,
        scope: (target) => restrictPinnedPublication(source!, target),
      );
    }
    if (source?.id == 'open-textbooks') {
      return PublicationDownload(
        link,
        scope: (target) {
          if (target.scheme != 'https' ||
              target.port != 443 ||
              target.host != link.host) {
            throw const PublicationFailure(PublicationProblem.unsupported);
          }
        },
      );
    }
    return PublicationDownload(link);
  }

  PublicationFailure _unsupported(PublicationShareProvider provider) =>
      PublicationFailure(switch (provider) {
        PublicationShareProvider.baidu ||
        PublicationShareProvider.pan123 => PublicationProblem.login,
        _ => PublicationProblem.unsupported,
      });
}
