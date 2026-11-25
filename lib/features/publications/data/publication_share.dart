import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'aliyun_share_preview.dart';
import 'baidu_public_share.dart';
import 'cloud_drive_accounts.dart';
import 'cloud_shared_file.dart';
import 'lanzou_public_share.dart';
import 'mobile_public_share.dart';
import 'pan123_public_share.dart';
import 'publication_catalogue.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';
import 'publication_sources.dart';
import 'publication_website_target.dart';
import 'quark_public_share.dart';
import 'tianyi_public_share.dart';
import 'uc_public_share.dart';

bool requiresPublicationFileChoice(AcquisitionCandidate candidate) =>
    candidate.source != 'manual' &&
    candidate.fileId == null &&
    candidate.sharedFileName == null &&
    PublicationShareProvider.of(candidate.link).listsFiles;

final class PublicationShareResolver {
  PublicationShareResolver(this.http, {this.catalogueFor, this.cloudAccounts})
    : _aliyun = AliyunSharePreview(http),
      _baidu = BaiduPublicShare(http),
      _lanzou = LanzouPublicShare(http),
      _quark = QuarkPublicShare(http),
      _mobile = MobilePublicShare(http),
      _pan123 = Pan123PublicShare(http),
      _tianyi = TianyiPublicShare(http),
      _uc = UcPublicShare(http);
  final PublicationHttp http;
  final PublicationCatalogue? Function(PublicationSource)? catalogueFor;
  final CloudDriveAccounts? cloudAccounts;
  final BaiduPublicShare _baidu;
  final AliyunSharePreview _aliyun;
  final MobilePublicShare _mobile;
  final Pan123PublicShare _pan123;
  final TianyiPublicShare _tianyi;
  final LanzouPublicShare _lanzou;
  final QuarkPublicShare _quark;
  final UcPublicShare _uc;

  Future<List<CloudSharedFile>> inspectResources(
    Uri link,
    String? code,
    CancellationToken token,
  ) async {
    validatePublicationAddress(link, allowLoopback: http.allowLoopback);
    http.authorize(link);
    return switch (PublicationShareProvider.of(link)) {
      PublicationShareProvider.baidu => _baidu.inspect(link, code, token),
      PublicationShareProvider.quark => _quark.inspectResources(
        link,
        code,
        token,
      ),
      PublicationShareProvider.uc => _uc.inspectResources(link, code, token),
      PublicationShareProvider.lanzou => [
        for (final file in await _lanzou.inspect(link, code, token))
          (name: file.name, id: file.id, bytes: null),
      ],
      PublicationShareProvider.mobile139 ||
      PublicationShareProvider.tianyi ||
      PublicationShareProvider.pan123 => [
        for (final item in (await inspectTree(link, code, token)).files)
          item.file,
      ],
      _ => throw _unsupported,
    };
  }

  Future<CloudShareListing> inspectTree(
    Uri link,
    String? code,
    CancellationToken token, {
    bool preview = false,
  }) async {
    validatePublicationAddress(link, allowLoopback: http.allowLoopback);
    http.authorize(link);
    return switch (PublicationShareProvider.of(link)) {
      PublicationShareProvider.aliyun => _aliyun.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.baidu => _baidu.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.quark => _quark.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.uc => _uc.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.lanzou => (
        files: [
          for (final file in await _lanzou.inspect(link, code, token))
            CloudShareItem((
              name: file.name,
              id: file.id,
              bytes: null,
            ), const []),
        ],
        truncated: false,
      ),
      PublicationShareProvider.pan123 => _pan123.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.mobile139 => _mobile.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      PublicationShareProvider.tianyi => _tianyi.inspectTree(
        link,
        code,
        token,
        preview: preview,
      ),
      _ => throw _unsupported,
    };
  }

