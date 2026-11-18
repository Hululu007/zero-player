import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../data/book_site_check.dart';
import '../data/books_repository.dart';
import '../domain/book.dart';

/// A scan belongs to one detail page identity. Selecting an already checked
/// channel cancels the remaining work before handing it to the guarded switch.
final class BookEditionPanel extends StatefulWidget {
  const BookEditionPanel({
    super.key,
    required this.repository,
    required this.book,
    required this.busy,
    required this.onSelected,
  });

  final BooksRepository repository;
  final Book book;
  final bool busy;
  final ValueChanged<BookEdition> onSelected;

  @override
  State<BookEditionPanel> createState() => _BookEditionPanelState();
}

final class _BookEditionPanelState extends State<BookEditionPanel> {
  final _updates = <String, BookEditionUpdate>{};
  CancellationToken? _token;
  int _completed = 0, _total = 0;
  bool _running = false, _expanded = true;
  String? _error;
  late String _policy;
  BooksRepository get _books => widget.repository;

  @override
  void initState() {
    super.initState();
    _policy = bookSitePolicySnapshot(_books.policy);
    _books.policy.addListener(_policyChanged);
    _books.sourceConfigurationChanges.addListener(_invalidate);
    _books.bookPolicyChanges.addListener(_checkAllowed);
  }

  @override
  void dispose() {
    _token?.cancel();
    _books.policy.removeListener(_policyChanged);
    _books.sourceConfigurationChanges.removeListener(_invalidate);
    _books.bookPolicyChanges.removeListener(_checkAllowed);
    super.dispose();
  }

  void _policyChanged() {
    final next = bookSitePolicySnapshot(_books.policy);
    if (next != _policy) _invalidate();
    _policy = next;
    _checkAllowed();
  }

  void _checkAllowed() {
    if (!_books.bookAllowed(widget.book) ||
        _updates.values.any(
          (u) => u.edition != null && !_books.bookAllowed(u.edition!.book),
        )) {
      _invalidate();
    }
  }

  void _invalidate() {
    _token?.cancel();
    _token = null;
    if (!mounted) return;
    setState(() {
      _running = false;
      _updates.clear();
      _completed = _total = 0;
      _error = null;
    });
  }

  Future<void> _scan() async {
    _invalidate();
    if (bookIdentity(widget.book.author).isEmpty) {
      setState(() => _error = '缺少作者信息，无法可靠匹配其他渠道');
      return;
    }
    final token = _token = CancellationToken();
    setState(() {
      _running = true;
      _expanded = true;
    });
    try {
      await _books.alternatives(
        widget.book,
        token,
        refresh: true,
        includeCurrent: true,
        onProgress: (update) {
          if (!mounted || token.isCancelled || _token != token) return;
          setState(() {
            _completed = update.completed;
            _total = update.total;
            if (update.source case final source?) {
              _updates[source.source.id] = update;
            }
          });
        },
      );
    } on RequestCancelled {
      // Cancellation keeps already checked results unless access was revoked.
    } on Exception {
      if (mounted && _token == token) {
        setState(() => _error = '渠道检测未完成，请重试');
      }
    } finally {
      if (mounted && _token == token) setState(() => _running = false);
    }
  }

  void _select(BookEdition edition) {
    if (!_books.bookAllowed(widget.book) || !_books.bookAllowed(edition.book)) {
      return;
    }
    _token?.cancel();
    setState(() => _running = false);
    widget.onSelected(edition);
  }

  @override
  Widget build(BuildContext context) {
    final results =
        _updates.values
            .where(
              (u) => u.edition != null && _books.bookAllowed(u.edition!.book),
            )
            .toList()
          ..sort(
            (a, b) => b.edition!.chapters.length.compareTo(
              a.edition!.chapters.length,
            ),
          );
    final best = results.firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: widget.busy || !_books.bookAllowed(widget.book)
                    ? null
                    : _running
                    ? () {
                        _token?.cancel();
                        setState(() => _running = false);
                      }
                    : _scan,
                icon: Icon(
                  _running ? Icons.stop : Icons.published_with_changes,
                ),
                label: Text(_running ? '停止渠道检测' : '检测各渠道最新章节'),
              ),
              if (_total > 0) Text('已检测 $_completed / $_total 个渠道'),
            ],
          ),
          if (_running) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (best != null)
            Text(
              '当前检测最新（按目录章数）：${best.source!.source.name} · '
              '${best.edition!.chapters.last.title} · ${best.edition!.chapters.length} 章',
            ),
          if (_updates.isNotEmpty) ...[
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起渠道结果' : '展开渠道结果'),
            ),
            if (_expanded)
              SizedBox(
                height: math.min(280, _updates.length * 76).toDouble(),
                child: ListView.builder(
                  itemCount: _updates.length,
                  itemBuilder: (context, index) =>
                      _row(_updates.values.elementAt(index)),
                ),
              ),
          ],
          if (!_running &&
              _total > 0 &&
              _completed == _total &&
              results.isEmpty)
            const Text('未检测到可用的同名同作者目录，请检查已启用的渠道'),
        ],
      ),
    );
  }

  Widget _row(BookEditionUpdate update) {
    final edition = update.edition;
    final current = update.source!.source.id == widget.book.sourceId;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${update.source!.source.name}${current ? '（当前）' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        edition == null
            ? update.failed
                  ? '检测失败，可重试'
                  : '未找到同名同作者的可用目录'
            : '${edition.chapters.length} 章 · ${edition.chapters.last.title}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: edition == null || current
          ? null
          : TextButton(
              onPressed: widget.busy ? null : () => _select(edition),
              child: const Text('跳转'),
            ),
    );
  }
}
