import 'dart:convert';

import '../../../core/network/cancellation_token.dart';
import '../domain/publication.dart';
import 'cloud_navhub_catalog.dart';
import 'cloud_resource_catalog.dart';
import '../domain/cloud_share_address.dart';
import 'publication_http.dart';
import 'publication_share_provider.dart';

final class CloudSearchHit {
  const CloudSearchHit({
    required this.title,
    required this.link,
    required this.source,
    this.code,
    this.platform,
    this.reference,
  });

  final String title, source;
  final Uri link;
  final String? code, platform, reference;

  String get key => reference == null
      ? (canonicalCloudShare(link) ?? link.removeFragment()).toString()
      : '$source:$platform:$reference';
}

enum CloudSearchEngine {
  all('全部搜索工具'),
  panHub('PanHub'),
  haiSou('海搜'),
  panHubPublic('PanHub 公开实例'),
  curated('PanHub 精选'),
  navigation('导航森林');

  const CloudSearchEngine(this.label);
  final String label;

  static CloudSearchEngine fromPreference(String? value) =>
      values.where((item) => item.name == value).firstOrNull ?? all;
}

const cloudSearchPreference = 'cloud.search.default';

const cloudSearchPlatforms = {
  'quark': '夸克网盘',
  'baidu': '百度网盘',
  'xunlei': '迅雷云盘',
  'uc': 'UC 网盘',
  'mobile': '移动云盘',
  'tianyi': '天翼云盘',
  'aliyun': '阿里云盘',
  '115': '115 网盘',
  '123': '123 网盘',
  'lanzou': '蓝奏云',
  'guangya': '光鸭云盘',
  'wo': '联通云盘',
  'weiyun': '腾讯微云',
  'ctfile': '城通网盘',
  'magnet': '磁力链接',
  'onedrive': 'OneDrive',
  'googleDrive': 'Google Drive',
  'others': '其他',
};

final panHubHome = Uri.https('panhub.shenzjd.com', '/');
final panHubPublicHome = Uri.https('panhub.houxnan.com', '/');
final haiSouHome = Uri.https('haisou.cc', '/');
final _searchWhitespace = RegExp(r'\s+');
final _searchShareCode = RegExp(r'^[A-Za-z0-9]{1,32}$');

Uri haiSouSearchPage(String query) {
  final keyword = query.trim();
  return keyword.isEmpty
      ? haiSouHome
      : haiSouHome.replace(queryParameters: {'q': keyword});
}

Uri panHubSearchPage(String query, {String? platform}) => panHubHome.replace(
  queryParameters: {
    if (query.trim().isNotEmpty) 'q': query.trim(),
    'cat': ?platform,
  },
);

typedef PanHubCursor = ({Set<int> completed, int total});

final class PanHubBrowserRequired implements Exception {
  const PanHubBrowserRequired();
}

final class CloudResourceSearch {
  CloudResourceSearch(this._http, this._navHub);

  final PublicationHttp _http;
  final CloudNavHubCatalog _navHub;
  static final _curatedPage = Uri.https(
    'panhub.shenzjd.com',
    '/api/curated-resources',
  );
  ({DateTime expires, List<CloudSearchHit> rows})? _curated;
  DateTime? _panHubBrowserUntil;
  String? _panHubBearer;
  CancellationToken? _panHubLogin;
  String? _haiSouKey;

  bool get haiSouConfigured => _haiSouKey != null;

  void configureHaiSou(String? key) {
    if (key != null && !RegExp(r'^[A-Za-z0-9._~-]{6,256}$').hasMatch(key)) {
      throw const FormatException('海搜 API Key 格式无效');
    }
    _haiSouKey = key;
  }

  bool get panHubSignedIn => _panHubBearer != null;

