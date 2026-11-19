import '../../../core/network/document_client.dart';
import '../../../core/network/header_policy.dart';
import '../../../core/text/display_text.dart';
import '../../supervision/domain/content_classification.dart';
import '../domain/catalog_item.dart';
import '../domain/vod_provider.dart';
import 'website_transport.dart';

/// Native JSON adapter for WebHome's public catalogue; never runs site scripts
/// or third-party parser pages. Official platform links remain unsupported.
final class WebHomeProvider implements VodProvider {
  const WebHomeProvider(this.transport);
  final WebsiteTransport transport;

  Future<Map> _request(Map<String, String> query) async {
    final document = await transport.get(
      transport.url('/api/proxy.php', query: query),
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': '${transport.source.endpoint.origin}/',
      },
    );
    final data = document.json;
    if (data is! Map || data['success'] != true) {
      throw FormatException(
        data is Map && data['need_captcha'] == true
            ? '网站要求人机验证，请稍后重试'
            : '网站没有返回有效的影片数据',
      );
    }
    return data;
  }

  @override
  Future<CatalogBrowse> browse({String category = '', int page = 1}) async {
    final data = await _request({'action': 'home'});
    final groups = data['categories'];
    final source = data['source_used'];
    if (groups is! Map || source is! String) {
      throw const FormatException('网站首页结构已变化');
    }
    final items = <String, CatalogItem>{};
    for (final entry in groups.entries) {
      if (category.isNotEmpty && category != entry.key) continue;
      if (entry.value is! List) continue;
      for (final row in (entry.value as List).whereType<Map>()) {
        final item = _item(row, source, category: '${entry.key}');
        items[item.id] = item;
      }
    }
    return CatalogBrowse(
      CatalogPage(items.values.toList(), 1),
      categories: {for (final key in groups.keys) '$key': displayText('$key')},
    );
  }

  @override
  Future<CatalogPage> search(String query, {int page = 1}) async {
    final data = await _request({
      'action': 'search',
      'wd': query,
      'page': '$page',
    });
    if (data['results'] is! List) {
      throw const FormatException('网站搜索结构已变化');
    }
    final items = <String, CatalogItem>{};
    for (final row in (data['results'] as List).whereType<Map>()) {
      if (row['source'] is! String) continue;
      final item = _item(row, row['source'] as String);
      items[item.id] = item;
    }
    // The public endpoint reports a result count, not a page count.
    return CatalogPage(items.values.toList(), page);
  }

  Future<Map> _detail(String id) async {
    final match = RegExp(
      r'^([a-zA-Z0-9_-]{1,64}):([0-9]{1,20})$',
    ).firstMatch(id);
    if (match == null) throw const FormatException('影片编号无效');
    final data = await _request({
      'action': 'detail',
      'source': match[1]!,
      'id': match[2]!,
    });
    final rows = data['details'];
    if (rows is! List ||
        rows.isEmpty ||
        rows.first is! Map ||
        '${(rows.first as Map)['id']}' != match[2]) {
      throw const FormatException('网站没有返回对应影片详情');
    }
    return rows.first as Map;
  }

  @override
  Future<CatalogItem> detail(String remoteId) async {
    final row = await _detail(remoteId);
    final source = remoteId.split(':').first;
    final lines = _lines(row, source);
    final item = _item(row, source, lines: lines);
    if (lines.isNotEmpty ||
        adultContent(item.title) ||
        adultContent(item.category, category: true)) {
      return item;
    }
    // Home recommendations use official links. Look for an exact title/year
    // in the same site's public collection channels, without parser services.
    final alternatives = await search(item.title);
    for (final candidate
        in alternatives.items
            .where(
              (candidate) =>
                  candidate.id != remoteId &&
                  candidate.title == item.title &&
                  (item.year.isEmpty || candidate.year == item.year) &&
                  !adultContent(candidate.category, category: true),
            )
            .take(3)) {
      transport.cancellation?.check();
      try {
        final detail = await _detail(candidate.id);
        final selected = _item(detail, candidate.id.split(':').first);
        if (selected.title != item.title ||
            (item.year.isNotEmpty && selected.year != item.year) ||
            adultContent(selected.category, category: true)) {
          continue;
        }
        lines.addAll(_lines(detail, candidate.id.split(':').first));
      } on FormatException {
        transport.cancellation?.check();
      } on RemoteFailure {
        transport.cancellation?.check();
      }
      if (lines.isNotEmpty) break;
    }
    return _item(row, source, lines: lines);
  }

  List<PlayLine> _lines(Map row, String source) {
    final result = <PlayLine>[];
    for (final group
        in (row['episodes'] is List ? row['episodes'] as List : const [])
            .whereType<Map>()) {
      final episodes = <Episode>[];
      for (final entry
          in (group['episodes'] is List ? group['episodes'] as List : const [])
              .whereType<Map>()) {
        final uri = Uri.tryParse('${entry['url']}');
        if (uri == null || !_direct(uri)) continue;
        episodes.add(Episode(displayText('${entry['name'] ?? '播放'}'), uri));
      }
      if (episodes.isNotEmpty) {
        result.add(
          PlayLine(
            '$source · ${displayText('${group['group'] ?? '直连'}')}',
            episodes,
          ),
        );
      }
    }
    return result;
  }

  CatalogItem _item(
    Map row,
    String source, {
    String? category,
    List<PlayLine> lines = const [],
  }) => CatalogItem(
    sourceId: transport.source.id,
    id: '$source:${row['id']}',
    title: displayText('${row['name'] ?? ''}'),
    poster: '${row['pic'] ?? ''}',
    year: displayText('${row['year'] ?? ''}'),
    category: displayText(category ?? '${row['type'] ?? ''}'),
    remarks: displayText('${row['remarks'] ?? ''}'),
    description: displayText('${row['content'] ?? ''}'),
    actors: displayText('${row['actor'] ?? ''}'),
    director: displayText('${row['director'] ?? ''}'),
    lines: lines,
  );

  bool _direct(Uri uri) =>
      {'https', 'http'}.contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.queryParameters.containsKey('url') &&
      RegExp(
        r'\.(?:m3u8|mp4|mkv|webm|ts|m4v)$',
        caseSensitive: false,
      ).hasMatch(uri.path);

  @override
  Future<ResolvedMedia> resolve(Episode episode) async {
    if (!_direct(episode.uri)) {
      throw const RemoteFailure(FailureKind.unsupported, '此线路需要网站外部解析');
    }
    return ResolvedMedia(
      episode.uri,
      headers: {
        ...HeaderPolicy.publicReferer(transport.source.endpoint, episode.uri),
        'User-Agent': 'Mozilla/5.0',
      },
    );
  }
}
