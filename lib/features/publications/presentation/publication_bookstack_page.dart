import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../application/publication_module.dart';
import '../data/publication_bookstack_reader.dart';
import '../data/publication_panda_html_catalogues.dart';
import '../domain/publication.dart';

class PublicationBookStackPage extends StatefulWidget {
  const PublicationBookStackPage({
    super.key,
    required this.module,
    required this.title,
    required this.page,
    required this.openOriginal,
  });

  final PublicationModule module;
  final String title;
  final Uri page;
  final ValueChanged<Uri> openOriginal;

  @override
  State<PublicationBookStackPage> createState() =>
      _PublicationBookStackPageState();
}

class _PublicationBookStackPageState extends State<PublicationBookStackPage> {
  CancellationToken? _request;
  List<BookStackChapter> _chapters = const [];
  BookStackChapter? _chapter;
  Uri? _lastOpened;
  String? _content, _error;
  bool _busy = false;
  bool _revoked = false;
  PublicationModule get _module => widget.module;

  @override
  void initState() {
    super.initState();
    _module.policy.addListener(_policyChanged);
    _load();
  }

  void _policyChanged() {
    _request?.cancel();
    setState(() {
      _revoked = true;
      _chapters = const [];
      _chapter = null;
      _lastOpened = null;
      _content = null;
      _busy = false;
      _error = PublicationProblem.blocked.label;
    });
  }

  @override
  void dispose() {
    _request?.cancel();
    _module.policy.removeListener(_policyChanged);
    super.dispose();
  }

  Future<void> _load([BookStackChapter? chapter]) async {
    if (_revoked) return;
    _request?.cancel();
    final token = _request = CancellationToken();
    setState(() {
      _busy = true;
      _chapter = chapter;
      if (chapter != null) _lastOpened = chapter.page;
      _content = null;
      _error = null;
    });
    bool current() =>
        mounted && identical(_request, token) && !token.isCancelled;
    try {
      final title = '${widget.title} ${chapter?.title ?? ''}';
      _module.library.requireImport(title);
      if (!await _module.discovery.isEnabled(bookStackSource)) {
        throw const PublicationFailure(PublicationProblem.blocked);
      }
      token.check();
      final http = _module.shares.http;
      if (chapter == null) {
        final chapters = await loadPublicationBookStack(
          http,
          widget.page,
          token,
        );
        if (current()) {
          setState(() {
            _chapters = chapters
                .where((item) => _module.policy.textAllowed(item.title))
                .toList();
            if (_chapters.isEmpty) _error = '来源暂未提供可阅读的章节';
          });
        }
      } else {
        final content = await loadPublicationBookStackChapter(
          http,
          chapter,
          token,
        );
        _module.library.requireImport(content);
        if (current()) setState(() => _content = content);
      }
    } on Exception catch (error) {
      if (current()) {
        setState(
          () => _error = switch (error) {
            PublicationFailure(:final problem) => problem.label,
            _ => PublicationProblem.network.label,
          },
        );
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _chapter;
    final index = _chapters.indexOf(chapter ?? (title: '', page: widget.page));
    return Scaffold(
      appBar: AppBar(
        title: Text(chapter?.title ?? (_revoked ? '在线阅读' : widget.title)),
        actions: [
          if (chapter != null)
            IconButton(
              tooltip: '返回目录',
              onPressed: () {
                _request?.cancel();
                setState(() {
                  _chapter = null;
                  _error = null;
                  _busy = false;
                });
              },
              icon: const Icon(Icons.list),
            ),
          if (!_revoked)
            IconButton(
              tooltip: '打开原站',
              onPressed: () =>
                  widget.openOriginal(chapter?.page ?? widget.page),
              icon: const Icon(Icons.open_in_new),
            ),
        ],
      ),
      body: switch ((_busy, _error, chapter)) {
        (true, _, null) => const Center(child: CircularProgressIndicator()),
        (true, _, _) => const Align(
          alignment: Alignment.topCenter,
          child: LinearProgressIndicator(semanticsLabel: '正在加载章节'),
        ),
        (_, final message?, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              if (!_revoked)
                TextButton(
                  onPressed: () => _load(chapter),
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
        (_, _, null) => ListView.builder(
          itemCount: _chapters.length,
          itemBuilder: (_, index) => ListTile(
            title: Text(_chapters[index].title),
            selected: _chapters[index].page == _lastOpened,
            trailing: Icon(
              _chapters[index].page == _lastOpened
                  ? Icons.check
                  : Icons.chevron_right,
            ),
            onTap: () => _load(_chapters[index]),
          ),
        ),
        _ => ListView(
          key: ValueKey(chapter),
          padding: const EdgeInsets.all(20),
          children: [
            SelectableText(
              _content ?? '',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                if (index > 0)
                  TextButton(
                    onPressed: () => _load(_chapters[index - 1]),
                    child: const Text('上一章'),
                  ),
                if (index >= 0 && index + 1 < _chapters.length)
                  TextButton(
                    onPressed: () => _load(_chapters[index + 1]),
                    child: const Text('下一章'),
                  ),
              ],
            ),
          ],
        ),
      },
    );
  }
}
