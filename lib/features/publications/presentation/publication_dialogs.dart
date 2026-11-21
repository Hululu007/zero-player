import 'package:flutter/material.dart';

Future<String?> publicationPrompt(
  BuildContext context,
  String title, {
  String initial = '',
  bool password = false,
  bool multiline = false,
  int limit = 256,
}) => showDialog<String>(
  context: context,
  builder: (context) => _Prompt(title, initial, password, multiline, limit),
);

class _Prompt extends StatefulWidget {
  const _Prompt(
    this.title,
    this.initial,
    this.password,
    this.multiline,
    this.limit,
  );
  final String title, initial;
  final bool password, multiline;
  final int limit;
  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  late final _text = TextEditingController(text: widget.initial);
  void _submit() {
    final value = widget.password ? _text.text : _text.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
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
        onSubmitted: widget.multiline ? null : (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('确定')),
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

Future<bool> confirmPublicationDelete(
  BuildContext context,
  String title,
  String detail,
) async =>
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
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
