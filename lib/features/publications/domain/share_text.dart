typedef PublicationShareInput = ({
  Uri link,
  String? code,
  String? zipPassword,
  String? pdfPassword,
  bool needsConfirmation,
});

final _shareUrls = RegExp(
  r'(?:https?://|(?<![a-z0-9_./\\:@%+-])(?<bare>pan\.quark\.cn/s/|drive\.uc\.cn/s/))'
  r'[^\s<>「」《》“”\[\]，；。]+',
  caseSensitive: false,
);

const _shareCodeKeys = {'pwd', 'password', 'passcode', 'code'};

bool containsPublicationShareLink(String text) => _shareUrls.hasMatch(text);

PublicationShareInput? publicationSourceShareInput(
  String field,
  bool Function(Uri) accepts,
) {
  final matches = _shareUrls.allMatches(field).take(2).toList();
  if (matches.length != 1) return null;
  try {
    return _shareBlock(
      field,
      matches,
      accepts: (uri) =>
          accepts(uri) &&
          uri.queryParametersAll.keys.every(_shareCodeKeys.contains),
    ).firstOrNull;
  } on FormatException {
    return null;
  }
}

List<PublicationShareInput> publicationShareInputs(String text) {
  if (text.length > 16384) throw const FormatException('分享文本过长');
  final matches = _shareUrls.allMatches(text).take(13).toList();
  if (matches.length > 12) throw const FormatException('单次最多处理十二条分享链接');
  final results = matches.length == 1
      ? _shareBlock(text, matches).toList()
      : [
          for (final block in text.split(RegExp(r'\r?\n[ \t\u3000]*\r?\n')))
            ..._shareBlock(block, _shareUrls.allMatches(block).toList()),
        ];
  if (results.isEmpty) throw const FormatException('未找到可识别的 HTTP(S) 分享或文件链接');
  return results;
}

final _shareCodes = RegExp(
  r'(?:提取码|访问密码|分享密码|口令|(?<!ZIP |PDF )(?<!ZIP|PDF)密码)\s*[:：=]?\s*([A-Za-z0-9]{2,16})(?![A-Za-z0-9])',
  caseSensitive: false,
);
final _documentPasswords = _typedPasswordPattern('ZIP|PDF');
final _validCode = RegExp(r'^[A-Za-z0-9]{2,16}$');

Iterable<PublicationShareInput> _shareBlock(
  String text,
  List<RegExpMatch> matches, {
  bool Function(Uri)? accepts,
}) sync* {
  var start = 0;
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    var end = text.length;
    if (i + 1 < matches.length) {
      final next = matches[i + 1];
      final lineBreak = text.lastIndexOf('\n', next.start);
      // A prefix on the next link's own line belongs to that entry.
      end = lineBreak >= match.end ? lineBreak + 1 : next.start;
    }
    final prefix = text.substring(start, match.start);
    final tail = text.substring(match.end, end);
    start = end;
    final raw = match[0]!.replaceFirst(RegExp(r'[)）},，.!！]+$'), '');
    final uri = Uri.tryParse(
      match.namedGroup('bare') == null ? raw : 'https://$raw',
    );
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) continue;
    if (accepts != null && !accepts(uri)) continue;
    final sharedPrefix = i == 0 && matches.length > 1;
    final block = sharedPrefix ? tail : '$prefix\n$tail';
    final zipPasswords = _typedPasswords(block, 'ZIP');
    final pdfPasswords = _typedPasswords(block, 'PDF');
    final explicit = <String>{
      for (final key in _shareCodeKeys)
        ...uri.queryParametersAll[key] ?? const <String>[],
      ..._shareCodes
          .allMatches(block.replaceAll(_documentPasswords, ''))
          .map((value) => value[1]!),
    }..removeWhere((value) => !_validCode.hasMatch(value));
    final ambiguous =
        explicit.length > 1 ||
        (sharedPrefix &&
            _shareCodes.hasMatch(prefix.replaceAll(_documentPasswords, '')));
    final stableLink = Uri.parse(uri.toString().split(RegExp(r'[?#]')).first);
    yield (
      link: stableLink,
      code: !ambiguous && explicit.length == 1 ? explicit.single : null,
      zipPassword: zipPasswords.length == 1 ? zipPasswords.single : null,
      pdfPassword: pdfPasswords.length == 1 ? pdfPasswords.single : null,
      needsConfirmation: ambiguous,
    );
  }
}

Set<String> _typedPasswords(String text, String format) =>
    _typedPasswordPattern(
      format,
    ).allMatches(text).map((match) => match[1]!).toSet();

RegExp _typedPasswordPattern(String format) => RegExp(
  '(?:$format)[ \\t]*(?:文件|文档|压缩包)?[ \\t]*密码[ \\t]*[:：=][ \\t]*([^\\s，；。]{1,256})',
  caseSensitive: false,
);
