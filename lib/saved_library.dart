import 'dart:async';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'drama_actions.dart';
import 'follow_updates.dart';
import 'hongguo_series.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'television_search_field.dart';

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
    this.refreshToken = 0,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;
  final int refreshToken;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();
  late FollowUpdates _updates;
  late int _updatesEpoch;

  @override
  void initState() {
    super.initState();
    _updates = FollowUpdates(widget.repository, widget.store);
    _updatesEpoch = widget.store.profileEpoch;
    if (!widget.history) unawaited(_updates.refresh());
  }

  @override
  void didUpdateWidget(SavedLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reset =
        oldWidget.repository != widget.repository ||
        oldWidget.store != widget.store ||
        _updatesEpoch != widget.store.profileEpoch;
    if (reset) {
      _updates.dispose();
      _updates = FollowUpdates(widget.repository, widget.store);
      _updatesEpoch = widget.store.profileEpoch;
      _search.clear();
    }
    if (!widget.history &&
        (reset ||
            oldWidget.history ||
            oldWidget.refreshToken != widget.refreshToken)) {
      unawaited(_updates.refresh());
    }
  }

  void _open(Drama drama, {bool resume = false}) {
    _updates.cancel();
    if (resume) {
      widget.onContinue(drama);
    } else {
      widget.onOpen(drama);
    }
  }

  @override
  void dispose() {
    _updates.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('这会删除当前用户的观看进度，已加入追剧的内容会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) {
    final target = widget.history
        ? drama
        : widget.store.seriesWatch(drama)?.drama ?? drama;
    unawaited(
      showDramaActions(
        context,
        drama: target,
        store: widget.store,
        history: widget.history,
        onContinue: () => _open(target, resume: true),
        onDownload: widget.onDownload == null
            ? null
            : () => widget.onDownload!(target),
      ),
    );
  }

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final watched = widget.history
        ? widget.store.watched(drama.id)
        : widget.store.seriesWatch(drama);
    final target = watched?.drama ?? drama;
    final followed = widget.store.followedSeries(drama) != null;
    final hasNextSeason = !widget.history && widget.store.hasNextSeason(drama);
    final badge = hasNextSeason
        ? '已有下季'
        : followed
        ? '已追剧'
        : null;
    final season = watched == null ? null : hongguoSeriesInfo(watched.drama);
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: target,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _open(target, resume: !widget.history),
      onMore: () => _actions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _actions(drama),
      ),
      badge: badge,
      badgeRibbon: hasNextSeason,
      subtitle: watched == null
          ? SourceSite.byId(drama.source).name
          : '${season == null ? '' : '第 ${season.season} ${season.unit} · '}第 ${watched.episode} 集 · ${formatPosition(watched.position)}',
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final history = widget.history
          ? widget.store.history
          : const <WatchEntry>[];
      final all = widget.history
          ? history.map((entry) => entry.drama).toList()
          : widget.store.trackedSeries;
      final items = all.where((drama) {
        final target = widget.history
            ? drama
            : widget.store.seriesWatch(drama)?.drama ?? drama;
        if (!matchesDramaQuery(drama, _search.text) &&
            !matchesDramaQuery(target, _search.text)) {
          return false;
        }
        return true;
      }).toList();
      final itemIds = widget.history
          ? items.map((drama) => drama.id).toSet()
          : const <String>{};
      final resume = widget.history
          ? history
                .where(
                  (entry) =>
                      itemIds.contains(entry.drama.id) &&
                      (!entry.finished ||
                          entry.drama.episodes <= 0 ||
                          entry.episode < entry.drama.episodes),
                )
                .firstOrNull
          : items
                .map(widget.store.seriesWatch)
                .whereType<WatchEntry>()
                .where(
                  (entry) =>
                      !entry.finished ||
                      entry.drama.episodes <= 0 ||
                      entry.episode < entry.drama.episodes,
                )
                .firstOrNull;
      final header = [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.history ? '最近观看' : '我的追剧'} · ${all.length}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (widget.history && all.isNotEmpty)
                IconButton(
                  tooltip: '清空观看记录',
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TelevisionSearchField(
            key: ValueKey(
              widget.history ? 'history-search' : 'favorites-search',
            ),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.history ? '搜索观看记录' : '搜索追剧',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        if (!widget.history && all.isNotEmpty)
          ListenableBuilder(
            listenable: _updates,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _updates.checking
                          ? '正在检查下季 · ${_updates.checked}/${_updates.total}'
                          : _updates.failed > 0
                          ? '部分追剧暂未完成检查，可重试'
                          : '进入追剧时检查下季，点卡片继续最近观看',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('follow-check-updates'),
                    tooltip: '检查下季',
                    onPressed: _updates.checking
                        ? null
                        : () => _updates.refresh(force: true),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
          ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('continue-watching'),
                leading: const Icon(Icons.play_circle_outline),
                title: Text(
                  '继续观看 · ${resume.drama.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '第 ${resume.episode} 集 · ${formatPosition(resume.position)}',
                ),
                onTap: () => _open(resume.drama, resume: true),
              ),
            ),
          ),
      ];
      final empty = StatusPanel(
        title: all.isEmpty
            ? widget.history
                  ? '还没有观看记录'
                  : '还没有追剧'
            : '没有匹配的记录',
        message: all.isEmpty ? '去发现页，挑一部喜欢的短剧。' : '可以更换搜索词或筛选条件。',
        icon: widget.history
            ? Icons.history_rounded
            : Icons.bookmark_border_rounded,
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          if (AppLayout.isTelevision(context)) {
            final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
              1,
              8,
            );
            final tileWidth =
                (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .5,
                  ),
                  child: SingleChildScrollView(child: Column(children: header)),
                ),
                Expanded(
                  child: items.isEmpty
                      ? empty
                      : RemoteGrid(
                          key: ValueKey(
                            'saved-tv-${widget.history}-${_search.text}',
                          ),
                          itemKeys: items.map((item) => item.id).toList(),
                          columns: columns,
                          itemExtent:
                              DramaTile.extentFor(context, tileWidth - 14) + 14,
                          itemBuilder: (_, index, node, onFocus) => _tile(
                            items[index],
                            focusNode: node,
                            onFocus: onFocus,
                          ),
                        ),
                ),
              ],
            );
          }
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return CustomScrollView(
            key: PageStorageKey('saved-${widget.history}-${_search.text}'),
            slivers: [
              SliverToBoxAdapter(child: Column(children: header)),
              if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: empty)
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _tile(items[index]),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}
