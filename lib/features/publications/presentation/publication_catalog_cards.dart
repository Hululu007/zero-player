import '../data/publication_bookstack_reader.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../../../core/network/poster_repository.dart';
import '../data/publication_recommendations.dart';
import '../domain/publication.dart';

class PublicationWorkCard extends StatelessWidget {
  const PublicationWorkCard({
    super.key,
    required this.editions,
    required this.featured,
    required this.initiallyExpanded,
    required this.covers,
    this.recommendations,
    required this.allowed,
    required this.sourceName,
    required this.onBuy,
    required this.onResource,
    required this.onPage,
    this.onReadOnline,
    required this.onFind,
    required this.onAddToList,
    required this.isLocal,
    this.onChannel,
  });

  final List<PublicationEdition> editions;
  final bool featured, initiallyExpanded;
  final PosterRepository? covers;
  final PublicationRecommendations? recommendations;
  final bool Function(String) allowed;
  final String Function(PublicationEdition) sourceName;
  final void Function(PublicationEdition, PublicationFormat) onBuy;
  final void Function(PublicationEdition, PublicationResource, bool) onResource;
  final void Function(Uri) onPage;
  final ValueChanged<PublicationEdition>? onReadOnline;
  final void Function(PublicationEdition) onFind;
  final void Function(PublicationEdition) onAddToList;
  final void Function(PublicationEdition)? onChannel;
  final bool Function(PublicationEdition, PublicationFormat) isLocal;

  Iterable<PublicationFormat> _formats(PublicationEdition edition) =>
      PublicationFormat.values.where(
        (format) =>
            isLocal(edition, format) ||
            edition.candidates.any((candidate) => candidate.format == format),
      );

