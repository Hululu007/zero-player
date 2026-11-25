import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network/cancellation_token.dart';
import '../data/cloud_resource_search.dart';
import '../data/cloud_shared_file.dart';
import '../domain/publication.dart';
import 'publication_management_view.dart' show publicationSize;

typedef CloudSearchInspect =
    Future<CloudShareListing> Function(
      Uri link,
      String? code,
      CancellationToken token,
    );

final class CloudSearchSharePreview extends StatefulWidget {
  const CloudSearchSharePreview({
    super.key,
    required this.hit,
    required this.inspect,
    required this.allowed,
    this.download,
    required this.open,
  });

  final CloudSearchHit hit;
  final CloudSearchInspect inspect;
  final bool Function(String) allowed;
  final VoidCallback? download;
  final VoidCallback open;

  @override
  State<CloudSearchSharePreview> createState() =>
      _CloudSearchSharePreviewState();
}

final class _CloudSearchSharePreviewState
    extends State<CloudSearchSharePreview> {
  CancellationToken? _token;
  Future<CloudShareListing>? _listing;
  int _limit = 5;

  @override
  void didUpdateWidget(CloudSearchSharePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hit.code != widget.hit.code && _listing != null) _load();
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  void _load() {
    _token?.cancel();
    final token = _token = CancellationToken();
    setState(() {
      _listing = Future.sync(
        () => widget.inspect(widget.hit.link, widget.hit.code, token),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(widget.hit.title),
    subtitle: Text(
      [
        widget.hit.source,
        widget.hit.link.host,
        if (widget.hit.code != null) '含提取码',
      ].join(' · '),
    ),
    childrenPadding: const EdgeInsetsDirectional.fromSTEB(24, 0, 12, 8),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    onExpansionChanged: (expanded) {
      if (expanded && _listing == null) _load();
    },
    children: [
      if (_listing != null)
        FutureBuilder<CloudShareListing>(
          future: _listing,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              final message = switch (snapshot.error) {
                PublicationFailure(:final problem) => problem.label,
                FormatException(:final message) => message,
                _ => '暂时无法读取分享',
              };
              return Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(message),
                  TextButton(onPressed: _load, child: const Text('重试')),
                  TextButton(onPressed: _copyLink, child: const Text('复制链接')),
                ],
              );
            }
            final listing = snapshot.requireData;
            final files = listing.files
                .where(
                  (item) =>
                      widget.allowed(item.file.name) &&
                      item.folders.every(widget.allowed),
                )
                .toList();
            if (files.isEmpty) return const Text('没有可访问的文件');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in files.take(_limit))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      [
                        [...item.folders, item.file.name].join(' / '),
                        if (item.file.bytes case final bytes?)
                          publicationSize(bytes),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (files.length > _limit)
                  TextButton(
                    onPressed: () => setState(() => _limit += 20),
                    child: Text('显示更多（共 ${files.length} 个文件）'),
                  ),
                if (listing.truncated) const Text('分享目录仅返回部分文件'),
              ],
            );
          },
        ),
      Wrap(
        spacing: 8,
        children: [
          if (widget.download case final VoidCallback download)
            TextButton.icon(
              onPressed: download,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('解析并选择文件'),
            ),
          TextButton(onPressed: widget.open, child: const Text('在浏览器打开')),
        ],
      ),
    ],
  );

  Future<void> _copyLink() async {
    final hit = widget.hit;
    if (!widget.allowed('${hit.title} ${hit.link.host}')) return;
    await Clipboard.setData(ClipboardData(text: hit.link.toString()));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('链接已复制')));
  }
}
