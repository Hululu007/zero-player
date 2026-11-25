part of 'book_discovery_view.dart';

extension _BookDiscoveryToolbar on _BookDiscoveryViewState {
  Widget _searchField({bool autofocus = false}) => TextField(
    controller: _search,
    focusNode: _searchFocus,
    autofocus: autofocus,
    maxLength: 2048,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _submitSearch(),
    onChanged: (_) => _updateToolbar(() {}),
    decoration: InputDecoration(
      isDense: true,
      hintText: widget.kind == BookKind.audio ? '搜索作品' : '搜书名、作者或书籍链接',
      counterText: '',
      prefixIcon: const Icon(Icons.search),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_search.text.isNotEmpty)
            IconButton(
              tooltip: '清空搜索',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              onPressed: () {
                _search.clear();
                _updateToolbar(() {});
              },
              icon: const Icon(Icons.close, size: 20),
            ),
          IconButton(
            tooltip: '搜索',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            onPressed: _search.text.trim().isEmpty ? null : _submitSearch,
            icon: const Icon(Icons.arrow_forward, size: 20),
          ),
        ],
      ),
    ),
  );

  /// Collapsed search on phones: one pill that expands on tap and folds back
  /// after a search or when the reader starts scrolling the results.
  Widget _searchEntry() {
    final hint = widget.kind == BookKind.audio ? '搜索作品' : '搜书名、作者或书籍链接';
    final typed = _search.text.trim();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openSearch,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.search, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  typed.isEmpty ? hint : typed,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: typed.isEmpty
                        ? Theme.of(context).hintColor
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(double gutter, {required bool compact}) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, 8, gutter, compact ? 2 : 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (compact) {
          return Row(
            children: [
              Expanded(
                child: _searchOpen
                    ? _searchField(autofocus: true)
                    : _searchEntry(),
              ),
              if (_searchOpen)
                IconButton(
                  tooltip: '收起搜索框',
                  onPressed: _closeSearch,
                  icon: const Icon(Icons.close),
                )
              else ...[
                IconButton.filledTonal(
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: _search.text.trim().isEmpty
                      ? _openSearch
                      : _submitSearch,
                ),
              ],
            ],
          );
        }
        final search = _searchField();
        final actions = <Widget>[
          IconButton.filledTonal(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _search.text.trim().isEmpty ? null : _submitSearch,
          ),
          if (_source == null)
            IconButton(
              tooltip: _channelsOnly ? '展开全部书单' : '折叠书单，仅显示渠道',
              isSelected: _channelsOnly,
              onPressed: _toggleChannelsOnly,
              icon: const Icon(Icons.unfold_less),
              selectedIcon: const Icon(Icons.unfold_more),
            ),
        ];
        if (constraints.maxWidth < 420) {
          return Column(
            children: [
              search,
              Align(
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: search),
            ...actions,
          ],
        );
      },
    ),
  );

  Widget _browseHeader(double gutter, {required bool compact}) {
    final theme = Theme.of(context);
    final source = _source?.source;
    final status =
        _error != null &&
            (_recommended.isNotEmpty || _results[_sourceId]?.isNotEmpty == true)
        ? _error
        : _busy && (source == null || _page == 1)
        ? (_total == 0 ? '正在加载…' : '$_completed / $_total 个渠道')
        : _failures.isEmpty
        ? null
        : '${_failures.length} 个渠道加载失败';
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final picker = Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _pickSource,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.hub_outlined, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          source?.name ?? (_showQidian ? '精选推荐' : '聚合渠道'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              );
              final actions = _browseActions(source);
              if (compact) {
                // A single scrolling icon row keeps the header one line tall on
                // phones instead of wrapping the actions into several rows.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    picker,
                    SizedBox(
                      height: 46,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: actions,
                      ),
                    ),
                  ],
                );
              }
              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    picker,
                    Wrap(spacing: 2, children: actions),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: picker),
                  ...actions,
                ],
              );
            },
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Text(status, style: theme.textTheme.bodySmall),
            ),
          if (_categories.any(
            (item) => bookCategoryAllowed(widget.repository.policy, item),
          ))
            _categoryBar(compact: compact),
          if (_groupId != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_group?.name ?? '当前分组'),
            ),
          if (source == null && widget.kind == BookKind.text && !_channelsOnly)
            _recommendationControls(),
        ],
      ),
    );
  }

  List<Widget> _browseActions(BookSource? source) => [
    IconButton(
      tooltip: '按分组发现',
      isSelected: _groupId != null,
      icon: const Icon(Icons.folder_outlined),
      selectedIcon: const Icon(Icons.folder_open),
      onPressed: _pickGroup,
    ),
    if (source == null && !_showQidian)
      IconButton(
        tooltip: '选择发现渠道',
        onPressed: _pickVisibleSources,
        icon: const Icon(Icons.checklist),
      ),
    if (source == null && !_showQidian)
      IconButton(
        tooltip: _favorites ? '显示全部渠道' : '仅收藏源',
        isSelected: _favorites,
        icon: const Icon(Icons.star_border),
        selectedIcon: const Icon(Icons.star),
        onPressed: () {
          _updateToolbar(() => _favorites = !_favorites);
          unawaited(_load());
        },
      ),
    if (_source case final BookSourceEntry entry) _favoriteButton(entry),
    if (source != null) _selectedSourceMenu(source),
    if (source == null && _aggregate)
      IconButton(
        tooltip: '渠道书单点击方式',
        onPressed: _openMode,
        icon: const Icon(Icons.settings_outlined),
      ),
    IconButton(
      tooltip: '刷新当前页面',
      onPressed: _busy ? null : _refreshListing,
      icon: const Icon(Icons.refresh),
    ),
  ];

  Widget _categoryBar({required bool compact}) {
    final category = _category;
    final visible = [
      for (final item in _categories)
        if (item.address.isNotEmpty &&
            bookCategoryAllowed(widget.repository.policy, item))
          item,
    ];
    Widget chip(LegadoCategory item) => ChoiceChip(
      label: Text(
        bookCategoryLabel(item, _categories.indexOf(item)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: item == category,
      onSelected: (_) => _selectCategory(item),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: compact
          // One horizontally scrolling row keeps the phone header short instead
          // of growing to two or three wrapped rows.
          ? SizedBox(
              height: 32 + MediaQuery.textScalerOf(context).scale(14),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: visible.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) => chip(visible[index]),
              ),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [for (final item in visible) chip(item)],
            ),
    );
  }
}
