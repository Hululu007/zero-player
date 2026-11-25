import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/request_scheduler.dart';
import 'cloud_resource_catalog.dart';
import 'publication_http.dart';

final navHubHome = Uri.https('navhub.shenzjd.com', '/');

final class CloudNavHubCatalog {
  CloudNavHubCatalog(this._http, Directory directory)
    : _cache = File(p.join(directory.path, 'navhub-catalog.json'));

  final PublicationHttp _http;
  final File _cache;
  Future<CloudResourceEntry>? _loaded;
  Future<CloudResourceEntry>? _refreshing;
  CancellationToken? _request;

  Future<CloudResourceEntry> load() => _loaded ??= _load();

  Future<CloudResourceEntry> _load() async {
    try {
      if (await _cache.length() <= 2 << 20) {
        return await compute(_decodeSnapshot, await _cache.readAsString());
      }
    } on Exception {
      // A missing or incomplete cache can be recovered from the bundled copy.
    }
    final snapshot = await rootBundle.loadString(
      'assets/catalogs/cloud/navhub.json',
    );
    return compute(_decodeSnapshot, snapshot);
  }

  Future<CloudResourceEntry> refresh() =>
      _refreshing ??= withRequestPriority(RequestPriority.background, _refresh)
          .whenComplete(() {
            _refreshing = null;
            _request = null;
          });

  Future<CloudResourceEntry> _refresh() async {
    final token = _request = CancellationToken();
    final body = await _http.text(
      navHubHome,
      token,
      scope: (uri) {
        if (uri != navHubHome) throw const FormatException('导航森林地址无效');
      },
      maxBytes: 2 << 20,
      deadline: const Duration(seconds: 25),
      allowGzip: true,
    );
    final (entry, snapshot) = await compute(_parseSnapshot, body);
    token.check();
    await _cache.parent.create(recursive: true);
    final temporary = File('${_cache.path}.tmp');
    try {
      await temporary.writeAsString(snapshot, flush: true);
      token.check();
      await temporary.rename(_cache.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    _loaded = Future.value(entry);
    return entry;
  }

  void cancel() => _request?.cancel();
}

CloudResourceEntry _decodeSnapshot(String raw) => _navHubEntry(jsonDecode(raw));

(CloudResourceEntry, String) _parseSnapshot(String body) {
  final data = parseNavHubCategories(body);
  return (_navHubEntry(data), jsonEncode(data));
}

CloudResourceEntry _navHubEntry(Object? raw) {
  var total = 0;
  List<CloudResourceEntry> rows(Object? data, int depth) {
    if (data is! List || depth > 8 || data.length > 10000) {
      throw const FormatException('导航森林分类无效');
    }
    final entries = <CloudResourceEntry>[];
    for (final row in data) {
      if (row case {
        'name': final String name,
      } when name.trim().isNotEmpty && name.length <= 512) {
        if (++total > 10000) throw const FormatException('导航森林条目过多');
        if (row['url'] case final String url) {
          final link = _navHubLink(url);
          if (link != null) {
            entries.add(CloudResourceEntry(name, link, const []));
          }
        } else {
          entries.add(
            CloudResourceEntry(name, null, rows(row['rows'], depth + 1)),
          );
        }
      }
    }
    return entries;
  }

  final categories = rows(raw, 0);
  if (categories.isEmpty || total <= categories.length) {
    throw const FormatException('导航森林目录为空');
  }
  return CloudResourceEntry('导航森林', navHubHome, categories);
}

Uri? _navHubLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  try {
    validatePublicationAddress(uri);
    return uri;
  } on Exception {
    return null;
  }
}

List<Object?> parseNavHubCategories(String body) {
  const prefix = 'self.__next_f.push(';
  final flight = StringBuffer();
  for (final script in html.parse(body).querySelectorAll('script')) {
    final text = script.text.trim();
    if (!text.startsWith(prefix) || !text.endsWith(')')) continue;
    final data = jsonDecode(text.substring(prefix.length, text.length - 1));
    if (data case [1, final String chunk]) flight.write(chunk);
  }
  for (final line in const LineSplitter().convert(flight.toString())) {
    if (!line.contains('"initialSites":')) continue;
    final payload = jsonDecode(line.substring(line.indexOf(':') + 1));
    if (payload is! List) continue;
    for (final node in payload) {
      if (node case [r'$', _, _, {'initialSites': final List categories}]) {
        return _mapNavHubRows(categories);
      }
    }
  }
  throw const FormatException('未找到导航森林的公开目录');
}

List<Object?> _mapNavHubRows(List categories, [int depth = 0]) {
  if (depth > 7) throw const FormatException('导航森林分类超出深度限制');
  return [
    for (final category in categories)
      if (category case {
        'name': final String name,
        'sites': final List sites,
      } when category['_deleted'] != true)
        {
          'name': name,
          'rows': [
            if (category['children'] case final List children)
              ..._mapNavHubRows(children, depth + 1),
            for (final site in sites)
              if (site case {
                'title': final String title,
                'url': final String url,
              } when site['_deleted'] != true && _navHubLink(url) != null)
                {'name': title, 'url': url},
          ],
        },
  ];
}
