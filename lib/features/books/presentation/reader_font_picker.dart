import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/cancellation_token.dart';
import '../data/reader_fonts.dart';

Future<String?> showReaderFontPicker(
  BuildContext context,
  ReaderFontStore store,
  String selected,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _FontPicker(store: store, selected: selected),
);

class _FontPicker extends StatefulWidget {
  const _FontPicker({required this.store, required this.selected});
  final ReaderFontStore store;
  final String selected;
  @override
  State<_FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends State<_FontPicker> {
  late final _system = widget.store.systemFamilies();
  final _token = CancellationToken();
  final _installed = <String>{};
  String _query = '';
  String? _busy, _error;

  @override
  void initState() {
    super.initState();
    _loadInstalled();
  }

  Future<void> _loadInstalled() async {
    for (final font in openReaderFonts) {
      if (await widget.store.installed(font)) _installed.add(font.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _choose(String family, {OpenReaderFont? download}) async {
    if (_busy != null) return;
    setState(() {
      _busy = family;
      _error = null;
    });
    try {
      if (download != null) await widget.store.download(download, _token);
      if (!await widget.store.ensure(family)) {
        _installed.remove(family);
        throw const FormatException('字体不可用，再次点按可重新下载，或选择其他字体');
      }
      if (mounted) Navigator.pop(context, family);
    } on Exception catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '字体获取失败，请检查网络后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _link(Uri uri) async {
    if (!await launchUrl(uri) && mounted) setState(() => _error = '无法打开项目链接');
  }

  @override
  void dispose() {
    _token.cancel();
    super.dispose();
  }

  Future<void> _fontAction(OpenReaderFont font, String action) async {
    if (action == 'download') {
      await _choose(font.id, download: font);
      return;
    }
    if (action == 'remove') {
      try {
        await widget.store.remove(font);
        if (mounted) {
          setState(() {
            _installed.remove(font.id);
            _error = '已删除下载副本，已加载的字体保留至本次运行结束';
          });
        }
      } on Exception {
        if (mounted) setState(() => _error = '删除失败，请重试');
      }
      return;
    }
    await _link(
      action == 'project'
          ? font.project
          : Uri.parse(
              'https://github.com/adobe-fonts/${font.repo}/blob/${font.version}/LICENSE.txt',
            ),
    );
  }

  Widget _onlineTile(OpenReaderFont font) => ListTile(
    title: Text(font.label),
    subtitle: Text(
      '${font.version} · ${(font.bytes / 1048576).toStringAsFixed(1)} MiB · ${_installed.contains(font.id) ? '已下载，点按使用' : '点按下载并使用'}',
    ),
    onTap: _busy != null
        ? null
        : () => _choose(
            font.id,
            download: _installed.contains(font.id) ? null : font,
          ),
    trailing: _busy == font.id
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(),
          )
        : PopupMenuButton<String>(
            tooltip: '字体项目与许可',
            enabled: _busy == null,
            onSelected: (value) => _fontAction(font, value),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'project', child: Text('官方项目')),
              const PopupMenuItem(value: 'license', child: Text('OFL 许可证')),
              if (_installed.contains(font.id)) ...[
                const PopupMenuItem(value: 'download', child: Text('重新下载')),
                const PopupMenuItem(value: 'remove', child: Text('删除下载副本')),
              ],
            ],
          ),
  );

  Widget _fontList(List<String> families, bool loading) {
    final header = <Widget>[
      const ListTile(title: Text('阅读字体'), subtitle: Text('中文阅读预览 · 山川日月，书卷常新')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          decoration: const InputDecoration(labelText: '筛选系统字体'),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      for (final item in readerBundledFonts.entries)
        ListTile(
          title: Text(
            item.value,
            style: TextStyle(fontFamily: readerFontFamily(item.key)),
          ),
          selected: widget.selected == item.key,
          onTap: () => _choose(item.key),
        ),
      ListTile(
        title: const Text('开源字体 · 按需下载'),
        subtitle: const Text('来自 free-font 列表对应官方项目 · SIL OFL 1.1'),
        onTap: () => _link(Uri.parse('https://github.com/wordshub/free-font')),
      ),
      for (final font in openReaderFonts) _onlineTile(font),
      ListTile(
        title: Text('系统可选字体（${families.length}）'),
        subtitle: const Text('以设备公开的字体族为准；缺失字形由系统回退'),
      ),
      if (loading) const Center(child: CircularProgressIndicator()),
      if (!loading && families.isEmpty)
        const ListTile(title: Text('当前设备未提供更多匹配字体，可使用系统默认字体')),
    ];
    return ListView.builder(
      itemCount: header.length + families.length,
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        final name = families[index - header.length];
        return ListTile(
          title: Text(name, style: TextStyle(fontFamily: name)),
          selected: widget.selected == 'system:$name',
          onTap: () => _choose('system:$name'),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .85,
    child: SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FutureBuilder<List<String>>(
          future: _system,
          builder: (context, snapshot) {
            final families = (snapshot.data ?? [])
                .where(
                  (name) => name.toLowerCase().contains(_query.toLowerCase()),
                )
                .toList();
            return _fontList(families, !snapshot.hasData);
          },
        ),
      ),
    ),
  );
}
