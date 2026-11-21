import 'package:flutter/material.dart';

import '../application/publication_discovery.dart';
import '../domain/publication.dart';

typedef PublicationBuy =
    void Function(PublicationEdition edition, PublicationFormat format);

class PublicationCatalogView extends StatelessWidget {
  const PublicationCatalogView({
    super.key,
    required this.input,
    required this.busy,
    required this.editions,
    required this.updates,
    required this.onSearch,
    this.onBrowse,
    this.onMore,
    required this.onBuy,
    required this.onShare,
    required this.onLocal,
    required this.onPage,
  });
  final TextEditingController input;
  final bool busy;
  final List<PublicationEdition> editions;
  final List<PublicationSearchUpdate> updates;
  final VoidCallback onSearch, onShare, onLocal;
  final VoidCallback? onBrowse, onMore;
  final PublicationBuy onBuy;
  final void Function(Uri) onPage;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<PublicationEdition>>{};
    for (final edition in editions) {
      (grouped[edition.workKey] ??= []).add(edition);
    }
    return CustomScrollView(
      slivers: [
        _searchControls(context),
        if (!busy && grouped.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(updates.isEmpty ? '搜索已启用的图书来源' : '没有匹配的图书'),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          sliver: SliverList.builder(
            itemCount: grouped.length,
            itemBuilder: (context, index) {
              final versions = grouped.values.elementAt(index);
              final first = versions.first;
              return Card(
                child: ExpansionTile(
                  key: PageStorageKey(first.workKey),
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(first.title),
                  subtitle: Text(
                    [
                      first.author,
                      '${versions.length} 个版本',
                    ].where((part) => part.isNotEmpty).join(' · '),
                  ),
                  initiallyExpanded: versions.length == 1 && index == 0,
                  children: [
                    for (final edition in versions) _version(context, edition),
                  ],
                ),
              );
            },
          ),
        ),
        if (!busy && grouped.isNotEmpty && onMore != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(onPressed: onMore, child: const Text('浏览更多图书')),
            ),
          ),
      ],
    );
  }

  Widget _searchControls(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: input,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            decoration: InputDecoration(
              labelText: '书名、作者或 ISBN',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '搜索图书',
                onPressed: onSearch,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onBrowse != null)
                FilledButton.icon(
                  onPressed: busy ? null : onBrowse,
                  icon: const Icon(Icons.explore_outlined),
                  label: const Text('浏览图书'),
                ),
              OutlinedButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.link),
                label: const Text('解析分享'),
              ),
              OutlinedButton.icon(
                onPressed: onLocal,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('导入本地文件'),
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: LinearProgressIndicator(),
            ),
          for (final result in updates)
            if (result.problem case final problem?)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  '${result.source.name} · ${problem.label}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
        ],
      ),
    ),
  );

  Widget _version(BuildContext context, PublicationEdition edition) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            edition.edition.isEmpty ? '版次未知' : edition.edition,
            edition.language.isEmpty ? '语种未知' : edition.language,
            if (edition.translator.isNotEmpty) '译者 ${edition.translator}',
            if (edition.isbn.isNotEmpty) 'ISBN ${edition.isbn}',
            if (edition.license.isNotEmpty) edition.license,
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final format
                in edition.candidates.map((item) => item.format).toSet())
              ActionChip(
                avatar: const Icon(Icons.download_outlined, size: 18),
                label: Text(format.label),
                onPressed: () => onBuy(edition, format),
              ),
            if (edition.candidates.isEmpty) const Text('可查看书目信息'),
            if (edition.page case final uri?)
              TextButton(
                onPressed: () => onPage(uri),
                child: const Text('来源链接'),
              ),
          ],
        ),
      ],
    ),
  );
}
