import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'danmaku_controller.dart';
import 'danmaku_emoji_render.dart';
import 'danmaku_exit_motion.dart';
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
    this.currentVisible = true,
  });
  final DanmakuController controller;
  final double aspectRatio;
  final String Function(DanmakuItem) flightText;
  final double speed;
  final double opacity;
  final bool currentVisible;
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

class _WindowsExit {
  _WindowsExit({
    required this.serial,
    required this.text,
    required this.width,
    required this.top,
    required this.height,
    required this.viewport,
    required this.style,
    required this.scaler,
    required this.motion,
    required this.startedAt,
    required this.child,
  }) : x = motion.startX;
  final int serial;
  final String text;
  final double width;
  final double top;
  final double height;
  final Rect viewport;
  final TextStyle style;
  final TextScaler scaler;
  final DanmakuExitMotion motion;
  final Duration startedAt;
  final Widget child;
  double x;
}

class _WindowsDanmakuOverlayState extends State<WindowsDanmakuOverlay>
    with SingleTickerProviderStateMixin {
  final _motion = ValueNotifier<int>(0);
  final _emoji = DanmakuEmojiCache();
  final _seen = <String>{};
  final _flights = <_WindowsFlight>[];
  final _exits = <_WindowsExit>[];
  late final Ticker _ticker;
  int _elapsed = 0;
  Object? _timeline;
  Object? _metrics;
  Object? _emojiRevision;
  DanmakuController? _owner;
  int? _planRevision;
  int? _exitResetRevision;
  int _exitSerial = 0;
  double _velocity = 0;
  Rect _viewport = Rect.zero;
  TextStyle _style = const TextStyle();
  TextScaler _scaler = TextScaler.noScaling;
  double _rowHeight = 0;

  @override
  void initState() {
    super.initState();
    _emoji.addListener(_emojiReady);
    widget.controller.addListener(_controllerChanged);
    _ticker = createTicker((elapsed) {
      final delta = elapsed.inMicroseconds - _elapsed;
      _elapsed = elapsed.inMicroseconds;
      final controller = widget.controller;
      if (!controller.exitsAllowed) {
        if (_exits.isNotEmpty) setState(_exits.clear);
        _ticker.stop();
        return;
      }
      if (controller.moving) {
        for (final flight in _flights) {
          flight.x -= delta / 1000000 * _velocity;
        }
      }
      final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
      for (final flight in _exits) {
        flight.x = flight.motion.positionAt(frame - flight.startedAt);
      }
      final expired =
          _flights.any((flight) => flight.x + flight.width < 0) ||
          _exits.any(
            (flight) => flight.motion.completedAt(frame - flight.startedAt),
          );
      if (expired) {
        setState(() {
          _flights.removeWhere((flight) => flight.x + flight.width < 0);
          _exits.removeWhere(
            (flight) => flight.motion.completedAt(frame - flight.startedAt),
          );
        });
      }
      _motion.value++;
      if (!controller.moving && _exits.isEmpty) _ticker.stop();
    });
  }

  void _emojiReady() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant WindowsDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _owner = null;
      _syncLifecycle();
    }
  }

  void _controllerChanged() {
    _syncLifecycle();
  }

  void _retire() {
    if (_viewport.isEmpty) return;
    for (final flight in _flights) {
      if (flight.x >= _viewport.width || flight.x + flight.width <= 0) continue;
      _exits.add(
        _WindowsExit(
          serial: ++_exitSerial,
          text: flight.text,
          width: flight.width,
          top: 8 + flight.lane * _rowHeight,
          height: _rowHeight,
          viewport: _viewport,
          style: _style,
          scaler: _scaler,
          motion: DanmakuExitMotion(
            startX: flight.x,
            width: flight.width,
            velocityPxPerSecond: _velocity / timeDilation,
          ),
          startedAt: SchedulerBinding.instance.currentSystemFrameTimeStamp,
          child: RepaintBoundary(
            child: DanmakuEmojiText(
              text: flight.text,
              style: _style,
              scaler: _scaler,
              cache: _emoji,
            ),
          ),
        ),
      );
    }
    _flights.clear();
    if (_exits.isNotEmpty && !_ticker.isActive) {
      _elapsed = 0;
      _ticker.start();
    }
  }

  void _syncLifecycle() {
    final controller = widget.controller;
    if (_owner != controller) {
      _owner = controller;
      _planRevision = controller.planRevision;
      _exitResetRevision = controller.exitResetRevision;
      _timeline = null;
      _flights.clear();
      _exits.clear();
    }
    if (_exitResetRevision != controller.exitResetRevision) {
      _exitResetRevision = controller.exitResetRevision;
      _planRevision = controller.planRevision;
      _timeline = null;
      _flights.clear();
      _exits.clear();
      _seen.clear();
    }
    if (!controller.exitsAllowed) _exits.clear();
    if (_planRevision != controller.planRevision) {
      if (controller.exitsAllowed) _retire();
      _planRevision = controller.planRevision;
      _timeline = null;
      _seen.clear();
      _flights.clear();
    }
    final timeline = (
      controller,
      controller.contentRevision,
      controller.timelineRevision,
    );
    if (_timeline != timeline) {
      _timeline = timeline;
      _seen.clear();
      _flights.clear();
    } else if (controller.exitsAllowed && controller.atEnd) {
      _retire();
    }
  }

  void _sync(Rect viewport, int rows, TextStyle style, TextScaler scaler) {
    _syncLifecycle();
    final controller = widget.controller;
    final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _exits.removeWhere(
      (flight) => flight.motion.completedAt(frame - flight.startedAt),
    );
    final width = viewport.width;
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
    if (widget.currentVisible && controller.visible && !controller.seeking) {
      for (final item in controller.items) {
        if (item.timeMs > controller.positionMs ||
            item.timeMs < controller.positionMs - 1000 ||
            _seen.contains(item.id) ||
            _flights.length + _exits.length >= maxDanmakuFlights)
          continue;
        final lane = List.generate(rows, (index) => index)
            .where(
              (lane) =>
                  _flights
                      .where((flight) => flight.lane == lane)
                      .every(
                        (flight) => flight.x + flight.width + 24 <= width,
                      ) &&
                  _exits
                      .where((flight) {
                        final top =
                            viewport.top + 8 + lane * style.fontSize! * 1.6;
                        return flight.viewport.top + flight.top <
                                top + style.fontSize! * 1.6 &&
                            flight.viewport.top + flight.top + flight.height >
                                top;
                      })
                      .every(
                        (flight) =>
                            flight.viewport.left +
                                flight.x +
                                flight.width +
                                24 <=
                            viewport.right,
                      ),
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
    _viewport = viewport;
    _style = style;
    _scaler = scaler;
    _rowHeight = style.fontSize! * 1.6;
    final speed = widget.speed.isFinite ? widget.speed.clamp(.5, 2) : 1;
    _velocity = controller.moving
        ? width / 10 * speed * danmakuBaselineSpeed
        : 0;
    if (controller.moving || _exits.isNotEmpty) {
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
            final viewport = Rect.fromLTWH(
              (constraints.maxWidth - size.width) / 2,
              (constraints.maxHeight - size.height) / 2,
              size.width,
              size.height,
            );
            return AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                _sync(viewport, rows, style, scaler);
                final groups = <Rect, List<_WindowsExit>>{};
                for (final flight in _exits) {
                  (groups[flight.viewport] ??= []).add(flight);
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.currentVisible &&
                        widget.controller.visible &&
                        rows > 0)
                      Positioned.fromRect(
                        rect: viewport,
                        child: ClipRect(
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final flight in _flights)
                                Positioned(
                                  key: ValueKey(
                                    'danmaku-item-${flight.item.id}',
                                  ),
                                  left: 0,
                                  top: 8 + flight.lane * font * 1.6,
                                  width: flight.width,
                                  height: font * 1.6,
                                  child: _movingText(
                                    key: ValueKey(
                                      'danmaku-motion-${flight.item.id}',
                                    ),
                                    text: flight.text,
                                    style: style,
                                    scaler: scaler,
                                    position: () => flight.x,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    for (final group in groups.entries)
                      Positioned.fromRect(
                        key: ValueKey(group.key),
                        rect: group.key,
                        child: ClipRect(
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final flight in group.value)
                                Positioned(
                                  key: ValueKey(
                                    'windows-danmaku-exit-${flight.serial}',
                                  ),
                                  left: 0,
                                  top: flight.top,
                                  width: flight.width,
                                  height: flight.height,
                                  child: _movingText(
                                    key: ValueKey(
                                      'windows-danmaku-exit-motion-${flight.serial}',
                                    ),
                                    text: flight.text,
                                    style: flight.style,
                                    scaler: flight.scaler,
                                    position: () => flight.x,
                                    child: flight.child,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    ),
  );

  Widget _movingText({
    required Key key,
    required String text,
    required TextStyle style,
    required TextScaler scaler,
    required double Function() position,
    Widget? child,
  }) => AnimatedBuilder(
    animation: _motion,
    child:
        child ??
        RepaintBoundary(
          child: DanmakuEmojiText(
            text: text,
            style: style,
            scaler: scaler,
            cache: _emoji,
          ),
        ),
    builder: (context, child) => Transform.translate(
      key: key,
      offset: Offset(position(), 0),
      child: child,
    ),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _ticker.dispose();
    _emoji.dispose();
    _motion.dispose();
    super.dispose();
  }
}
