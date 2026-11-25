import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/cancellation_token.dart';
import '../application/publication_discovery.dart';
import '../application/publication_module.dart';
import '../data/publication_panda_directory.dart';
import '../data/publication_recommendations.dart';
import '../data/publication_download_filter.dart';
import '../domain/publication.dart';
import 'publication_catalog_cards.dart';
import 'publication_channel_picker.dart';
import 'publication_management_view.dart';
import 'publication_panda_dialog.dart';

enum _Mode { featured, aggregate, channel }

extension on PublicationSearchField {
  String get label => switch (this) {
    PublicationSearchField.all => '综合',
    PublicationSearchField.title => '书名',
    PublicationSearchField.author => '作者',
    PublicationSearchField.isbn => 'ISBN',
  };

  String get inputLabel => switch (this) {
    PublicationSearchField.all => '书名、作者或 ISBN',
    _ => '输入$label',
  };
}

enum _FormatFilter {
  all('全部格式'),
  downloadable('有下载入口'),
  listing('仅书目'),
  epub('EPUB', PublicationFormat.epub),
  pdf('PDF', PublicationFormat.pdf),
  kindle('MOBI / AZW / AZW3'),
  zip('ZIP', PublicationFormat.zip);

  const _FormatFilter(this.label, [this.format]);
  final String label;
  final PublicationFormat? format;

  bool matches(PublicationEdition edition) => switch (this) {
    all => true,
    downloadable => edition.hasDownload,
    listing => !edition.hasDownload,
    kindle =>
      edition.candidates.any((item) => item.format.isKindle) ||
          edition.resources.any((item) => item.format?.isKindle == true),
    _ =>
      edition.candidates.any((item) => item.format == format) ||
          edition.resources.any((item) => item.format == format),
  };
}

class PublicationCatalogView extends StatefulWidget {
  const PublicationCatalogView({
    super.key,
    required this.module,
    required this.sources,
    required this.visible,
    required this.policyRevision,
    required this.onManage,
    required this.onBuy,
    required this.onResource,
    required this.onShare,
    required this.onLocal,
    required this.onPage,
    required this.onLists,
    required this.onAddToList,
    required this.isLocal,
    this.searchRequest,
    this.channelGroups = const {},
    this.onManageGroups,
    this.channelRequest,
    this.onReadOnline,
  });

  final PublicationModule module;
  final List<PublicationSourceStatus> sources;
  final bool visible;
  final int policyRevision;
  final VoidCallback onManage, onShare, onLocal;
  final void Function(
    PublicationEdition,
    PublicationFormat,
    List<PublicationEdition>,
  )
  onBuy;
  final void Function(PublicationEdition, PublicationResource, bool) onResource;
  final void Function(Uri) onPage;
  final VoidCallback onLists;
  final void Function(PublicationEdition) onAddToList;
  final bool Function(PublicationEdition, PublicationFormat) isLocal;
  final (PublicationEdition, int)? searchRequest;
  final PublicationChannelGroups channelGroups;
  final VoidCallback? onManageGroups;
  final ValueChanged<PublicationEdition>? onReadOnline;
  final (String, int)? channelRequest;

  @override
  State<PublicationCatalogView> createState() => PublicationCatalogViewState();
}

typedef _CatalogLocation = ({
  _Mode mode,
  PublicationBoard board,
  _FormatFilter format,
  PublicationSearchField field,
  PublicationSearchScope scope,
  PublicationDownloadFilter download,
  String query,
  int pages,
  double offset,
  Map<String, PublicationSearchUpdate> updates,
  Map<String, PublicationEdition> recommendations,
});

