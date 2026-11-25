import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/request_scheduler.dart';
import '../domain/publication.dart';
import 'cloud_resource_catalog.dart';
import 'cloud_kdocs_catalog.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

enum CloudSharedCatalog {
  pcGames(
    'PC 游戏',
    'https://docs.qq.com/smartsheet/DQWtRWFNCdU9tc1J0?tab=BB08J2&viewId=vEjgSC',
  ),
  mobileApps('移动应用', 'https://www.kdocs.cn/l/cm6dlrR8PJyO?R=L1MvMQ=='),
  pcSoftware('PC 电脑软件', 'https://www.kdocs.cn/l/cpl9vj8lwpCD?R=L1MvMQ==');

  const CloudSharedCatalog(this.label, this.address);
  final String label, address;
  Uri get uri => Uri.parse(address);

  static CloudSharedCatalog? named(String label) =>
      values.where((item) => item.label == label).firstOrNull;
}

List<CloudResourceEntry> _decodeSnapshot(String raw) {
  final data = jsonDecode(raw);
  if (data is! List) throw const FormatException('资源快照格式无效');
  return [
    for (final row in data)
      if (row case {
        'name': final String name,
        'url': final String url,
      } when name.isNotEmpty && name.length <= 512)
        if (_cloudDocumentLink(url) case final link?)
          CloudResourceEntry(name, link, const []),
  ];
}

final class CloudSharedCatalogs {
  CloudSharedCatalogs(this._http, this._directory);

  final PublicationHttp _http;
  final Directory _directory;
  final _active = <CloudSharedCatalog, CancellationToken>{};
  final _pending = <CloudSharedCatalog, Future<CloudResourceEntry>>{};
  final _loaded = <CloudSharedCatalog, Future<CloudResourceEntry>>{};

  File _file(CloudSharedCatalog source) =>
      File(p.join(_directory.path, 'cloud-catalog-${source.name}.json'));

  Future<CloudResourceEntry> load(CloudSharedCatalog source) =>
      _loaded.putIfAbsent(source, () => _load(source));

  Future<CloudResourceEntry> _load(CloudSharedCatalog source) async {
    try {
      final file = _file(source);
      if (await file.length() <= 4 << 20) {
        final rows = await compute(_decodeSnapshot, await file.readAsString());
        return CloudResourceEntry(
          source.label,
          source.uri,
          rows,
          updated: await file.lastModified(),
        );
      }
    } on Exception {
      // A missing or incomplete snapshot leaves the original document accessible.
    }
    return CloudResourceEntry(source.label, source.uri, const []);
  }

  Future<CloudResourceEntry> refresh(CloudSharedCatalog source) =>
      _pending.putIfAbsent(
        source,
        () =>
            withRequestPriority(
              RequestPriority.background,
              () => _refresh(source),
            ).whenComplete(() {
              _pending.remove(source);
              _active.remove(source);
            }),
      );

  Future<CloudResourceEntry> _refresh(CloudSharedCatalog source) async {
    final token = _active[source] = CancellationToken();
    final rows = await withPublicationRequestDeadline(
      token,
      const Duration(seconds: 75),
      (request) => switch (source) {
        CloudSharedCatalog.pcGames => _tencent(request),
        CloudSharedCatalog.mobileApps || CloudSharedCatalog.pcSoftware =>
          readKdocsCloudCatalog(_http, source.uri, request),
      },
    );
    if (rows.isEmpty) throw const FormatException('文档没有可读取的分享条目');
    final data = jsonEncode(
      rows
          .map((row) => {'name': row.name, 'url': row.link.toString()})
          .toList(),
    );
    if (data.length > 4 << 20) throw const FormatException('资源文档超过大小限制');
    token.check();
    final file = _file(source);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(data, flush: true);
      token.check();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    final entry = CloudResourceEntry(
      source.label,
      source.uri,
      rows,
      updated: DateTime.now(),
    );
    _loaded[source] = Future.value(entry);
    return entry;
  }

  Future<List<CloudResourceEntry>> _tencent(CancellationToken token) async {
    final page = CloudSharedCatalog.pcGames.uri;
    final guest = GuestShareSession((uri) => uri.origin == page.origin);
    final markup = await _http.text(
      page,
      token,
      guest: guest,
      scope: (uri) {
        if (uri != page) {
          throw const PublicationFailure(PublicationProblem.login);
        }
      },
      allowGzip: true,
    );
    final raw = html
        .parse(markup)
        .querySelector('#opendoc-jsonp')
        ?.attributes['src'];
    final address = raw == null ? null : page.resolve(raw);
    if (address == null ||
        address.origin != page.origin ||
        address.path != '/dop-api/opendoc' ||
        address.queryParameters['id'] != page.pathSegments.last ||
        address.queryParameters['tab'] != page.queryParameters['tab'] ||
        address.queryParameters['viewId'] != page.queryParameters['viewId'] ||
        address.queryParameters['callback'] != 'clientVarsCallback') {
      throw const FormatException('未找到腾讯文档的公开表格');
    }
    const count = 61;
    final first = await _tencentPage(address, page, guest, token, 0, count);
    final columns = first.columns;
    final ordered = first.order;
    if (columns == null || ordered == null || ordered.length > 1500) {
      throw const FormatException('腾讯文档视图格式无效或记录过多');
    }
    final records = {...first.records};
    for (var start = count; start < ordered.length; start += count) {
      token.check();
      final next = await _tencentPage(
        address,
        page,
        guest,
        token,
        start,
        count,
      );
      if (first.revision == null || next.revision != first.revision) {
        throw const FormatException('表格在更新中，请重新刷新');
      }
      records.addAll(next.records);
    }
    if (!ordered.every(records.containsKey)) {
      throw const FormatException('腾讯文档未返回完整的视图记录');
    }
    return _tencentRows(ordered, records, columns);
  }

