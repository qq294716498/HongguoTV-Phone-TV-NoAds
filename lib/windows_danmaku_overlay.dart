import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'danmaku_controller.dart';
import 'danmaku_emoji_render.dart';
import 'danmaku_models.dart';

double windowsDanmakuFontSize(Size viewport, {double textScale = 1}) =>
    (18 *
            math.sqrt(viewport.width * viewport.height / (960 * 540)) *
            textScale.clamp(1, 1.15))
        .clamp(12, 28);

class WindowsDanmakuOverlay extends StatefulWidget {
  const WindowsDanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    required this.flightText,
    this.speed = 1,
    this.opacity = .62,
  });
  final DanmakuController controller;
  final double aspectRatio;
  final String Function(DanmakuItem) flightText;
  final double speed;
  final double opacity;
  @override
  State<WindowsDanmakuOverlay> createState() => _WindowsDanmakuOverlayState();
}

class _WindowsFlight {
  _WindowsFlight(this.item, this.text, this.lane, this.width, this.x);
  DanmakuItem item;
  String text;
  final int lane;
  double width;
  double x;
}

class _WindowsDanmakuOverlayState extends State<WindowsDanmakuOverlay>
    with SingleTickerProviderStateMixin {
  final _motion = ValueNotifier<int>(0);
  final _emoji = DanmakuEmojiCache();
  final _seen = <String>{};
  final _flights = <_WindowsFlight>[];
  late final Ticker _ticker;
  int _elapsed = 0;
  double _width = 0;
  Object? _timeline;
  Object? _metrics;
  Object? _emojiRevision;

  @override
  void initState() {
    super.initState();
    _emoji.addListener(_emojiReady);
    _ticker = createTicker((elapsed) {
      final delta = elapsed.inMicroseconds - _elapsed;
      _elapsed = elapsed.inMicroseconds;
      if (!widget.controller.moving) return;
      final speed = widget.speed.isFinite ? widget.speed.clamp(.5, 2) : 1;
      for (final flight in _flights) {
        flight.x -=
            delta / 1000000 * _width / 10 * speed * danmakuBaselineSpeed;
      }
      final expired = _flights.any((flight) => flight.x + flight.width < 0);
      if (expired)
        setState(
          () => _flights.removeWhere((flight) => flight.x + flight.width < 0),
        );
      _motion.value++;
    });
  }

  void _emojiReady() {
    if (mounted) setState(() {});
  }

  void _sync(double width, int rows, TextStyle style, TextScaler scaler) {
    final controller = widget.controller;
    final timeline = (
      controller,
      controller.contentRevision,
      controller.timelineRevision,
    );
    if (_timeline != timeline) {
      _timeline = timeline;
      _seen.clear();
      _flights.clear();
    }
    final metrics = (style.fontSize, scaler.scale(1), _emoji.imageCount);
    double measure(String text) =>
        DanmakuEmojiContent.parse(
          text,
        ).measure(style, scaler, cache: _emoji).ceilToDouble() +
        8;
    final items = {for (final item in controller.items) item.id: item};
    for (final flight in _flights) {
      final item = items[flight.item.id];
      if (item != null && item.repeatCount != flight.item.repeatCount) {
        flight.item = item;
        flight.text = widget.flightText(item);
        flight.width = measure(flight.text);
      } else if (_metrics != metrics) {
        flight.width = measure(flight.text);
      }
    }
    _metrics = metrics;
    _seen.retainAll({
      ...items.keys,
      ..._flights.map((flight) => flight.item.id),
    });
    if (controller.visible && !controller.seeking) {
      for (final item in controller.items) {
        if (item.timeMs > controller.positionMs ||
            item.timeMs < controller.positionMs - 1000 ||
            _seen.contains(item.id) ||
            _flights.length >= 24)
          continue;
        final lane = List.generate(rows, (index) => index)
            .where(
              (lane) => _flights
                  .where((flight) => flight.lane == lane)
                  .every((flight) => flight.x + flight.width + 24 <= width),
            )
            .firstOrNull;
        if (lane == null) continue;
        final text = widget.flightText(item);
        _seen.add(item.id);
        _flights.add(_WindowsFlight(item, text, lane, measure(text), width));
      }
    }
    final revision = (controller, controller.dataRevision);
    if (_emojiRevision != revision) {
      _emojiRevision = revision;
      _emoji.ensureLoaded(controller.items.map(widget.flightText));
    }
    _width = width;
    if (controller.moving) {
      if (!_ticker.isActive) {
        _elapsed = 0;
        _ticker.start();
      }
    } else {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                constraints.biggest.isEmpty)
              return const SizedBox.shrink();
            final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
                ? widget.aspectRatio
                : 16 / 9;
            final size = Size(
              math.min(constraints.maxWidth, constraints.maxHeight * aspect),
              math.min(constraints.maxHeight, constraints.maxWidth / aspect),
            );
            final font = windowsDanmakuFontSize(
              size,
              textScale: MediaQuery.textScalerOf(context).scale(1),
            );
            final style = TextStyle(
              fontSize: font,
              height: 1.2,
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(
                alpha: widget.opacity.isFinite
                    ? widget.opacity.clamp(.2, 1)
                    : .62,
              ),
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 1,
                  offset: Offset(0, .5),
                ),
              ],
            );
            const scaler = TextScaler.noScaling;
            final rows = ((size.height * .38 - 8) / (font * 1.6)).floor().clamp(
              0,
              3,
            );
            return Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: widget.controller,
                    builder: (context, _) {
                      _sync(size.width, rows, style, scaler);
                      if (!widget.controller.visible || rows == 0)
                        return const SizedBox.shrink();
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final flight in _flights)
                            Positioned(
                              key: ValueKey('danmaku-item-${flight.item.id}'),
                              left: 0,
                              top: 8 + flight.lane * font * 1.6,
                              width: flight.width,
                              height: font * 1.6,
                              child: AnimatedBuilder(
                                animation: _motion,
                                child: RepaintBoundary(
                                  child: DanmakuEmojiText(
                                    text: flight.text,
                                    style: style,
                                    scaler: scaler,
                                    cache: _emoji,
                                  ),
                                ),
                                builder: (context, child) =>
                                    Transform.translate(
                                      key: ValueKey(
                                        'danmaku-motion-${flight.item.id}',
                                      ),
                                      offset: Offset(flight.x, 0),
                                      child: child,
                                    ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _ticker.dispose();
    _emoji.dispose();
    _motion.dispose();
    super.dispose();
  }
}
