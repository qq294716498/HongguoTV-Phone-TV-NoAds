import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'remote_widgets.dart';
import 'catalog_filters.dart';
import 'core_bridge.dart';
import 'detail_screen.dart';
import 'local_store.dart';
import 'drama_actions.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'widgets.dart';

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.initialGroup,
    this.initialBoard,
    this.embedded = false,
  });
  final AppRepository repository;
  final LocalStore store;
  final String initialGroup;
  final String? initialBoard;
  final bool embedded;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scroll = ScrollController();
  List<RankingBoard> _boards = [];
  RankingBoard? _board;
  List<RankingItem> _items = [];
  bool _loading = true;
  bool _grid = true;
  bool _more = false;
  bool _hasMore = false;
  bool _failedMore = false;
  int _page = 1;
  int _generation = 0;
  String? _error;
  String _updated = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _initialize();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_hasMore || _loading || _more || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.2).clamp(260.0, 720.0);
    if (position.extentAfter <= threshold) {
      _load(more: true);
    }
  }

  void _metadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final boards = (await widget.repository.rankingBoards())
          .where((board) => widget.store.allowsSource(board.source))
          .toList();
      if (!mounted || generation != _generation) return;
      setState(() {
        _boards = boards;
        _board =
            boards
                .where((board) => board.id == widget.initialBoard)
                .firstOrNull ??
            boards
                .where((board) => board.groupId == widget.initialGroup)
                .firstOrNull ??
            boards.firstOrNull;
        _loading = false;
      });
      if (_board != null) await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    final board = _board;
    if (board == null || more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = false;
    });
    try {
      final result = await widget.repository.rankings(
        board.id,
        page: more ? _page + 1 : 1,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final rows = <String, RankingItem>{
          if (more)
            for (final item in _items) item.drama.id: item,
          for (final item in result.items) item.drama.id: item,
        };
        _items = rows.values.toList()..sort((a, b) => a.rank.compareTo(b.rank));
        _page = result.page;
        _hasMore = result.hasMore;
        _updated = result.updatedText;
        _error = result.warning.isEmpty ? null : result.warning;
        _loading = false;
        _more = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString();
          _failedMore = more;
          _loading = false;
          _more = false;
        });
      }
    }
  }

  void _select(RankingBoard board) {
    if (_board?.id == board.id) return;
    setState(() {
      _board = board;
      _items = [];
      _updated = '';
      _page = 1;
      _hasMore = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final groups = SourceGroup.fromSources(
      _boards.map((board) => SourceSite.byId(board.source)).toSet(),
    );
    final boards = _boards
        .where((board) => board.groupId == _board?.groupId)
        .toList();
    final items = _items
        .map(
          (item) => RankingItem(
            item.rank,
            widget.repository.catalogUpdates.current(item.drama),
            metric: item.metric,
          ),
        )
        .where(
          (item) =>
              widget.store.allowsSource(item.drama.source) &&
              !(item.drama.source == 'huangdou' &&
                  widget.store.hideVip &&
                  item.drama.vip),
        )
        .toList();
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: television && groups.length > 1
                  ? RemoteButton(
                      key: const ValueKey('ranking-source-switch'),
                      label:
                          '${_board == null ? '短剧' : SourceSite.byId(_board!.source).groupName}榜单',
                      icon: groups.length > 1
                          ? Icons.expand_more_rounded
                          : null,
                      onPressed: groups.length > 1
                          ? () async {
                              final group = await showRemoteChoice<SourceGroup>(
                                context: context,
                                title: '切换榜单站源',
                                values: groups,
                                selected: groups.firstWhere(
                                  (group) => group.id == _board?.groupId,
                                  orElse: () => groups.first,
                                ),
                                label: (group) => group.name,
                              );
                              if (group != null && mounted) {
                                _select(
                                  _boards.firstWhere(
                                    (board) => board.groupId == group.id,
                                  ),
                                );
                              }
                            }
                          : null,
                    )
                  : PopupMenuButton<SourceGroup>(
                      tooltip: '切换榜单站源',
                      enabled: groups.length > 1,
                      onSelected: (group) => _select(
                        _boards.firstWhere(
                          (board) => board.groupId == group.id,
                        ),
                      ),
                      itemBuilder: (_) => [
                        for (final group in groups)
                          PopupMenuItem(value: group, child: Text(group.name)),
                      ],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _board == null
                                ? '榜单'
                                : '${SourceSite.byId(_board!.source).groupName}榜单',
                          ),
                          if (groups.length > 1)
                            const Icon(Icons.expand_more_rounded),
                        ],
                      ),
                    ),
              actions: [
                if (!television)
                  IconButton(
                    tooltip: _grid ? '列表视图' : '海报视图',
                    onPressed: () => setState(() => _grid = !_grid),
                    icon: Icon(
                      _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                    ),
                  ),
                RefreshAction(
                  loading: _loading || _more,
                  tooltip: '更新榜单',
                  onPressed: _board == null
                      ? _initialize
                      : () => _load(force: true),
                ),
              ],
            ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (boards.isNotEmpty && !widget.embedded)
              CatalogFilters(
                key: ValueKey('ranking-boards-${_board!.groupId}'),
                categories: [
                  for (final board in boards)
                    CatalogCategory(board.id, board.name),
                ],
                category: _board!.id,
                onCategory: (id) =>
                    _select(boards.firstWhere((board) => board.id == id)),
                onRetry: () => _load(force: true),
              ),
            if (widget.embedded)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          _board?.description ?? '',
                          _updated,
                        ].where((text) => text.isNotEmpty).join(' '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (!television)
                      IconButton(
                        tooltip: _grid ? '列表视图' : '海报视图',
                        onPressed: () => setState(() => _grid = !_grid),
                        icon: Icon(
                          _grid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                        ),
                      ),
                    RefreshAction(
                      loading: _loading || _more,
                      tooltip: '更新榜单',
                      onPressed: () => _load(force: true),
                    ),
                  ],
                ),
              ),
            if (_board != null && !widget.embedded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    [
                      _board!.description,
                      if (_updated.isNotEmpty) _updated,
                    ].join(' '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            if (_loading && items.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            if (_error != null && items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _loading || _more
                          ? null
                          : () => _load(more: _failedMore, force: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading && items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_board?.source == 'hongguo') ...[
                            const SizedBox(height: 16),
                            const Text('正在获取榜单，数据未完整返回时会自动重试'),
                          ],
                        ],
                      ),
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: _error == null ? '暂无榜单内容' : '榜单暂时无法加载',
                      message: _error ?? '当前站源暂无可显示的榜单。',
                      onRetry: _board == null
                          ? _initialize
                          : () => _load(force: true),
                    )
                  : television
                  ? RemoteGrid(
                      key: ValueKey('ranking-${_board!.id}'),
                      controller: _scroll,
                      itemKeys: [
                        for (final item in items)
                          '${item.rank}-${item.drama.id}',
                      ],
                      columns: 1,
                      itemExtent:
                          (MediaQuery.textScalerOf(context).scale(17) * 2.4 +
                                  MediaQuery.textScalerOf(context).scale(13) *
                                      1.4 +
                                  24)
                              .clamp(88.0, 160.0),
                      spacing: 8,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      autofocus: true,
                      footer: Center(
                        child: _more
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(),
                              )
                            : _hasMore
                            ? RemoteButton(
                                label: '加载更多',
                                onPressed: () => _load(more: true),
                              )
                            : const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('已显示全部榜单'),
                              ),
                      ),
                      itemBuilder: (context, index, node, onFocus) =>
                          _rankingTile(
                            items[index],
                            television: true,
                            node: node,
                            onFocus: onFocus,
                          ),
                    )
                  : _grid
                  ? LayoutBuilder(
                      builder: (context, constraints) => RefreshIndicator(
                        onRefresh: () => _load(force: true),
                        child: CustomScrollView(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                              sliver: SliverGrid(
                                gridDelegate: dramaGridDelegate(
                                  context,
                                  constraints.maxWidth - 40,
                                ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final item = items[index];
                                  return DramaTile(
                                    key: ValueKey(
                                      'rank-${item.rank}-${item.drama.id}',
                                    ),
                                    drama: item.drama,
                                    repository: widget.repository,
                                    actions: DramaActionButton(
                                      drama: item.drama,
                                      onPressed: () => showDramaActions(
                                        context,
                                        drama: item.drama,
                                        repository: widget.repository,
                                        store: widget.store,
                                      ),
                                    ),
                                    rank: item.rank,
                                    subtitle: item.metric.isEmpty
                                        ? item.drama.category
                                        : item.metric,
                                    onTap: () => _openDrama(item),
                                  );
                                }, childCount: items.length),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: Center(
                                child: _more
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? TextButton(
                                        onPressed: () => _load(more: true),
                                        child: const Text('加载更多'),
                                      )
                                    : const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text('已显示全部榜单'),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(force: true),
                      child: ListView.builder(
                        key: ValueKey('ranking-${_board!.id}'),
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount: items.length + 1,
                        itemBuilder: (context, index) {
                          if (index == items.length) {
                            return Center(
                              child: _more
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: CircularProgressIndicator(),
                                    )
                                  : _hasMore
                                  ? OutlinedButton(
                                      onPressed: () => _load(more: true),
                                      child: const Text('加载更多'),
                                    )
                                  : const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: Text('已显示全部榜单'),
                                    ),
                            );
                          }
                          final item = items[index];
                          return _rankingTile(item);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDrama(RankingItem item) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => DetailScreen(
        drama: item.drama,
        repository: widget.repository,
        store: widget.store,
      ),
    ),
  );

  Widget _rankingTile(
    RankingItem item, {
    bool television = false,
    FocusNode? node,
    VoidCallback? onFocus,
  }) {
    void open() => _openDrama(item);
    final colors = Theme.of(context).colorScheme;
    final content = Padding(
      padding: EdgeInsets.all(television ? 4 : 12),
      child: Row(
        children: [
          SizedBox(
            width: television ? 30 : 36,
            child: Text(
              '${item.rank}',
              style: TextStyle(
                fontSize: television ? 20 : 24,
                fontWeight: FontWeight.w800,
                color: item.rank <= 3
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: television ? 46 : 72,
            height: television ? 68 : 108,
            child: DramaCover(
              drama: item.drama,
              repository: widget.repository,
              radius: 8,
            ),
          ),
          SizedBox(width: television ? 12 : 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: television
                      ? const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        )
                      : Theme.of(context).textTheme.titleMedium,
                ),
                if (television)
                  Row(
                    children: [
                      if (item.drama.category.isNotEmpty)
                        Flexible(
                          child: Text(
                            item.drama.category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (item.drama.category.isNotEmpty &&
                          item.metric.isNotEmpty)
                        const SizedBox(width: 12),
                      if (item.metric.isNotEmpty)
                        Flexible(
                          child: Text(
                            item.metric,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                            ),
                          ),
                        ),
                    ],
                  )
                else ...[
                  if (item.drama.category.isNotEmpty)
                    Text(
                      item.drama.category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (item.metric.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        item.metric,
                        style: TextStyle(color: colors.primary),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
    final key = ValueKey('rank-${item.rank}-${item.drama.id}');
    if (television) {
      return Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: RemoteTarget(
          key: key,
          focusNode: node,
          onFocus: onFocus,
          onPressed: open,
          radius: 12,
          child: content,
        ),
      );
    }
    return Card(
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(12),
        onTap: open,
        child: content,
      ),
    );
  }
}
