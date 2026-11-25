import 'dart:collection';
import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_shared_file.dart';
import 'publication_http.dart';

typedef CloudShareNode = ({String id, String name, int? bytes});
typedef CloudSharePage = ({
  List<CloudShareNode> files,
  List<CloudShareNode> directories,
  bool more,
});

bool validCloudShareCode(String? code) =>
    code == null || RegExp(r'^[A-Za-z0-9]{2,32}$').hasMatch(code);

String? cloudNodeId(Object? value) {
  final id = switch (value) {
    final int number => '$number',
    final String text => text,
    _ => '',
  };
  return RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ? id : null;
}

String cloudNodeName(Object? value) =>
    value is String ? publicationLabel(value, max: 512) : '';

int? cloudNodeSize(Object? value) => switch (value) {
  final int bytes when bytes >= 0 => bytes,
  final String text when text.length <= 18 => switch (int.tryParse(text)) {
    final int bytes when bytes >= 0 => bytes,
    _ => null,
  },
  _ => null,
};

Future<CloudShareListing> listCloudShare(
  String root,
  CancellationToken token,
  Future<CloudSharePage> Function(String directory, int page) load, {
  bool preview = false,
}) async {
  final queue = Queue.of([(id: root, page: 1, parents: const <String>[])]);
  final directories = {root};
  final seenFiles = <String>{};
  final files = <CloudShareItem>[];
  var truncated = false;
  final requestLimit = preview ? 8 : 30;
  final fileLimit = preview ? 6 : 600;
  for (
    var requests = 0;
    queue.isNotEmpty && requests < requestLimit;
    requests++
  ) {
    token.check();
    final dir = queue.removeFirst();
    final page = await load(dir.id, dir.page);
    var newNodes = false;
    for (final node in page.directories) {
      if (!directories.add(node.id)) continue;
      newNodes = true;
      if (dir.parents.length >= 16) {
        truncated = true;
        continue;
      }
      queue.add((id: node.id, page: 1, parents: [...dir.parents, node.name]));
    }
    for (final node in page.files) {
      final id = '${dir.id}:${node.id}';
      if (!seenFiles.add(id)) continue;
      newNodes = true;
      if (files.length >= fileLimit) return (files: files, truncated: true);
      files.add(
        CloudShareItem((
          name: node.name,
          id: id,
          bytes: node.bytes,
        ), dir.parents),
      );
    }
    if (page.more) {
      if (newNodes && dir.page < 20) {
        queue.addFirst((id: dir.id, page: dir.page + 1, parents: dir.parents));
      } else {
        truncated = true;
      }
    }
  }
  return (files: files, truncated: truncated || queue.isNotEmpty);
}

(String, String) splitCloudShareFileId(String? value) {
  final parts = value?.split(':');
  if (parts != null &&
      parts.length == 2 &&
      parts.every((value) => cloudNodeId(value) != null)) {
    return (parts[0], parts[1]);
  }
  throw const PublicationFailure(PublicationProblem.shareFile);
}

Future<CloudSharedFile> findCloudShareFile(
  String? id,
  bool Function(CloudSharedFile) matches,
  Future<CloudSharePage> Function(String directory, int page) load, {
  bool preview = false,
}) async {
  final (folder, file) = splitCloudShareFileId(id);
  for (var number = 1; number <= 20; number++) {
    final page = await load(folder, number);
    for (final item in page.files) {
      if (item.id != file) continue;
      final current = (name: item.name, id: id, bytes: item.bytes);
      if (matches(current)) return current;
      throw const PublicationFailure(PublicationProblem.invalid);
    }
    if (!page.more) break;
  }
  throw const PublicationFailure(PublicationProblem.missing);
}

Future<Map> requestCloudShareJson(
  PublicationHttp http,
  Uri target,
  Uri referer,
  CancellationToken token, {
  Map<String, Object?>? json,
  Map<String, String>? form,
  Map<String, String> headers = const {},
}) => withPublicationRequestDeadline(token, const Duration(seconds: 20), (
  request,
) async {
  void scope(Uri next) {
    if (next != target) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  final response = await http.open(
    target,
    request,
    scope: scope,
    redirect: false,
    referer: referer,
    json: json,
    form: form,
    plainForm: true,
    accept: 'application/json;charset=UTF-8',
    originHeaders: headers,
    acceptGzip: true,
  );
  final text = await http.readText(
    response,
    request,
    scope: scope,
    acceptedStatuses: const {200, 400, 401, 403},
    maxBytes: 1 << 20,
    allowGzip: true,
  );
  try {
    final result = jsonDecode(text);
    if (result is Map) return result;
  } on FormatException {
    // Service errors can contain credentials or user data.
  }
  throw const PublicationFailure(PublicationProblem.network);
});

PublicationDownload cloudSiteDownload(
  Object? raw,
  Uri referer,
  bool Function(Uri) owns,
) {
  final uri = raw is String && raw.length <= 8192 ? Uri.tryParse(raw) : null;
  void scope(Uri target) {
    if (target.scheme != 'https' ||
        target.port != 443 ||
        target.userInfo.isNotEmpty ||
        !owns(target)) {
      throw const PublicationFailure(PublicationProblem.unsupported);
    }
  }

  if (uri == null) {
    throw const PublicationFailure(PublicationProblem.emptyResponse);
  }
  scope(uri);
  return PublicationDownload(uri, scope: scope, referer: referer);
}