  Future<void> signInPanHub(String code) async {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      throw const FormatException('请输入六位验证码');
    }
    _http.authorize(panHubHome);
    _panHubLogin?.cancel();
    final token = _panHubLogin = CancellationToken();
    try {
      final auth = Uri.https('wx-auth.shenzjd.com', '/api/auth/check', {
        'siteId': panHubHome.host,
        'authToken': code,
      });
      final data = jsonDecode(await _read(auth, token));
      token.check();
      _http.authorize(panHubHome);
      if (data case {'authenticated': true, 'token': final String value}
          when value.length >= 16 &&
              value.length <= 2048 &&
              RegExp(r'^[A-Za-z0-9._~+/=-]+$').hasMatch(value)) {
        _panHubBearer = value;
        _panHubBrowserUntil = null;
        return;
      }
      throw const FormatException('验证码无效或已过期');
    } finally {
      if (identical(_panHubLogin, token)) _panHubLogin = null;
    }
  }

  void clearPanHubSession() {
    _panHubLogin?.cancel();
    _panHubBearer = null;
    _panHubBrowserUntil = null;
  }

  Future<List<CloudSearchHit>> navigation(
    String query, [
    CancellationToken? token,
  ]) async {
    if (query.isEmpty) return const [];
    final catalog = await _navHub.load();
    token?.check();
    final terms = _searchTerms(query);
    Iterable<CloudSearchHit> scan(List<CloudResourceEntry> entries) sync* {
      for (final entry in entries) {
        if (entry.link case final link?) {
          if (_matches('${entry.name} ${link.host}', terms)) {
            yield CloudSearchHit(
              title: entry.name,
              link: link,
              source: '导航森林',
              platform: _platform(link),
            );
          }
        }
        yield* scan(entry.rows);
      }
    }

    return scan(catalog.rows).take(60).toList();
  }

  Future<List<CloudSearchHit>> curated(
    String query,
    CancellationToken token,
  ) async {
    token.check();
    _http.authorize(_curatedPage);
    final saved = _curated;
    final List<CloudSearchHit> rows;
    if (saved != null && saved.expires.isAfter(DateTime.now())) {
      rows = saved.rows;
    } else {
      final payload = jsonDecode(await _read(_curatedPage, token));
      if (payload case {'code': 0, 'data': {'items': final List items}}) {
        rows = _cloudRows(items, 'PanHub 精选');
        token.check();
        _curated = (
          expires: DateTime.now().add(const Duration(minutes: 5)),
          rows: rows,
        );
      } else {
        throw const FormatException('PanHub 精选返回格式无效');
      }
    }
    final terms = _searchTerms(query);
    return rows.where((item) => _matches(item.title, terms)).toList();
  }

  Future<List<CloudSearchHit>> panHub(
    String query,
    CancellationToken token, {
    String? platform,
    PanHubCursor? cursor,
    void Function(PanHubCursor?)? onContinuation,
    void Function(List<CloudSearchHit>)? onPartial,
  }) async {
    token.check();
    final target = panHubHome.replace(
      path: '/api/search.stream',
      queryParameters: {
        'kw': query,
        'cat': ?platform,
        if (cursor != null) ...{
          'maxResults': '${cursor.total + 90}',
          'initialTotal': '${cursor.total}',
          'skipTasks': cursor.completed.join(','),
        },
      },
    );
    _http.authorize(target);
    final bearer = _panHubBearer;
    if (_panHubBrowserUntil?.isAfter(DateTime.now()) == true) {
      throw const PanHubBrowserRequired();
    }
    final search = _PanHubResults(query, onChanges: onPartial);
    await withPublicationRequestDeadline(token, const Duration(seconds: 75), (
      request,
    ) async {
      final payload = await _http.open(
        target,
        request,
        interactive: true,
        accept: 'text/event-stream',
        bearer: bearer,
        scope: _exactTarget(target),
        redirect: false,
      );
      if (const {401, 403}.contains(payload.response.statusCode)) {
        await discardPublicationResponse(payload);
        request.check();
        if (payload.response.statusCode == 401 && _panHubBearer == bearer) {
          _panHubBearer = null;
        }
        if (bearer == null) {
          _panHubBrowserUntil = DateTime.now().add(const Duration(minutes: 5));
        }
        throw const PanHubBrowserRequired();
      }
      if (payload.response.statusCode != 200 ||
          payload.response.headers.contentType?.mimeType !=
              'text/event-stream') {
        await discardPublicationResponse(payload);
        throw publicationHttpFailure(payload);
      }
      var length = 0;
      final bytes = payload.body.map((chunk) {
        request.check();
        length += chunk.length;
        if (length > 4 << 20) throw const FormatException('搜索结果超出大小限制');
        return chunk;
      });
      await for (final line
          in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
        search.addLine(line);
        if (search.finished) break;
      }
      search.flush();
    });
    final rows = search.complete();
    final completed = {...?cursor?.completed, ...search.completed};
    onContinuation?.call(
      search.reachedLimit &&
              completed.isNotEmpty &&
              completed.length > (cursor?.completed.length ?? 0)
          ? (completed: completed, total: (cursor?.total ?? 0) + rows.length)
          : null,
    );
    return rows;
  }

  Future<List<CloudSearchHit>> panHubPublic(
    String query,
    CancellationToken token, {
    String? platform,
  }) async {
    final target = panHubPublicHome.replace(
      path: '/api/search',
      queryParameters: {
        'kw': query,
        'res': 'merged_by_type',
        'cloud_types': ?platform,
      },
    );
    final body = await _http.text(
      target,
      token,
      scope: _exactTarget(target),
      deadline: const Duration(seconds: 35),
      maxBytes: 4 << 20,
      allowGzip: true,
    );
    final payload = jsonDecode(body);
    if (payload case {'code': 0, 'data': {'merged_by_type': final Map types}}) {
      return [
        for (final entry in types.entries)
          if (entry.key is String && entry.value is List)
            ..._cloudRows(
              entry.value as List,
              CloudSearchEngine.panHubPublic.label,
              platform: entry.key as String,
            ),
      ];
    }
    if (payload case {'code': 0, 'data': {'total': 0}}) return const [];
    throw const FormatException('PanHub 公开实例返回格式无效');
  }

  Future<({List<CloudSearchHit> rows, bool more})> haiSou(
    String query,
    CancellationToken token, {
    String? platform,
    int page = 1,
    bool files = false,
  }) async {
    final key = _haiSouKey;
    if (key == null) throw const FormatException('请先设置海搜 API Key');
    final target = Uri.https('apiok.us', '/api/b9d1/search', {'apikey': key});
    final body = await withPublicationRequestDeadline(
      token,
      const Duration(seconds: 20),
      (request) async {
        final response = await _http.open(
          target,
          request,
          interactive: true,
          redirect: false,
          scope: _exactTarget(target),
          json: {
            'query': query,
            'page': page,
            'pageSize': 50,
            'searchIn': files ? 'files' : 'title',
            if (platform != null)
              'platforms': [
                switch (platform) {
                  'aliyun' => 'ali',
                  'mobile' => 'yidong',
                  _ => platform,
                },
              ],
          },
        );
        if (response.response.statusCode != 200) {
          await discardPublicationResponse(response);
          throw publicationHttpFailure(response);
        }
        final bytes = <int>[];
        await for (final chunk in response.body) {
          request.check();
          if (bytes.length + chunk.length > 2 << 20) {
            throw const FormatException('海搜响应超出大小限制');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      },
    );
    final payload = jsonDecode(body);
    if (payload case {
      'code': 0,
      'result': {
        'items': final List items,
        'pagination': {'totalPages': final int pages},
      },
    }) {
      return (
        rows: _cloudRows(items, CloudSearchEngine.haiSou.label),
        more: page < pages,
      );
    }
    throw const FormatException('海搜 API 请求失败，请检查 Key 和接口配额');
  }

  Future<String> _read(Uri address, CancellationToken token) => _http.text(
    address,
    token,
    scope: _exactTarget(address),
    deadline: const Duration(seconds: 12),
    maxBytes: 512 << 10,
    allowGzip: true,
  );
}

PublicationRequestGuard _exactTarget(Uri address) => (target) {
  if (target != address) throw const FormatException('服务地址已变更');
};

List<String> _searchTerms(String query) =>
    query.toLowerCase().split(_searchWhitespace);

bool _matches(String text, List<String> terms) {
  final candidate = text.toLowerCase();
  return terms.every(candidate.contains);
}

List<CloudSearchHit> parsePanHubSearch(String body, {String query = ''}) {
  final search = _PanHubResults(query);
  for (final line in const LineSplitter().convert(body)) {
    search.addLine(line);
    if (search.finished) break;
  }
  search.flush();
  return search.complete();
}

final class _PanHubResults {
  _PanHubResults(this.query, {this.onChanges});

  final String query;
  final void Function(List<CloudSearchHit>)? onChanges;
  final rows = <String, CloudSearchHit>{};
  final completed = <int>{};
  final _data = <String>[];
  String _event = '';
  var recognized = false, finished = false, reachedLimit = false;

  void addLine(String line) {
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('event:')) {
      flush();
      _event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      _data.add(line.substring(5).trimLeft());
    }
  }

  void flush() {
    if (_data.isEmpty || finished) return;
    final raw = _data.join('\n');
    _data.clear();
    if (_event == 'error') throw const FormatException('PanHub 搜索暂不可用');
    final payload = jsonDecode(raw);
    if (payload case {'merged': final Map types}) {
      recognized = true;
      final changes = <CloudSearchHit>[];
      for (final entry in types.entries) {
        if (entry.key is! String || entry.value is! List) continue;
        for (final hit in _cloudRows(
          entry.value as List,
          'PanHub',
          platform: entry.key as String,
          query: query,
        )) {
          final key = hit.key;
          final old = rows[key];
          if (old != null && (old.code != null || hit.code == null)) continue;
          rows[key] = hit;
          if (onChanges != null) changes.add(hit);
        }
      }
      if (changes.isNotEmpty) onChanges?.call(changes);
    }
    if (payload case {'completedIndices': final List indices}) {
      completed.addAll(
        indices.whereType<int>().where((index) => index >= 0).take(4096),
      );
    }
    if (_event == 'done') {
      finished = true;
      if (payload is Map) {
        reachedLimit = payload['reachedLimit'] == true;
        recognized = recognized || payload['total'] == 0;
      }
    }
    _event = '';
  }

  List<CloudSearchHit> get result => rows.values.toList();

  List<CloudSearchHit> complete() {
    if (!recognized) throw const FormatException('PanHub 搜索暂不可用');
    if (!finished) throw const FormatException('PanHub 搜索提前中断，已保留收到的结果');
    return result;
  }
}