  @override
  Widget build(BuildContext context) {
    final first = editions.first;
    final cover = editions
        .map((item) => item.cover)
        .whereType<Uri>()
        .firstOrNull;
    final quick = editions
        .where((edition) => _formats(edition).isNotEmpty)
        .firstOrNull;
    final resourceEdition = editions
        .where((edition) => edition.resources.isNotEmpty)
        .firstOrNull;
    final summaryResource = quick == null
        ? resourceEdition?.resources.first
        : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: SizedBox(
          width: 42,
          height: 56,
          child: _PublicationCover(uri: cover, repository: covers),
        ),
        title: Text(first.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (first.author.isNotEmpty) first.author,
                if (featured &&
                    first.rating.isNotEmpty &&
                    allowed(first.rating))
                  first.rating,
                if (!featured && editions.length > 1) '${editions.length} 个版本',
                if (!featured && editions.length == 1) sourceName(first),
              ].where((value) => value.isNotEmpty).join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (quick != null || summaryResource != null)
              Wrap(
                spacing: 6,
                children: [
                  if (quick != null)
                    for (final format in _formats(quick))
                      _acquire(quick, format),
                  if (summaryResource != null)
                    _resource(resourceEdition!, summaryResource),
                ],
              ),
          ],
        ),
        children: [
          for (final edition in editions)
            _version(context, edition, summaryResource),
        ],
      ),
    );
  }

  Widget _resource(PublicationEdition book, PublicationResource resource) =>
      ActionChip(
        avatar: Icon(
          resource.canListFiles || resource.lookupRequired
              ? Icons.folder_open
              : Icons.open_in_new,
          size: 18,
        ),
        label: Text(
          resource.canListFiles ? '查看${resource.label}文件' : resource.label,
        ),
        onPressed: () => onResource(
          book,
          resource,
          !resource.canListFiles && !resource.lookupRequired,
        ),
      );

  Widget _acquire(PublicationEdition edition, PublicationFormat format) {
    final local = isLocal(edition, format);
    return ActionChip(
      avatar: Icon(
        local ? Icons.menu_book_outlined : Icons.download_outlined,
        size: 18,
      ),
      label: Text('${local ? '阅读' : '下载'} ${format.label}'),
      onPressed: () => onBuy(edition, format),
    );
  }

  Widget _version(
    BuildContext context,
    PublicationEdition edition,
    PublicationResource? summaryResource,
  ) {
    final metadata = [
      if (!featured && editions.length > 1) sourceName(edition),
      edition.publisher,
      edition.edition,
      edition.language,
      if (edition.translator.isNotEmpty) '译者 ${edition.translator}',
      if (edition.isbn.isNotEmpty) 'ISBN ${edition.isbn}',
      edition.license,
      ...edition.tags.take(4),
    ].where((value) => value.isNotEmpty && allowed(value)).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (metadata.isNotEmpty)
              Text(metadata, style: Theme.of(context).textTheme.bodySmall),
            if (featured && edition.page?.host == PublicationBoard.douban.host)
              _FeaturedDetails(
                key: ValueKey((edition.id, recommendations)),
                book: edition,
                source: recommendations,
                allowed: allowed,
              )
            else if (edition.description.isNotEmpty &&
                allowed(edition.description))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(edition.description),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (editions.length > 1)
                  for (final format in _formats(edition))
                    _acquire(edition, format),
                for (final resource in edition.resources) ...[
                  if (resource != summaryResource &&
                      (resource.canListFiles || resource.lookupRequired))
                    _resource(edition, resource),
                  if (!resource.lookupRequired)
                    TextButton(
                      onPressed: () => onResource(edition, resource, true),
                      child: Text(
                        resource.label.startsWith('原站')
                            ? resource.label
                            : '打开${resource.label}',
                      ),
                    ),
                ],
                if (featured ||
                    (!edition.hasDownload && _formats(edition).isEmpty))
                  TextButton(
                    onPressed: () => onFind(edition),
                    child: const Text('查找可下载版本'),
                  ),
                if (edition.page case final uri?
                    when onReadOnline != null &&
                        publicationBookStackId(uri) != null)
                  FilledButton.tonalIcon(
                    onPressed: () => onReadOnline!(edition),
                    icon: const Icon(Icons.menu_book_outlined),
                    label: const Text('在线阅读'),
                  ),
                if (onChannel case final open?)
                  TextButton(
                    onPressed: () => open(edition),
                    child: const Text('进入渠道'),
                  ),
                TextButton(
                  onPressed: () => onAddToList(edition),
                  child: const Text('加入书单'),
                ),
                if (edition.page case final uri?)
                  TextButton(
                    onPressed: () => onPage(uri),
                    child: const Text('来源链接'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturedDetails extends StatefulWidget {
  const _FeaturedDetails({
    super.key,
    required this.book,
    required this.source,
    required this.allowed,
  });

  final PublicationEdition book;
  final PublicationRecommendations? source;
  final bool Function(String) allowed;

  @override
  State<_FeaturedDetails> createState() => _FeaturedDetailsState();
}

class _FeaturedDetailsState extends State<_FeaturedDetails> {
  final _token = CancellationToken();
  late final _detail = widget.source?.details(widget.book, _token);

  @override
  void dispose() {
    _token.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<PublicationFeaturedDetails?>(
        future: _detail,
        builder: (_, snapshot) {
          final isbn = snapshot.data?.isbn ?? '';
          final description = snapshot.data?.description;
          final summary =
              description?.isNotEmpty == true && widget.allowed(description!)
              ? description
              : widget.book.description;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isbn.isNotEmpty && widget.allowed(isbn)) Text('ISBN $isbn'),
              if (summary.isNotEmpty && widget.allowed(summary))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(summary),
                ),
            ],
          );
        },
      );
}

class _PublicationCover extends StatefulWidget {
  const _PublicationCover({required this.uri, required this.repository});
  final Uri? uri;
  final PosterRepository? repository;

  @override
  State<_PublicationCover> createState() => _PublicationCoverState();
}

class _PublicationCoverState extends State<_PublicationCover> {
  PosterLease? _lease;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PublicationCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  void _load() {
    _lease?.release();
    final uri = widget.uri;
    _lease = uri == null ? null : widget.repository?.acquire(uri.toString());
  }

  @override
  void dispose() {
    _lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: FutureBuilder<Uint8List>(
      key: ValueKey((widget.uri, widget.repository)),
      future: _lease?.bytes,
      builder: (_, snapshot) => snapshot.hasData
          ? Image.memory(
              snapshot.data!,
              cacheWidth: 144,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => _placeholder(context),
            )
          : _placeholder(context),
    ),
  );

  Widget _placeholder(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Center(child: Icon(Icons.menu_book_outlined, size: 20)),
  );
}
