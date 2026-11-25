import 'package:flutter/material.dart';

import '../application/publication_workflow.dart';
import '../data/publication_share_provider.dart';
import '../data/publication_zip.dart';
import '../domain/acquisition_task.dart';
import '../domain/publication.dart';
import 'baidu_token_guide.dart';
import 'publication_management_view.dart' show publicationSize;

Future<String?> publicationPrompt(
  BuildContext context,
  String title, {
  String initial = '',
  bool password = false,
  bool multiline = false,
  int limit = 256,
  String? instructions,
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _Prompt(title, initial, password, multiline, limit, instructions),
);

class _Prompt extends StatefulWidget {
  const _Prompt(
    this.title,
    this.initial,
    this.password,
    this.multiline,
    this.limit,
    this.instructions,
  );
  final String title, initial;
  final bool password, multiline;
  final int limit;
  final String? instructions;
  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  late final _text = TextEditingController(text: widget.initial);
  bool get _hasValue =>
      (widget.password ? _text.text : _text.text.trim()).isNotEmpty;

  void _submit() {
    final value = widget.password ? _text.text : _text.text.trim();
    if (_hasValue) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 520,
      child: TextField(
        controller: _text,
        autofocus: true,
        obscureText: widget.password,
        maxLength: widget.limit,
        minLines: widget.multiline ? 4 : 1,
        maxLines: widget.multiline ? 8 : 1,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          helperText: widget.instructions,
          helperMaxLines: 4,
        ),
        onSubmitted: widget.multiline ? null : (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _hasValue ? _submit : null,
        child: const Text('确定'),
      ),
    ],
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}

Future<T?> choosePublicationValue<T>(
  BuildContext context,
  String title,
  List<T> values,
  String Function(T) label, {
  bool confirmSingle = false,
}) {
  if (values.length == 1 && !confirmSingle) return Future.value(values.single);
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(title: Text(title)),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: values.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(label(values[index])),
              onTap: () => Navigator.pop(context, values[index]),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> showBaiduPublicationShare(
  BuildContext context,
  Uri link,
  String? code,
  Future<void> Function(Uri? page) proceed,
) async {
  const open = '在百度网盘打开';
  const withCode = '输入提取码并打开';
  const importBook = '导入已下载的图书';
  final action = await choosePublicationValue(
    context,
    '请在百度网盘完成下载，下载后可将文件导入书库',
    [open, withCode, importBook],
    (value) => value,
  );
  if (!context.mounted || action == null) return;
  if (action == importBook) {
    await proceed(null);
    return;
  }
  if (action == withCode) {
    code = await publicationPrompt(
      context,
      '输入百度网盘提取码',
      initial: code ?? '',
      password: true,
      limit: 4,
    );
    if (!context.mounted || code == null) return;
  }
  await proceed(baiduPublicationSharePage(link, code));
}

Future<({String? token})?> choosePublicationDownloadAccess(
  BuildContext context,
  Uri link,
) async {
  if (!isBaiduPublicationShare(link)) return (token: null);
  const guest = '尝试游客下载';
  const authorized = '使用百度网盘访问令牌';
  const help = '查看令牌获取教程';
  Future<String?> choose() => choosePublicationValue(context, '百度网盘下载方式', [
    guest,
    authorized,
    help,
  ], (value) => value);
  var action = await choose();
  while (action == help) {
    if (!context.mounted) return null;
    await showBaiduTokenGuide(context);
    if (!context.mounted) return null;
    action = await choose();
  }
  if (!context.mounted || action == null) return null;
  if (action == guest) return (token: null);
  final token = await publicationPrompt(
    context,
    '输入百度网盘授权的访问令牌',
    password: true,
    limit: 512,
  );
  if (token == null) return null;
  final value = token.trim();
  if (!validBaiduPublicationToken(value)) {
    throw const FormatException('百度网盘访问令牌格式无效');
  }
  return (token: value);
}

Future<void> retryPublicationDownload(
  BuildContext context,
  PublicationWorkflow workflow,
  AcquisitionTask task,
) async {
  final needsCode = task.problem == PublicationProblem.shareCode;
  final code = needsCode
      ? await publicationPrompt(context, '输入分享提取码', password: true)
      : null;
  if (!context.mounted || (needsCode && code == null)) return;
  final access = await choosePublicationDownloadAccess(
    context,
    task.candidate.link,
  );
  if (access == null || !context.mounted) return;
  await workflow.start(
    task.id,
    code: code,
    codeFor: task.candidate.id,
    baiduAccessToken: access.token,
  );
}

Future<PublicationZipEntry?> choosePublicationZipEntry(
  BuildContext context,
  List<PublicationZipEntry> items,
  bool Function(String) allowed,
) {
  if (items.isEmpty) throw const FormatException('压缩包里没有可导入的电子书');
  final visible = items.where((entry) => allowed(entry.path)).toList();
  if (visible.isEmpty) {
    throw const PublicationFailure(PublicationProblem.blocked);
  }
  return choosePublicationValue(
    context,
    '选择压缩包中的图书',
    visible,
    (entry) =>
        '${entry.path} · ${publicationSize(entry.bytes)}${entry.encrypted ? ' · 有密码' : ''}',
  );
}

Future<PublicationSharedFile?> choosePublicationShareFile(
  BuildContext context,
  List<PublicationSharedFile> files,
) => choosePublicationValue(
  context,
  '选择网盘文件',
  files,
  (file) => file.bytes == null
      ? file.name
      : '${file.name} · ${publicationSize(file.bytes!)}',
  confirmSingle: true,
);

Future<bool> confirmPublicationDelete(
  BuildContext context,
  String title,
  String detail, {
  String action = '确认',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
