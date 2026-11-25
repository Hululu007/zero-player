import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/publication.dart';
import 'publication_http.dart';

const publicationPandaDirectoryAsset =
    'assets/catalogs/books/panda-directory.json';
final publicationPandaPage = Uri.https('xmsoushu.com', '/');
final _domain = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$',
);
final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');

enum PublicationPandaStatus {
  native('应用内搜索'),
  website('系统浏览器'),
  limited('站点验证或拒绝访问'),
  changedDomain('跳域或 HTTPS 降级'),
  changedPurpose('站点用途已变更'),
  unavailable('未验证可用入口'),
  invalid('地址无效'),
  auxiliary('辅助资源'),
  archived('导航回收站');

  const PublicationPandaStatus(this.label);
  final String label;
}

typedef PublicationPandaEntry = ({
  String name,
  String host,
  PublicationPandaStatus status,
  Uri? website,
  String? sourceId,
});
typedef PublicationPandaGroup = ({
  String id,
  String name,
  List<PublicationPandaEntry> entries,
});
typedef PublicationPandaDirectory = ({
  String reviewed,
  List<PublicationPandaGroup> groups,
});

Future<PublicationPandaDirectory> loadPublicationPandaDirectory() async =>
    parsePublicationPandaDirectory(
      await rootBundle.loadString(publicationPandaDirectoryAsset),
    );

PublicationPandaDirectory parsePublicationPandaDirectory(String raw) {
  final data = jsonDecode(raw);
  if (data case {
    'version': 1,
    'reviewed': final String reviewed,
    'groups': final List groups,
  } when _day.hasMatch(reviewed) && groups.isNotEmpty && groups.length <= 32) {
    final ids = <String>{};
    final result = <PublicationPandaGroup>[];
    var count = 0;
    for (final group in groups) {
      if (group case {
        'id': final String id,
        'name': final String name,
        'entries': final List entries,
      } when id.isNotEmpty && name.isNotEmpty && ids.add(id)) {
        count += entries.length;
        if (count > 1000) break;
        result.add((
          id: id,
          name: publicationLabel(name, max: 48),
          entries: entries.map(_entry).toList(),
        ));
      }
    }
    if (result.length == groups.length && count <= 1000) {
      return (reviewed: reviewed, groups: result);
    }
  }
  throw const FormatException('熊猫书源目录格式无效');
}

PublicationPandaEntry _entry(Object? raw) {
  if (raw case {
    'name': final String name,
    'original': final String original,
    'status': final String status,
  } when name.isNotEmpty && original.length <= 2048) {
    final host = Uri.tryParse(original)?.host ?? '';
    final state = PublicationPandaStatus.values.byName(status);
    final website =
        state == PublicationPandaStatus.website && raw['website'] is String
        ? _website(raw['website'] as String, host)
        : null;
    return (
      name: publicationLabel(name, max: 100),
      host: _domain.hasMatch(host) ? host : '',
      status: state == PublicationPandaStatus.website && website == null
          ? PublicationPandaStatus.invalid
          : state,
      website: website,
      sourceId: state == PublicationPandaStatus.native
          ? raw['source'] as String
          : null,
    );
  }
  throw const FormatException('熊猫书源条目格式无效');
}

Uri? _website(String raw, String originalHost) {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      raw.length > 2048 ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.host != originalHost ||
      !_domain.hasMatch(uri.host) ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  try {
    validatePublicationAddress(uri);
    return uri;
  } on FormatException {
    return null;
  } on PublicationFailure {
    return null;
  }
}