  Future<PublicationDownload> resolveResource(
    Uri link,
    CloudSharedFile file,
    String? code,
    CancellationToken token, {
    String? baiduAccessToken,
  }) async {
    validatePublicationAddress(link, allowLoopback: http.allowLoopback);
    http.authorize(link);
    return switch (PublicationShareProvider.of(link)) {
      PublicationShareProvider.baidu => _baidu.resolve(
        link,
        file.id,
        code,
        token,
        (current) => current == file,
        accessToken: baiduAccessToken,
      ),
      PublicationShareProvider.quark => _quark.resolveResource(
        link,
        file,
        code,
        token,
      ),
      PublicationShareProvider.uc => _uc.resolveResource(
        link,
        file,
        code,
        token,
      ),
      PublicationShareProvider.lanzou => _lanzou.resolveResource(
        link,
        file,
        code,
        token,
      ),
      PublicationShareProvider.pan123 => _pan123.resolve(
        link,
        code,
        file.id,
        token,
        (current) => current == file,
      ),
      PublicationShareProvider.mobile139 => _mobile.resolve(
        link,
        code,
        file.id,
        token,
        (current) => current == file,
        account: cloudAccounts?.mobile,
      ),
      PublicationShareProvider.tianyi => _tianyi.resolve(
        link,
        code,
        file.id,
        token,
        (current) => current == file,
        accessToken: cloudAccounts?.tianyi,
      ),
      _ => throw _unsupported,
    };
  }

  Future<List<PublicationSharedFile>> inspect(
    Uri target,
    String? code,
    CancellationToken token,
  ) async {
    http.authorize(target);
    validatePublicationAddress(target, allowLoopback: http.allowLoopback);
    return switch (PublicationShareProvider.of(target)) {
      PublicationShareProvider.baidu => [
        for (final file in await _baidu.inspect(target, code, token))
          ?sharedPublication(file),
      ],
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
      PublicationShareProvider.mobile139 ||
      PublicationShareProvider.tianyi ||
      PublicationShareProvider.pan123 => [
        for (final file in await inspectResources(target, code, token))
          ?sharedPublication(file),
      ],
      _ => throw _unsupported,
    };
  }

  Future<PublicationDownload> resolve(
    AcquisitionCandidate candidate,
    PublicationSource? source,
    String? code,
    CancellationToken token, {
    String? baiduAccessToken,
  }) async {
    final link = candidate.link;
    validatePublicationAddress(link, allowLoopback: http.allowLoopback);
    http.authorize(link);
    final catalogue = source == null
        ? null
        : catalogueFor?.call(source) ?? source.catalogue?.call(http);
    if (catalogue is DownloadablePublicationCatalogue) {
      return catalogue.download(candidate, token);
    }
    if (catalogue is SharedPublicationCatalogue) {
      catalogue.restrictShare(candidate.page, link);
    } else if (catalogue != null) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
    if (source?.configurable == true) source!.restrict(link);
    if (requiresPublicationFileChoice(candidate)) {
      throw const PublicationFailure(PublicationProblem.shareFile);
    }
    if (code == null && candidate.publishedAccess?.needsConfirmation == true) {
      throw const PublicationFailure(PublicationProblem.shareCode);
    }
    final provider = PublicationShareProvider.of(link);
    if (provider == PublicationShareProvider.baidu) {
      return _baidu.resolve(link, candidate.fileId, code, token, (file) {
        final book = sharedPublication(file);
        return book != null && candidate.matchesSharedFile(book);
      }, accessToken: baiduAccessToken);
    }
    if (provider == PublicationShareProvider.quark) {
      return _quark.resolve(candidate, code, token);
    }
    if (provider == PublicationShareProvider.uc) {
      return _uc.resolve(candidate, code, token);
    }
    if (provider == PublicationShareProvider.lanzou) {
      return _lanzou.resolve(candidate, code, token);
    }
    bool matches(CloudSharedFile file) {
      final book = sharedPublication(file);
      return book != null && candidate.matchesSharedFile(book);
    }

    if (provider == PublicationShareProvider.pan123) {
      return _pan123.resolve(link, code, candidate.fileId, token, matches);
    }
    if (provider == PublicationShareProvider.mobile139) {
      return _mobile.resolve(
        link,
        code,
        candidate.fileId,
        token,
        matches,
        account: cloudAccounts?.mobile,
      );
    }
    if (provider == PublicationShareProvider.tianyi) {
      return _tianyi.resolve(
        link,
        code,
        candidate.fileId,
        token,
        matches,
        accessToken: cloudAccounts?.tianyi,
      );
    }
    if (provider != PublicationShareProvider.direct) {
      throw _unsupported;
    }
    if (source?.configurable == true) {
      return PublicationDownload(
        link,
        scope: source!.restrict,
        detectGuestQuota: publicationSameWebsite(source.endpoint, link),
      );
    }
    return PublicationDownload(link);
  }

  static const _unsupported = PublicationFailure(
    PublicationProblem.unsupported,
  );
}
