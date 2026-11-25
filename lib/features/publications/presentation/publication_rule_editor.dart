import 'dart:convert';

import 'package:flutter/material.dart';

import '../application/publication_discovery.dart';
import '../data/publication_rule_examples.dart';
import '../data/publication_sources.dart';
import '../domain/publication.dart';

Future<String?> editPublicationRule(
  BuildContext context,
  PublicationDiscovery discovery, {
  required Future<String?> Function() importFile,
  PublicationSource? initial,
}) => showDialog<String>(
  context: context,
  builder: (_) => _RuleEditor(discovery, importFile, initial),
);

class _RuleEditor extends StatefulWidget {
  const _RuleEditor(this.discovery, this.importFile, this.initial);
  final PublicationDiscovery discovery;
  final Future<String?> Function() importFile;
  final PublicationSource? initial;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final _rule = TextEditingController(
    text: const JsonEncoder.withIndent(
      '  ',
    ).convert(widget.initial?.toSpec() ?? greenTeaPressRule),
  );
  final _sample = TextEditingController(), _detail = TextEditingController();
  String? _status;
  List<PublicationEdition> _rows = [];
  bool _importing = false;

  void _inspect({bool preview = false, bool save = false}) {
    try {
      final config = widget.discovery.validateConfig(
        _rule.text,
        id: widget.initial?.id,
      );
      if (save) {
        Navigator.pop(context, jsonEncode(config.toSpec()));
        return;
      }
      final rows = preview
          ? widget.discovery.preview(config, _sample.text, detail: _detail.text)
          : const <PublicationEdition>[];
      setState(() {
        _rows = rows;
        _status = preview && rows.isEmpty ? '样本未匹配到图书' : '规则校验通过';
      });
    } on FormatException catch (error) {
      setState(() {
        _status = error.message;
        _rows = [];
      });
    } on PublicationFailure catch (error) {
      setState(() {
        _status = error.problem.label;
        _rows = [];
      });
    } on Exception {
      setState(() {
        _status = '无法解析样本';
        _rows = [];
      });
    }
  }

  void _loadExample(Map<String, Object?> example) {
    _rule.text = const JsonEncoder.withIndent('  ').convert(example);
    _sample.clear();
    _detail.clear();
    _inspect();
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final raw = await widget.importFile();
      if (!mounted || raw == null) return;
      _rule.text = raw;
      _inspect();
    } on Exception {
      if (mounted) setState(() => _status = '无法导入规则文件');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void dispose() {
    _rule.dispose();
    _sample.dispose();
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '导入书源规则' : '编辑书源规则'),
    scrollable: true,
    content: SizedBox(
      width: 650,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _rule,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(labelText: '版本化 JSON 配置'),
          ),
          TextField(
            controller: _sample,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '列表样本（HTML 或 JSON）'),
          ),
          TextField(
            controller: _detail,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '首条结果的详情样本（可选）'),
          ),
          Wrap(
            spacing: 5,
            children: [
              if (widget.initial == null)
                PopupMenuButton<Map<String, Object?>>(
                  enabled: !_importing,
                  tooltip: '规则示例',
                  onSelected: _loadExample,
                  itemBuilder: (_) => [
                    for (final example in publicationRuleExamples)
                      PopupMenuItem(
                        value: example,
                        child: Text(example['name'] as String),
                      ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    child: Text('规则示例'),
                  ),
                ),
              TextButton(
                onPressed: _importing ? null : _import,
                child: const Text('导入 JSON 文件'),
              ),
              TextButton(
                onPressed: () => _inspect(),
                child: const Text('校验规则'),
              ),
              TextButton(
                onPressed: () => _inspect(preview: true),
                child: const Text('预览样本'),
              ),
            ],
          ),
          if (_status != null) Text(_status!),
          for (final row in _rows)
            ListTile(
              title: Text(row.title),
              subtitle: Text(
                [
                  if (row.author.isNotEmpty) row.author,
                  if (row.page != null) row.page!.host,
                  if (row.candidates.isNotEmpty)
                    row.candidates
                        .map((item) => item.format.name.toUpperCase())
                        .join('、'),
                ].join(' · '),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => _inspect(save: true),
        child: const Text('保存规则'),
      ),
    ],
  );
}