class PublicationCatalogViewState extends State<PublicationCatalogView>
    with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _updates = <String, PublicationSearchUpdate>{};
  final _recommended = <String, PublicationEdition>{};
  final _history = <_CatalogLocation>[];
  final _showTop = ValueNotifier(false);
  CancellationToken? _request;
  _Mode _mode = _Mode.featured;
  PublicationBoard _board = PublicationBoard.douban;
  _FormatFilter _format = _FormatFilter.all;
  PublicationSearchField _field = PublicationSearchField.all;
  PublicationSearchScope _scope = allPublicationChannels;
  String? get _channel => _scope.channel;
  PublicationDownloadFilter _download = PublicationDownloadFilter.all;
  int? _handledChannel;

  bool _inScope(PublicationSourceStatus item) {
    if (_channel != null) return item.source.id == _channel;
    if (_scope.favorites) return item.favorite;
    if (_scope.group case final group?) {
      return widget.channelGroups[group]?.contains(item.source.id) == true;
    }
    return true;
  }

  List<PublicationSourceStatus> get _scoped =>
      _channels.where(_inScope).toList();

  String _query = '';
  String? _error;
  bool _started = false, _busy = false, _startScheduled = false;
  int _pages = 0;
  int? _handledSearch;

  List<PublicationSourceStatus> get _channels => widget.sources
      .where(
        (item) =>
            item.enabled && widget.module.discovery.manageable(item.source),
      )
      .toList();

  bool get _canBrowseDirectory {
    final supervision = widget.module.policy.supervision;
    return !supervision.enabled && !supervision.corrupted;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_observeScroll);
    _startWhenVisible();
  }

  @override
  void didUpdateWidget(covariant PublicationCatalogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedPolicy = oldWidget.policyRevision != widget.policyRevision;
    if (changedPolicy) {
      _cancel();
      _updates.clear();
      _recommended.clear();
      _history.clear();
      _query = '';
      _input.clear();
      _pages = 0;
      _started = false;
      _error = null;
    }
    if (oldWidget.sources != widget.sources || changedPolicy) {
      final active = {
        for (final item in _channels) item.source.id: item.source,
      };
      _updates.removeWhere(
        (id, result) => active[id]?.sameConfiguration(result.source) != true,
      );
    }
    // Source checks and navigation can rebuild this view while a search streams.
    // The current search keeps its scope until the user submits another one.
    _startWhenVisible();
  }

  void _observeScroll() {
    _showTop.value = _scroll.hasClients && _scroll.offset > 420;
  }

  void _startWhenVisible() {
    if (!widget.visible || _startScheduled) return;
    final pending = widget.searchRequest;
    final channel = widget.channelRequest;
    if (_started &&
        (pending == null || pending.$2 == _handledSearch) &&
        (channel == null || channel.$2 == _handledChannel)) {
      return;
    }
    _startScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScheduled = false;
      if (!mounted || !widget.visible) return;
      final pending = widget.searchRequest;
      final channel = widget.channelRequest;
      if (channel != null && channel.$2 != _handledChannel) {
        _handledChannel = channel.$2;
        _selectChannel(channel.$1);
      } else if (pending != null && pending.$2 != _handledSearch) {
        _handledSearch = pending.$2;
        _findDownload(pending.$1);
      } else if (!_started) {
        unawaited(_load());
      }
    });
  }

  bool get hasHistory => _history.isNotEmpty;

  void _remember() {
    if (!_started) return;
    if (_history.length == 8) _history.removeAt(0);
    _history.add((
      mode: _mode,
      board: _board,
      format: _format,
      field: _field,
      scope: _scope,
      download: _download,
      query: _query,
      pages: _pages,
      offset: _scroll.hasClients ? _scroll.offset : 0,
      updates: Map.of(_updates),
      recommendations: Map.of(_recommended),
    ));
  }

  bool goBack() {
    if (_history.isEmpty) return false;
    _cancel();
    final previous = _history.removeLast();
    final enabled = {
      for (final item in _channels)
        if (!item.paused) item.source.id: item.source,
    };
    setState(() {
      _mode = previous.mode;
      _board = previous.board;
      _format = previous.format;
      _field = previous.field;
      _scope = previous.scope;
      _download = previous.download;
      _query = _input.text = previous.query;
      _error = null;
      _pages = previous.pages;
      _updates
        ..clear()
        ..addEntries(
          previous.updates.entries.where(
            (entry) =>
                enabled[entry.key]?.sameConfiguration(entry.value.source) ==
                true,
          ),
        );
      _recommended
        ..clear()
        ..addAll(previous.recommendations);
    });
    if (_pages == 0 ||
        (_mode == _Mode.channel && !enabled.containsKey(_channel))) {
      unawaited(_load());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(
          previous.offset.clamp(0.0, _scroll.position.maxScrollExtent),
        );
      });
    }
    return true;
  }

  void _cancel() {
    _request?.cancel();
    _request = null;
    _busy = false;
  }

  void _top({bool animate = false}) {
    if (!_scroll.hasClients) return;
    if (animate) {
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _scroll.jumpTo(0);
    }
  }

  void _showFeatured() {
    if (_mode == _Mode.featured) return;
    setState(() {
      _mode = _Mode.featured;
      _scope = allPublicationChannels;
      _format = _FormatFilter.all;
      _download = PublicationDownloadFilter.all;
      _history.clear();
      _input.clear();
      _query = '';
    });
    unawaited(_load());
  }

  Future<void> _pickChannels() async {
    var channels = _channels;
    try {
      channels = (await widget.module.discovery.sources())
          .where(
            (item) =>
                item.enabled && widget.module.discovery.manageable(item.source),
          )
          .toList();
    } on Exception {
      // A transient settings read can still use the most recent snapshot.
    }
    if (!mounted || !widget.visible) return;
    final scope = await pickPublicationChannels(
      context,
      channels,
      widget.channelGroups,
      _scope,
      (item, favorite) =>
          widget.module.discovery.setFavorite(item.source, favorite),
    );
    if (mounted && scope != null) _selectScope(scope);
  }

  void _search({
    String? title,
    bool remember = true,
    PublicationSearchField? field,
  }) {
    FocusScope.of(context).unfocus();
    if (title != null) _input.text = title;
    final query = publicationSearchQuery(_input.text);
    if (query.isEmpty && _mode != _Mode.channel) {
      setState(() => _error = '请输入要搜索的图书');
      return;
    }
    final nextField = field ?? _field;
    if (remember &&
        (_mode == _Mode.featured || query != _query || nextField != _field)) {
      _remember();
    }
    setState(() {
      if (_mode == _Mode.featured) {
        _mode = _Mode.aggregate;
        _format = _FormatFilter.all;
      }
      if (title == null && _format == _FormatFilter.downloadable) {
        _format = _FormatFilter.all;
      }
      _query = query;
      _field = nextField;
    });
    unawaited(_load());
  }

  void _findDownload(PublicationEdition edition) {
    _remember();
    setState(() {
      _mode = _Mode.aggregate;
      _scope = allPublicationChannels;
      _download = PublicationDownloadFilter.all;
      _format = _FormatFilter.downloadable;
    });
    _search(
      title: edition.title,
      remember: false,
      field: PublicationSearchField.title,
    );
  }

  void _selectSearchField(PublicationSearchField? field) {
    if (field == null || field == _field) return;
    if (_query.isEmpty && publicationSearchQuery(_input.text).isEmpty) {
      setState(() => _field = field);
    } else {
      _search(field: field);
    }
  }

  void _selectChannel(String id) =>
      _selectScope((channel: id, group: null, favorites: false));

  void _selectScope(PublicationSearchScope scope) {
    if (_mode != _Mode.featured && _scope == scope) return;
    _remember();
    setState(() {
      _mode = scope.channel != null ? _Mode.channel : _Mode.aggregate;
      _scope = scope;
      _query = publicationSearchQuery(_input.text);
    });
    unawaited(_load());
  }

  String get _scopeLabel =>
      _scoped
          .where((item) => item.source.id == _channel)
          .firstOrNull
          ?.source
          .name ??
      _scope.group ??
      (_channel != null
          ? '所选渠道'
          : _scope.favorites
          ? '收藏渠道'
          : '全部渠道');

  Future<void> _openPanda() async {
    if (!_canBrowseDirectory) return;
    bool allowed(PublicationPandaEntry entry) =>
        mounted &&
        _canBrowseDirectory &&
        widget.module.discovery.allowed('${entry.name} ${entry.host}');
    final selected = await showPublicationPandaDirectory(
      context,
      enabled: {for (final item in _channels) item.source.id},
      allowed: allowed,
    );
    if (selected == null || !allowed(selected)) return;
    if (selected.sourceId case final id?) {
      if (_channels.any((item) => item.source.id == id)) _selectChannel(id);
    } else if (selected.website case final address?) {
      widget.onPage(address);
    }
  }

  Future<void> _load({bool more = false, bool refresh = false}) async {
    if (_mode != _Mode.featured &&
        _field == PublicationSearchField.isbn &&
        _query.isNotEmpty &&
        normalizedIsbn(_query).isEmpty) {
      _cancel();
      setState(() => _error = '请输入有效的 10 位或 13 位 ISBN');
      return;
    }
    _cancel();
    final token = _request = CancellationToken();
    final featured = _mode == _Mode.featured;
    final scoped = _scoped;
    final scope = _scope;
    final page = featured
        ? (more ? _pages + 1 : 1)
        : (more ? (_pages == 1 ? 3 : 5) : (_query.isEmpty ? 1 : 3));
    if (!more) _top();
    setState(() {
      _started = true;
      _busy = true;
      _error = null;
      if (!more) {
        _updates.clear();
        _recommended.clear();
        _pages = 0;
      }
    });
    try {
      if (featured) {
        final result = await widget.module.recommendations.load(
          _board,
          page,
          token,
          refresh: refresh,
        );
        if (!mounted || !identical(_request, token) || token.isCancelled) {
          return;
        }
        setState(() {
          for (final edition in result) {
            _recommended[edition.id] = edition;
          }
        });
      } else if (_mode == _Mode.channel || _query.isNotEmpty) {
        if (refresh && _mode == _Mode.channel) {
          final selected = scoped
              .where((entry) => entry.source.id == _channel && entry.paused)
              .firstOrNull;
          if (selected != null) {
            await widget.module.discovery.check(selected.source);
          }
          token.check();
        }
        await for (final result in widget.module.discovery.search(
          _query,
          token,
          maxPages: page,
          sourceId: scope.channel,
          sourceIds: scope.group == null
              ? null
              : widget.channelGroups[scope.group] ?? const {},
          favoritesOnly: scope.favorites,
          progressive: !more,
          field: _field,
        )) {
          if (!mounted || !identical(_request, token) || token.isCancelled) {
            return;
          }
          if (!_channels.any(
            (item) => item.source.sameConfiguration(result.source),
          )) {
            continue;
          }
          setState(() {
            final old = _updates[result.source.id];
            _updates[result.source.id] =
                (more || result.problem != null) &&
                    old != null &&
                    result.editions.isEmpty
                ? (
                    source: result.source,
                    editions: old.editions,
                    problem: result.problem,
                    complete: result.complete,
                  )
                : result;
          });
        }
      }
      if (mounted && identical(_request, token)) _pages = page;
    } on RequestCancelled {
      // Navigation or a new request invalidated this load.
    } catch (error) {
      if (mounted && identical(_request, token)) {
        _error = switch (error) {
          PublicationFailure(:final problem) => publicationSourceProblemLabel(
            problem,
          ),
          FormatException() => '来源返回的数据格式无效',
          _ => PublicationProblem.network.label,
        };
      }
    } finally {
      if (mounted && identical(_request, token)) {
        setState(() {
          _request = null;
          _busy = false;
        });
      }
    }
  }

  Future<void> _retrySource(String id) async {
    if (_busy ||
        _query.isNotEmpty &&
            _field == PublicationSearchField.isbn &&
            normalizedIsbn(_query).isEmpty) {
      return;
    }
    final token = _request = CancellationToken();
    setState(() => _busy = true);
    try {
      final source = _scoped.where((item) => item.source.id == id).firstOrNull;
      if (source != null && source.paused) {
        await widget.module.discovery.check(source.source);
      }
      token.check();
      await for (final result in widget.module.discovery.search(
        _query,
        token,
        sourceId: id,
        maxPages: _pages == 0 ? 3 : _pages,
        field: _field,
      )) {
        if (!mounted || !identical(_request, token) || token.isCancelled) {
          return;
        }
        final old = _updates[id];
        setState(() {
          _updates[id] = (
            source: result.source,
            editions: result.problem != null && result.editions.isEmpty
                ? old?.editions ?? const []
                : result.editions,
            problem: result.problem,
            complete: result.complete,
          );
        });
      }
    } on RequestCancelled {
      return;
    } catch (error) {
      if (mounted && identical(_request, token)) {
        _error = error is PublicationFailure
            ? publicationSourceProblemLabel(error.problem)
            : '暂时无法重试此渠道';
      }
    } finally {
      if (mounted && identical(_request, token)) {
        setState(() {
          _request = null;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final featured = _mode == _Mode.featured;
    final channels = _scoped;
    final all = <String, PublicationEdition>{};
    final sourceNames = <String, String>{};
    if (featured) {
      all.addAll(_recommended);
    } else {
      for (final result in _updates.values) {
        for (final edition in result.editions) {
          all.putIfAbsent(edition.id, () => edition);
          sourceNames.putIfAbsent(edition.id, () => result.source.name);
        }
      }
    }
    final works = _workGroups(all.values, featured);
    final canLoadMore = featured
        ? _pages > 0 && _pages < _board.pages
        : (_mode == _Mode.channel || _query.isNotEmpty) &&
              _pages > 0 &&
              _pages < 5 &&
              (all.isNotEmpty ||
                  (_query.isNotEmpty && channels.any((item) => !item.paused)));

    return Stack(
      children: [
        CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _toolbar()),
            if (_busy)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (!featured &&
                _mode == _Mode.aggregate &&
                _query.isNotEmpty &&
                channels.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '已完成 ${_updates.values.where((item) => item.complete).length} / ${channels.where((item) => !item.paused && !item.source.websiteOnly).length} 个渠道 · ${works.length} 部作品',
                  ),
                ),
              ),
            if (_error != null ||
                _updates.values.any((result) => result.problem != null))
              SliverToBoxAdapter(child: _problems(works.isNotEmpty)),
            if (!_busy && works.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: _empty(
                    featured,
                    channels.every((item) => item.paused),
                    all.isNotEmpty,
                  ),
                ),
              ),
            _cards(works, sourceNames, featured),
            if (!_busy && canLoadMore)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton(
                    onPressed: () => _load(more: true),
                    child: const Text('浏览更多图书'),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 72)),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: ValueListenableBuilder<bool>(
            valueListenable: _showTop,
            builder: (_, visible, _) => visible
                ? FloatingActionButton.small(
                    heroTag: null,
                    tooltip: '返回页首',
                    onPressed: () => _top(animate: true),
                    child: const Icon(Icons.vertical_align_top),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  List<List<PublicationEdition>> _workGroups(
    Iterable<PublicationEdition> editions,
    bool featured,
  ) {
    final grouped = <String, List<PublicationEdition>>{};
    for (final edition in editions) {
      if (!featured && !_download.matches(edition)) continue;
      if (featured ||
          _format.matches(edition) ||
          (_format == _FormatFilter.downloadable &&
              PublicationFormat.values.any(
                (format) => widget.isLocal(edition, format),
              ))) {
        (grouped[edition.workKey] ??= []).add(edition);
      }
    }
    final works = grouped.values.toList();
    if (!featured && _query.isNotEmpty) {
      final needle = _query.toLowerCase();
      final isbn = _field == PublicationSearchField.all
          ? normalizedIsbn(needle)
          : '';
      final order = {
        for (final (i, work) in works.indexed)
          work: (i, _relevance(work, needle, isbn)),
      };
      works.sort((a, b) {
        final rank = order[b]!.$2.compareTo(order[a]!.$2);
        return rank != 0 ? rank : order[a]!.$1.compareTo(order[b]!.$1);
      });
    }
    return works;
  }

  int _relevance(List<PublicationEdition> work, String needle, String isbn) {
    final value = switch (_field) {
      PublicationSearchField.all ||
      PublicationSearchField.title => work.first.title,
      PublicationSearchField.author => work.first.author,
      PublicationSearchField.isbn => '',
    };
    final text = publicationSearchQuery(value).toLowerCase();
    final exact =
        text == needle ||
        (isbn.isNotEmpty && work.any((item) => item.isbn == isbn));
    return (exact
            ? 8
            : text.startsWith(needle)
            ? 4
            : 0) +
        (work.any((item) => item.candidates.isNotEmpty) ? 2 : 0) +
        (work.any((item) => item.hasDownload) ? 1 : 0);
  }

  Widget _cards(
    List<List<PublicationEdition>> works,
    Map<String, String> sourceNames,
    bool featured,
  ) {
    final workIndices = {
      for (var i = 0; i < works.length; i++) works[i].first.workKey: i,
    };
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      sliver: SliverList.builder(
        itemCount: works.length,
        findChildIndexCallback: (key) =>
            key is PageStorageKey<String> ? workIndices[key.value] : null,
        itemBuilder: (context, index) {
          final books = works[index];
          return PublicationWorkCard(
            key: PageStorageKey(books.first.workKey),
            editions: books,
            featured: featured,
            initiallyExpanded: books.length == 1 && index == 0 && !featured,
            covers: widget.visible ? widget.module.covers : null,
            recommendations: featured && widget.visible
                ? widget.module.recommendations
                : null,
            allowed: widget.module.discovery.allowed,
            sourceName: (edition) =>
                featured ? _board.label : sourceNames[edition.id] ?? '',
            onPage: widget.onPage,
            onReadOnline: widget.onReadOnline,
            onResource: widget.onResource,
            onFind: _findDownload,
            onAddToList: widget.onAddToList,
            isLocal: widget.isLocal,
            onChannel: !featured && _mode == _Mode.aggregate
                ? (edition) {
                    final id = _updates.values
                        .where(
                          (result) => result.editions.any(
                            (row) => row.id == edition.id,
                          ),
                        )
                        .firstOrNull
                        ?.source
                        .id;
                    if (id != null) _selectChannel(id);
                  }
                : null,
            onBuy: (edition, format) => widget.onBuy(edition, format, books),
          );
        },
      ),
    );
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Semantics(
              label: '搜索类型',
              child: DropdownButton<PublicationSearchField>(
                value: _field,
                items: [
                  for (final field in PublicationSearchField.values)
                    DropdownMenuItem(value: field, child: Text(field.label)),
                ],
                onChanged: _selectSearchField,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _input,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: _field.inputLabel,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '搜索图书',
                    onPressed: () => _search(),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _browseControls(),
      ],
    ),
  );

  Widget _browseControls() => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (_mode == _Mode.featured)
        DropdownButton<PublicationBoard>(
          value: _board,
          items: [
            for (final board in PublicationBoard.values)
              DropdownMenuItem(value: board, child: Text(board.label)),
          ],
          onChanged: (board) {
            if (board == null || board == _board) return;
            setState(() => _board = board);
            unawaited(_load());
          },
        ),
      if (_mode != _Mode.featured)
        TextButton.icon(
          onPressed: _showFeatured,
          icon: const Icon(Icons.arrow_back),
          label: const Text('推荐'),
        ),
      OutlinedButton.icon(
        onPressed: _pickChannels,
        icon: const Icon(Icons.manage_search),
        label: Text(
          _mode == _Mode.featured ? '选择渠道' : _scopeLabel,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (_mode != _Mode.featured)
        DropdownButton<_FormatFilter>(
          value: _format,
          items: [
            for (final filter in _FormatFilter.values)
              DropdownMenuItem(value: filter, child: Text(filter.label)),
          ],
          onChanged: (filter) {
            if (filter == null) return;
            setState(() => _format = filter);
            _top();
          },
        ),
      if (_mode != _Mode.featured)
        DropdownButton<PublicationDownloadFilter>(
          value: _download,
          items: [
            for (final filter in PublicationDownloadFilter.values)
              DropdownMenuItem(value: filter, child: Text(filter.label)),
          ],
          onChanged: (filter) {
            if (filter == null) return;
            setState(() => _download = filter);
            _top();
          },
        ),
      IconButton(
        tooltip: '刷新发现',
        onPressed: _busy ? null : () => _load(refresh: true),
        icon: const Icon(Icons.refresh),
      ),
      if (_canBrowseDirectory)
        TextButton.icon(
          onPressed: _openPanda,
          icon: const Icon(Icons.travel_explore),
          label: const Text('熊猫书源'),
        ),
      if (_mode == _Mode.featured)
        IconButton(
          tooltip: '查看原榜单',
          onPressed: () => widget.onPage(_board.url(1)),
          icon: const Icon(Icons.open_in_new),
        ),
      PopupMenuButton<VoidCallback>(
        tooltip: '图书操作',
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          PopupMenuItem(value: widget.onShare, child: const Text('解析分享')),
          PopupMenuItem(value: widget.onLocal, child: const Text('导入本地文件')),
          PopupMenuItem(value: widget.onLists, child: const Text('我的书单')),
          if (widget.onManageGroups case final manage?)
            PopupMenuItem(value: manage, child: const Text('管理渠道分组')),
        ],
      ),
    ],
  );

  Widget _problems(bool hasBooks) {
    final messages = <Widget>[
      if (_error case final error?) Text(error),
      for (final result in _updates.values)
        if (result.problem case final problem?)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${result.source.name} · ${publicationSourceProblemLabel(problem)}',
              ),
              if (problem != PublicationProblem.blocked)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _retrySource(result.source.id),
                  child: const Text('重试'),
                ),
            ],
          ),
    ];
    if (messages.length > 1 || (hasBooks && _mode == _Mode.aggregate)) {
      return ExpansionTile(
        title: Text('${messages.length} 个来源提示'),
        childrenPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 6,
        ),
        expandedAlignment: Alignment.centerLeft,
        children: messages,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: messages.single,
    );
  }

  Widget _empty(bool featured, bool noChannels, bool filtered) {
    final current = _mode == _Mode.channel
        ? _channels
              .where((item) => item.source.id == _channel)
              .firstOrNull
              ?.source
        : null;
    final website = current?.websiteOnly == true || _query.isNotEmpty
        ? current?.website
        : null;
    final websiteQueryParameter = current?.websiteQueryParameter;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(switch ((featured, noChannels, filtered)) {
          _ when current?.websiteOnly == true => '此书源在原站提供搜索',
          (_, _, true) when _format == _FormatFilter.downloadable =>
            '暂未找到可本地阅读的版本',
          (_, _, true) => '没有符合筛选条件的图书',
          (true, _, _) => '暂无可显示的推荐图书',
          (_, true, _) => '所选范围没有可用的书源',
          _ when _mode == _Mode.aggregate && _query.isEmpty => '输入关键词搜索所选渠道',
          _ => '没有匹配的图书',
        }),
        if (!featured && noChannels)
          TextButton(onPressed: widget.onManage, child: const Text('管理书源')),
        if (_mode == _Mode.channel &&
            _channel != null &&
            current?.websiteOnly != true)
          TextButton(
            onPressed: () => _load(refresh: true),
            child: const Text('重试当前渠道'),
          ),
        if (website != null)
          TextButton(
            onPressed: () => widget.onPage(
              websiteQueryParameter != null && _query.isNotEmpty
                  ? website.replace(
                      queryParameters: {websiteQueryParameter: _query},
                    )
                  : website,
            ),
            child: const Text('在原站搜索'),
          ),
        if (!featured && _format == _FormatFilter.downloadable)
          TextButton(
            onPressed: () => setState(() => _format = _FormatFilter.all),
            child: const Text('显示全部搜索结果'),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _cancel();
    _input.dispose();
    _scroll.dispose();
    _showTop.dispose();
    super.dispose();
  }
}
