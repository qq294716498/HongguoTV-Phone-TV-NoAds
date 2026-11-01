import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class SeriesSeasonStrip extends StatefulWidget {
  const SeriesSeasonStrip({
    super.key,
    required this.entries,
    required this.selectedId,
    required this.repository,
    required this.onSelected,
    this.autofocus = false,
  });

  final List<HongguoSeriesEntry> entries;
  final String selectedId;
  final AppRepository repository;
  final ValueChanged<Drama> onSelected;
  final bool autofocus;

  @override
  State<SeriesSeasonStrip> createState() => SeriesSeasonStripState();
}

class SeriesSeasonStripState extends State<SeriesSeasonStrip> {
  final _scroll = ScrollController();
  final _nodes = <String, FocusNode>{};
  String? _focused;
  bool _initialFocusPending = false;
  int _generation = 0;
  double _extent = 100;

  FocusNode _node(int index) => _nodes.putIfAbsent(
    widget.entries[index].drama.id,
    () => FocusNode(
      debugLabel: 'series-season-${widget.entries[index].drama.id}',
    ),
  );

  @override
  void initState() {
    super.initState();
    _initialFocusPending = widget.autofocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSelection(requestFocus: widget.autofocus);
    });
  }

  void focusSelection() => _showSelection(requestFocus: true);

  void _showSelection({required bool requestFocus}) {
    if (widget.entries.isEmpty) return;
    final focus = FocusManager.instance.primaryFocus;
    final available = focus == null || focus is FocusScopeNode;
    final restore = !requestFocus && available && _focused != null;
    final target = restore ? _focused : widget.selectedId;
    final index = widget.entries.indexWhere(
      (entry) => entry.drama.id == target,
    );
    _focusAt(
      index < 0 ? 0 : index,
      requestFocus:
          requestFocus || available && (_initialFocusPending || restore),
    );
  }

  void _focusAt(int index, {bool requestFocus = true}) {
    if (index < 0 || index >= widget.entries.length) return;
    final generation = ++_generation;
    final node = requestFocus ? _node(index) : null;
    final previousFocus = FocusManager.instance.primaryFocus;
    Future<void> scrolling = Future<void>.value();
    if (_scroll.hasClients) {
      final left = 12 + index * _extent;
      final right = left + _extent;
      final offset = _scroll.offset;
      final viewport = _scroll.position.viewportDimension;
      final target = left < offset
          ? left
          : right > offset + viewport
          ? right - viewport
          : offset;
      final clamped = target.clamp(0.0, _scroll.position.maxScrollExtent);
      if ((clamped - offset).abs() > 1) {
        scrolling = _scroll.animateTo(
          clamped,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
        );
      }
    }
    final requested = node?.context != null;
    if (requested) node!.requestFocus();
    unawaited(
      scrolling.then((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final focus = FocusManager.instance.primaryFocus;
          if (mounted &&
              !requested &&
              generation == _generation &&
              (focus == previousFocus ||
                  focus == null ||
                  focus is FocusScopeNode) &&
              node?.context != null) {
            node!.requestFocus();
          }
        });
        WidgetsBinding.instance.scheduleFrame();
      }),
    );
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final current = _focused;
    if (current == null || !(_nodes[current]?.hasFocus ?? false)) {
      return KeyEventResult.ignored;
    }
    final index = widget.entries.indexWhere(
      (entry) => entry.drama.id == current,
    );
    final offset = event.logicalKey == LogicalKeyboardKey.arrowRight
        ? 1
        : event.logicalKey == LogicalKeyboardKey.arrowLeft
        ? -1
        : 0;
    if (offset == 0 || index < 0) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _generation++;
      }
      return KeyEventResult.ignored;
    }
    final next = index + offset;
    if (next < 0 || next >= widget.entries.length) {
      return KeyEventResult.ignored;
    }
    _focusAt(next);
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(SeriesSeasonStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.entries.map((entry) => entry.drama.id).toSet();
    final removed = _nodes.keys.where((id) => !ids.contains(id)).toList();
    final restore = removed.any((id) => _nodes[id]!.hasFocus);
    for (final id in removed) {
      _nodes.remove(id)?.dispose();
    }
    if (_focused != null && !ids.contains(_focused)) {
      _focused = null;
      _generation++;
    }
    if (restore && widget.entries.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusSelection();
      });
    } else if (widget.selectedId != oldWidget.selectedId ||
        widget.entries.indexWhere(
              (entry) => entry.drama.id == widget.selectedId,
            ) !=
            oldWidget.entries.indexWhere(
              (entry) => entry.drama.id == oldWidget.selectedId,
            )) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSelection(requestFocus: false);
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    for (final node in _nodes.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final television = AppLayout.isTelevision(context);
      final scaler = MediaQuery.textScalerOf(context);
      final labelSize = television ? 17.0 : 15.0;
      final labelHeight = (scaler.scale(labelSize) * 1.3).ceilToDouble();
      final countHeight = (scaler.scale(13) * 1.3).ceilToDouble();
      final coverHeight = math.max(
        56.0,
        constraints.maxHeight - labelHeight - countHeight - 22,
      );
      final width = math.max(
        coverHeight * 2 / 3 + 16,
        scaler.scale(labelSize) * 5 + 16,
      );
      _extent = width + 8;
      final colors = Theme.of(context).colorScheme;
      return Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        child: ListView.builder(
          key: const ValueKey('all-season-cover-scroll'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          itemExtent: _extent,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: widget.entries.length,
          itemBuilder: (context, index) {
            final entry = widget.entries[index];
            final selected = entry.drama.id == widget.selectedId;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: entry.drama.title,
                child: RemoteTarget(
                  key: ValueKey('all-season-${entry.drama.id}'),
                  focusNode: _node(index),
                  onFocus: () {
                    _initialFocusPending = false;
                    _focused = entry.drama.id;
                  },
                  selected: selected,
                  label:
                      '${entry.drama.title}，${entry.label}，${entry.drama.episodes > 0 ? '共 ${entry.drama.episodes} 集' : '集数待更新'}${selected ? '，当前选择' : ''}',
                  radius: 12,
                  padding: const EdgeInsets.all(6),
                  borderWidth: television ? 3 : 2,
                  onPressed: () => widget.onSelected(entry.drama),
                  child: Column(
                    children: [
                      SizedBox(
                        height: coverHeight,
                        width: coverHeight * 2 / 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DramaCover(
                              key: ValueKey(
                                'all-season-cover-${entry.drama.id}',
                              ),
                              drama: entry.drama,
                              repository: widget.repository,
                              radius: 8,
                              showMetadata: false,
                            ),
                            if (selected)
                              Align(
                                alignment: Alignment.topRight,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.primary,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Icon(
                                    Icons.check_rounded,
                                    size: 16,
                                    color: colors.onPrimary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: labelHeight,
                        child: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: labelSize,
                            height: 1.3,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected ? colors.primary : colors.onSurface,
                          ),
                        ),
                      ),
                      SizedBox(
                        height: countHeight,
                        child: Text(
                          entry.drama.episodes > 0
                              ? '共 ${entry.drama.episodes} 集'
                              : '集数待更新',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
