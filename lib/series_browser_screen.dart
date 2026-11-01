import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'episode_browser.dart';
import 'local_store.dart';
import 'models.dart';
import 'series_catalog.dart';
import 'hongguo_series.dart';
import 'search_input.dart';
import 'series_season_strip.dart';
import 'television_navigation.dart';
import 'widgets.dart';

class SeriesEpisodeSelection {
  const SeriesEpisodeSelection(this.detail, this.index, {this.position = 0});
  final DramaDetail detail;
  final int index;
  final double position;
}

class SeriesBrowserScreen extends StatefulWidget {
  const SeriesBrowserScreen({
    super.key,
    required this.anchor,
    required this.repository,
    required this.store,
    this.initialDetail,
    this.currentEpisode,
  });
  final Drama anchor;
  final AppRepository repository;
  final LocalStore store;
  final DramaDetail? initialDetail;
  final int? currentEpisode;

  @override
  State<SeriesBrowserScreen> createState() => _SeriesBrowserScreenState();
}

class _SeriesBrowserScreenState extends State<SeriesBrowserScreen> {
  late final int _epoch;
  late final SeriesCatalog _catalog;
  late Drama _selected;
  DramaDetail? _detail;
  String? _detailError;
  bool _loadingDetail = false;
  int _detailSequence = 0;
  bool _choosing = false;
  final _search = TextEditingController();
  final _seasonStrip = GlobalKey<SeriesSeasonStripState>();
  Timer? _searchDelay;
  String _filter = '';

  bool get _allowed =>
      mounted &&
      widget.store.profileEpoch == _epoch &&
      !widget.store.locked &&
      widget.anchor.source == SourceSite.hongguo.id &&
      widget.store.allowsSource(widget.anchor.source);

  @override
  void initState() {
    super.initState();
    _epoch = widget.store.profileEpoch;
    _selected = widget.anchor;
    final initial = widget.initialDetail;
    _detail =
        initial?.drama.id == widget.anchor.id &&
            initial?.drama.source == widget.anchor.source
        ? initial
        : null;
    _catalog = SeriesCatalog(
      anchor: widget.anchor,
      repository: widget.repository,
      knownDramas: widget.store.seriesDramasFor(widget.anchor),
      allowed: () => _allowed,
    )..addListener(_catalogChanged);
    widget.store.addListener(_storeChanged);
    unawaited(_loadCatalog());
    if (_detail == null) unawaited(_selectSeason(_selected));
  }

  void _catalogChanged() {
    if (mounted) setState(() {});
  }

  void _storeChanged() {
    if (!mounted) return;
    if (!_allowed) {
      _catalog.cancel();
      _detailSequence++;
    }
    setState(() {});
  }

  Future<void> _loadCatalog({bool refresh = false}) async {
    await _catalog.load(refresh: refresh);
    if (!_allowed) return;
    try {
      await widget.store.refreshDramas(
        _catalog.entries.map((entry) => entry.drama),
      );
    } catch (_) {}
  }

  Future<void> _selectSeason(Drama drama) async {
    if (!_allowed) return;
    final sequence = ++_detailSequence;
    setState(() {
      _selected = drama;
      _detail = null;
      _detailError = null;
      _loadingDetail = true;
    });
    try {
      final initial = widget.initialDetail;
      final detail = initial?.drama.id == drama.id
          ? initial!
          : await widget.repository
                .detail(drama)
                .timeout(const Duration(seconds: 25));
      if (!mounted || !_allowed || sequence != _detailSequence) return;
      if (detail.drama.id != drama.id ||
          detail.drama.source != widget.anchor.source) {
        throw AppFailure('季信息不一致，请刷新重试');
      }
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
    } catch (_) {
      if (_allowed && sequence == _detailSequence) {
        setState(() {
          _detailError = '这一季的集数暂时无法加载';
          _loadingDetail = false;
        });
      }
    }
  }