List<CloudSearchHit> _cloudRows(
  List items,
  String source, {
  String? platform,
  String? query,
}) => [
  for (final item in items)
    if (_cloudRow(item, source, platform, query) case final CloudSearchHit hit)
      hit,
];

CloudSearchHit? _cloudRow(
  Object? item,
  String source,
  String? platform,
  String? query,
) {
  if (item is! Map) return null;
  final title = publicationLabel(
    item['name'] ?? item['title'] ?? item['note'],
    max: 512,
  );
  if (title.isEmpty) return null;
  final raw = item['url'] ?? item['shareUrl'];
  final reference = item['tid'];
  final type = _platformKey(platform ?? item['platform']);
  final link = raw is String && raw.length <= 2048 ? Uri.tryParse(raw) : null;
  final code = [
    item['password'],
    item['pwd'],
    item['sharePwd'],
    if (link != null)
      for (final key in ['pwd', 'accessCode', 'passcode'])
        ...cloudShareCodes(link, key),
  ].whereType<String>().where(_searchShareCode.hasMatch).firstOrNull;
  if (query != null &&
      reference is String &&
      reference.isNotEmpty &&
      reference.length <= 512 &&
      (link == null || link.host.isEmpty)) {
    return CloudSearchHit(
      title: title,
      link: panHubSearchPage(query, platform: type),
      source: source,
      platform: type,
      reference: reference,
    );
  }
  if (link == null ||
      link.scheme != 'https' ||
      link.port != 443 ||
      link.host.isEmpty ||
      link.userInfo.isNotEmpty ||
      (query == null &&
          PublicationShareProvider.of(link) ==
              PublicationShareProvider.direct)) {
    return null;
  }
  return CloudSearchHit(
    title: title,
    link: link,
    code: code,
    source: source,
    platform: _platform(link) ?? type,
  );
}

String? _platformKey(Object? value) => switch (value) {
  'ali' || 'alipan' || 'aliyundrive' => 'aliyun',
  'yidong' || '139' || 'mobile139' => 'mobile',
  '189' || 'ctyun' => 'tianyi',
  '123pan' => '123',
  '115pan' => '115',
  'google_drive' || 'googledrive' => 'googleDrive',
  final String key when cloudSearchPlatforms.containsKey(key) => key,
  _ => null,
};

String? _platform(Uri link) => switch (PublicationShareProvider.of(link)) {
  PublicationShareProvider.pan115 => '115',
  PublicationShareProvider.pan123 => '123',
  PublicationShareProvider.mobile139 => 'mobile',
  PublicationShareProvider.lanzouPro => 'lanzou',
  PublicationShareProvider.direct => null,
  final value => value.name,
};