  Future<_TencentPage> _tencentPage(
    Uri address,
    Uri page,
    GuestShareSession guest,
    CancellationToken token,
    int start,
    int count,
  ) async {
    final target = address.replace(
      queryParameters: {
        ...address.queryParameters,
        'startrow': '$start',
        'endrow': '${start + count - 1}',
      },
    );
    final body = await _http.text(
      target,
      token,
      guest: guest,
      referer: page,
      allowGzip: true,
      maxBytes: 2 << 20,
      scope: (uri) {
        if (uri != target) {
          throw const PublicationFailure(PublicationProblem.login);
        }
      },
    );
    return compute(_decodeTencentPage, body);
  }

  void cancel() {
    for (final token in _active.values) {
      token.cancel();
    }
  }
}

typedef _TencentPage = ({
  Map? columns,
  List<String>? order,
  Map<String, Object?> records,
  int? revision,
});

_TencentPage _decodeTencentPage(String body) {
  const prefix = 'clientVarsCallback(';
  final text = body.trim();
  final end = text.lastIndexOf(')');
  if (!text.startsWith(prefix) || end <= prefix.length) {
    throw const FormatException('腾讯文档返回格式无效');
  }
  final payload = jsonDecode(text.substring(prefix.length, end));
  final vars = payload is Map ? payload['clientVars'] : null;
  if (vars is! Map) throw const FormatException('腾讯文档缺少公开数据');
  final collab = vars['collab_client_vars'];
  final attributed = collab is Map ? collab['initialAttributedText'] : null;
  final parts = attributed is Map ? attributed['text'] : null;
  if (parts is! List) throw const FormatException('腾讯文档缺少表格记录');
  Map? columns;
  List<String>? order;
  final records = <String, Object?>{};
  var remaining = 8 << 20;
  for (final part in parts) {
    if (part case {'smartsheet': final String encoded}) {
      final sink = _DocumentBytes(remaining);
      ZLibDecoder().startChunkedConversion(sink)
        ..add(base64Decode(base64.normalize(encoded)))
        ..close();
      remaining -= sink.bytes.length;
      final batches = jsonDecode(utf8.decode(sink.bytes.takeBytes()));
      if (batches is! List) continue;
      for (final batch in batches.whereType<List>()) {
        for (final command in batch) {
          if (command case {
            't': 3005,
            'c': {'k1': 'BB08J2', 'k3': final Map table},
          }) {
            if (table['k3'] case final Map fields) columns = fields;
            if (table['k4'] case final List views) {
              for (final view in views) {
                if (view case {'k30': 'vEjgSC', 'k3': {'k1': final List ids}}) {
                  order = ids.whereType<String>().toList();
                }
              }
            }
          }
          if (command case {
            't': 3028,
            'c': {'k1': 'BB08J2', 'k2': {'k1': final Map cells}},
          }) {
            for (final entry in cells.entries) {
              if (entry.key case final String id) records[id] = entry.value;
            }
          }
        }
      }
    }
  }
  return (
    columns: columns,
    order: order,
    records: records,
    revision: switch (vars['calcRev']) {
      final int revision => revision,
      _ => null,
    },
  );
}

class _DocumentBytes implements Sink<List<int>> {
  _DocumentBytes(this.limit);

  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('表格解压后超过大小限制');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

List<CloudResourceEntry> _tencentRows(
  List<String> order,
  Map records,
  Map columns,
) {
  final title = columns.entries
      .where(
        (entry) => entry.value is Map && (entry.value as Map)['k30'] == '游戏名称',
      )
      .firstOrNull
      ?.key;
  final linkColumns = columns.entries
      .where((entry) => entry.value is Map && (entry.value as Map)['k31'] == 8)
      .map((entry) => entry.key);
  if (title == null || linkColumns.isEmpty) {
    throw const FormatException('腾讯文档缺少名称或链接列');
  }
  final result = <CloudResourceEntry>[];
  for (final id in order) {
    final row = records[id];
    if (row is! Map || row['k1'] is! Map) continue;
    final cells = row['k1'] as Map;
    final titleCell = cells[title];
    if (titleCell is! Map || titleCell['k1'] is! List) continue;
    final runs = (titleCell['k1'] as List).whereType<Map>();
    final name = publicationLabel(
      runs.map((run) => run['k2']).whereType<String>().join(),
    );
    if (name.isEmpty) continue;
    final links = <Uri>{};
    for (final column in linkColumns) {
      if (cells[column] case {'k8': final List entries}) {
        for (final entry in entries.whereType<Map>()) {
          if (_cloudDocumentLink(entry['k3'] ?? entry['k2']) case final link?) {
            links.add(link);
          }
        }
      }
    }
    result.addAll(
      links.map((link) => CloudResourceEntry(name, link, const [])),
    );
  }
  return result;
}

Uri? _cloudDocumentLink(Object? raw) {
  if (raw is! String || raw.length > 2048) return null;
  final link = Uri.tryParse(raw);
  if (link == null ||
      link.scheme != 'https' ||
      link.port != 443 ||
      link.userInfo.isNotEmpty ||
      PublicationShareProvider.of(link) == PublicationShareProvider.direct) {
    return null;
  }
  return link;
}