  Future<void> _chooseEpisode(int index, {bool resume = false}) async {
    final detail = _detail;
    if (!_allowed ||
        _choosing ||
        detail == null ||
        index < 0 ||
        index >= detail.episodes.length) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    _choosing = true;
    final sequence = _detailSequence;
    try {
      if (detail.episodes[index].vip) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('这是一集 VIP 内容'),
            content: const Text('站源可能只提供试看或限制播放。'),
            actions: [
              TextButton(
                autofocus: AppLayout.isTelevision(context),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('尝试播放'),
              ),
            ],
          ),
        );
        if (accepted != true) return;
      }
      if (!mounted || !_allowed || sequence != _detailSequence) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      final watch = widget.store.watched(detail.drama.id);
      final position =
          resume &&
              watch?.episode == detail.episodes[index].number &&
              !watch!.finished
          ? watch.position
          : 0.0;
      Navigator.pop(
        context,
        SeriesEpisodeSelection(detail, index, position: position),
      );
    } finally {
      _choosing = false;
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _catalog.removeListener(_catalogChanged);
    _catalog.dispose();
    _searchDelay?.cancel();
    _search.dispose();
    _detailSequence++;
    super.dispose();
  }

  void _searchChanged(String value) {
    _searchDelay?.cancel();
    if (!_search.value.composing.isCollapsed) return;
    final next = value.trim().toLowerCase();
    if (next == _filter) return;
    if (next.isEmpty) {
      setState(() => _filter = '');
    } else {
      _searchDelay = Timer(const Duration(milliseconds: 180), () {
        if (_allowed &&
            _search.value.composing.isCollapsed &&
            _search.text.trim().toLowerCase() == next) {
          setState(() => _filter = next);
        }
      });
    }
  }

  void _submitFilter(String value) {
    _searchDelay?.cancel();
    if (!_allowed) return;
    setState(() => _filter = value.trim().toLowerCase());
    if (AppLayout.isTelevision(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _seasonStrip.currentState?.focusSelection();
      });
    }
  }

  bool _matches(HongguoSeriesEntry entry) {
    if (_filter.isEmpty) return true;
    final compact = _filter.replaceAll(RegExp(r'\s+'), '');
    final number = RegExp(
      r'^(?:第)?([0-9零〇一二两兩三四五六七八九十百]+)([季部])?$',
    ).firstMatch(compact);
    if (number != null) {
      final unit = number[2] ?? entry.unit;
      final parsed = hongguoSeriesInfo(
        Drama(
          id: entry.drama.id,
          source: entry.drama.source,
          title: '本系列 第${number[1]}$unit',
        ),
      );
      return parsed?.season == entry.season && parsed?.unit == entry.unit;
    }
    final query = hongguoSeriesInfo(
      Drama(id: entry.drama.id, source: entry.drama.source, title: _filter),
    );
    if (query != null) {
      final info = hongguoSeriesInfo(entry.drama, unit: entry.unit);
      return query.key == info?.key &&
          query.season == entry.season &&
          query.unit == entry.unit;
    }
    return entry.drama.title.toLowerCase().contains(_filter) ||
        entry.label.replaceAll(' ', '').contains(compact);
  }

  void _back() {
    if (TelevisionNavigation.dismissInput(context)) return;
    Navigator.of(context).maybePop();
  }

  Widget _refresh() => IconButton(
    key: const ValueKey('all-seasons-refresh'),
    tooltip: '刷新全季',
    onPressed: !_allowed || _catalog.loading
        ? null
        : () => _loadCatalog(refresh: true),
    icon: const Icon(Icons.refresh_rounded),
  );

  Widget _seasonList({required bool narrowHeader}) {
    final entries = _catalog.entries;
    final visible = entries.where(_matches).toList();
    final television = AppLayout.isTelevision(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelSize = television ? 17.0 : 15.0;
    final stripHeight =
        96 +
        (scaler.scale(labelSize) * 1.3).ceilToDouble() +
        (scaler.scale(13) * 1.3).ceilToDouble() +
        22;
    final selected = entries
        .where((entry) => entry.drama.id == _selected.id)
        .firstOrNull;
    final hidden = visible.every((entry) => entry.drama.id != _selected.id);
    return Column(
      key: const ValueKey('all-seasons-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _catalog.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _filter.isEmpty
                    ? '${entries.length} 季'
                    : '${visible.length}/${entries.length} 季',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (narrowHeader) _refresh(),
            ],
          ),
        ),
        if (hidden && selected != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '当前选集：${selected.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (visible.isEmpty)
          SizedBox(
            height: stripHeight,
            child: const Center(child: Text('本系列中未找到匹配的季')),
          )
        else
          SizedBox(
            height: stripHeight,
            child: SeriesSeasonStrip(
              key: _seasonStrip,
              entries: visible,
              selectedId: _selected.id,
              repository: widget.repository,
              autofocus: television,
              onSelected: (drama) {
                if (_selected.id != drama.id || _detailError != null) {
                  unawaited(_selectSeason(drama));
                }
              },
            ),
          ),
        if (_catalog.loading)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_catalog.error.isNotEmpty || _catalog.hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _catalog.error.isNotEmpty
                        ? _catalog.error
                        : _catalog.loading
                        ? '正在查找更多季'
                        : '还有搜索结果，继续查找可补全各季',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  key: const ValueKey('all-seasons-load-more'),
                  onPressed: _catalog.loading
                      ? null
                      : () => _loadCatalog(refresh: !_catalog.hasMore),
                  child: Text(_catalog.error.isNotEmpty ? '重试' : '继续查找'),
                ),
              ],
            ),
          ),
        if (!_catalog.loading &&
            !_catalog.hasMore &&
            _catalog.error.isEmpty &&
            entries.length == 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text(
              '暂未找到其他季，可以刷新后重试',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _episodes() {
    if (_loadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = _detail;
    if (_detailError != null || detail == null || detail.episodes.isEmpty) {
      return StatusPanel(
        title: _detailError ?? '这一季暂时没有可播放的集数',
        message: '可以重新加载这一季，或选择其他季。',
        onRetry: () => _selectSeason(_selected),
      );
    }
    final watch = widget.store.watched(detail.drama.id);
    final current = detail.drama.id == widget.anchor.id
        ? widget.currentEpisode ?? watch?.episode
        : watch?.episode;
    final resumeIndex = detail.episodes.indexWhere(
      (episode) => episode.number == watch?.episode,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            detail.drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (resumeIndex >= 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              key: const ValueKey('all-seasons-resume'),
              onPressed: () => _chooseEpisode(resumeIndex, resume: true),
              icon: const Icon(Icons.history_rounded),
              label: Text('继续本机第 ${watch!.episode} 集'),
            ),
          ),
        Expanded(
          child: EpisodeBrowser(
            key: ValueKey('all-season-episodes-${detail.drama.id}'),
            keyPrefix: 'all-season-episode',
            denseDesktop: true,
            episodes: detail.episodes,
            currentNumber: current,
            onSelected: (index) => _chooseEpisode(index),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final scaler = MediaQuery.textScalerOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final narrow = width < 600;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _back,
        const SingleActivator(LogicalKeyboardKey.goBack): _back,
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          leadingWidth: 48,
          toolbarHeight: (scaler.scale(20) + 32).clamp(56.0, 72.0),
          title: Semantics(
            label: '查看全季',
            child: SearchInput(
              key: const ValueKey('all-seasons-search'),
              controller: _search,
              hint: '搜索本系列标题或季号',
              onChanged: _searchChanged,
              onSearch: _submitFilter,
            ),
          ),
          actions: [if (!narrow) _refresh()],
        ),
        body: !_allowed
            ? const StatusPanel(title: '当前用户无权访问', message: '请返回后重新选择。')
            : SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final availableHeight = constraints.maxHeight + keyboard;
                    final split =
                        constraints.maxWidth >= 700 &&
                        (availableHeight < 400 ||
                            availableHeight < 520 && scaler.scale(17) > 22);
                    final content = split
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: (constraints.maxWidth * .35).clamp(
                                  250.0,
                                  380.0,
                                ),
                                child: SingleChildScrollView(
                                  child: _seasonList(narrowHeader: narrow),
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(child: _episodes()),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _seasonList(narrowHeader: narrow),
                              const Divider(height: 1),
                              Expanded(child: _episodes()),
                            ],
                          );
                    final minimum = 384 + scaler.scale(17) * 4;
                    final height =
                        keyboard > 0 && constraints.maxHeight < minimum
                        ? minimum
                        : constraints.maxHeight;
                    return SingleChildScrollView(
                      primary: false,
                      child: SizedBox(height: height, child: content),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
