import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class EpisodeDragSelection extends StatefulWidget {
  const EpisodeDragSelection({
    super.key,
    required this.controller,
    required this.columns,
    required this.itemExtent,
    required this.spacing,
    required this.padding,
    required this.numbers,
    required this.selected,
    required this.onChanged,
    required this.child,
    this.onLimit,
    this.limit = 500,
  });

  final ScrollController controller;
  final int columns;
  final double itemExtent;
  final double spacing;
  final EdgeInsets padding;
  final List<int> numbers;
  final Set<int> selected;
  final ValueChanged<Set<int>>? onChanged;
  final VoidCallback? onLimit;
  final int limit;
  final Widget child;

  @override
  State<EpisodeDragSelection> createState() => _EpisodeDragSelectionState();
}

class _EpisodeDragSelectionState extends State<EpisodeDragSelection> {
  final _viewport = GlobalKey();
  Timer? _ticker;
  Offset? _down, _pointer;
  int? _anchor, _end;
  Set<int> _before = {};
  bool _selecting = false, _warned = false;
  String? _gesture;

  RenderBox? get _box =>
      _viewport.currentContext?.findRenderObject() as RenderBox?;

  int? _indexAt(Offset position, {bool clamp = false}) {
    final box = _box;
    if (box == null || widget.numbers.isEmpty) return null;
    final point = box.globalToLocal(position);
    final width = box.size.width - widget.padding.horizontal;
    final tileWidth =
        (width - widget.spacing * (widget.columns - 1)) / widget.columns;
    final x = point.dx - widget.padding.left;
    final y =
        point.dy -
        widget.padding.top +
        (widget.controller.hasClients ? widget.controller.offset : 0);
    if (!clamp &&
        (point.dy < 0 ||
            point.dy >= box.size.height ||
            x < 0 ||
            x >= width ||
            y < 0)) {
      return null;
    }
    var column = (x / (tileWidth + widget.spacing)).floor();
    final row = (y / (widget.itemExtent + widget.spacing)).floor();
    if (!clamp &&
        (x % (tileWidth + widget.spacing) >= tileWidth ||
            y % (widget.itemExtent + widget.spacing) >= widget.itemExtent)) {
      return null;
    }
    column = column.clamp(0, widget.columns - 1);
    if (Directionality.of(context) == TextDirection.rtl) {
      column = widget.columns - 1 - column;
    }
    final index = row * widget.columns + column;
    if (!clamp && (index < 0 || index >= widget.numbers.length)) return null;
    return index.clamp(0, widget.numbers.length - 1);
  }

  void _begin(Offset position) {
    if (widget.onChanged == null) return;
    _anchor = _indexAt(position);
    if (_anchor == null) return;
    _before = Set.of(widget.selected);
    _selecting = !_before.contains(widget.numbers[_anchor!]);
    _warned = false;
    _end = null;
    _move(position);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _scroll(),
    );
  }

  void _move(Offset position) {
    if (_anchor == null || widget.onChanged == null) return;
    _pointer = position;
    final end = _indexAt(position, clamp: true);
    if (end == null || end == _end) return;
    _end = end;
    final next = Set<int>.of(_before);
    final step = end >= _anchor! ? 1 : -1;
    for (var index = _anchor!; ; index += step) {
      final number = widget.numbers[index];
      if (_selecting) {
        if (next.length < widget.limit || next.contains(number)) {
          next.add(number);
        } else if (!_warned) {
          _warned = true;
          widget.onLimit?.call();
        }
      } else {
        next.remove(number);
      }
      if (index == end) break;
    }
    widget.onChanged!(next);
  }

  void _scroll() {
    final box = _box;
    final pointer = _pointer;
    if (_anchor == null ||
        box == null ||
        pointer == null ||
        !widget.controller.hasClients) {
      return;
    }
    final local = box.globalToLocal(pointer);
    final edge = min(48.0, box.size.height / 4);
    final distance = local.dy < edge
        ? local.dy - edge
        : local.dy > box.size.height - edge
        ? local.dy - (box.size.height - edge)
        : 0.0;
    if (distance == 0) return;
    final position = widget.controller.position;
    final next = (position.pixels + (distance / edge).clamp(-1.0, 1.0) * 12)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == position.pixels) return;
    widget.controller.jumpTo(next);
    _move(pointer);
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    _anchor = null;
    _end = null;
    _down = null;
    _pointer = null;
    _gesture = null;
  }

  @override
  void didUpdateWidget(EpisodeDragSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null ||
        widget.columns != oldWidget.columns ||
        widget.itemExtent != oldWidget.itemExtent ||
        widget.numbers.length != oldWidget.numbers.length ||
        !listEquals(widget.numbers, oldWidget.numbers)) {
      _stop();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: _viewport,
    behavior: HitTestBehavior.translucent,
    onHorizontalDragDown: widget.onChanged == null
        ? null
        : (details) => _down = details.globalPosition,
    onHorizontalDragStart: widget.onChanged == null
        ? null
        : (details) {
            _gesture = 'horizontal';
            _begin(_down ?? details.globalPosition);
            _move(details.globalPosition);
          },
    onHorizontalDragUpdate: widget.onChanged == null
        ? null
        : (details) => _move(details.globalPosition),
    onHorizontalDragEnd: widget.onChanged == null ? null : (_) => _stop(),
    onHorizontalDragCancel: widget.onChanged == null
        ? null
        : () {
            if (_gesture == 'horizontal') _stop();
          },
    onLongPressStart: widget.onChanged == null
        ? null
        : (details) {
            _gesture = 'long';
            _begin(details.globalPosition);
          },
    onLongPressMoveUpdate: widget.onChanged == null
        ? null
        : (details) => _move(details.globalPosition),
    onLongPressEnd: widget.onChanged == null ? null : (_) => _stop(),
    onLongPressCancel: widget.onChanged == null
        ? null
        : () {
            if (_gesture == 'long') _stop();
          },
    child: widget.child,
  );
}
