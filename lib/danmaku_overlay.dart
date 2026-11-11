import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'danmaku_controller.dart';
import 'portrait_video_frame.dart';
import 'danmaku_emoji_render.dart';
import 'danmaku_exit_motion.dart';
import 'danmaku_models.dart';
import 'danmaku_text.dart';
import 'windows_danmaku_overlay.dart';

String danmakuFlightText(DanmakuItem item) {
  final buffer = StringBuffer();
  var remaining = 100;
  var clipped = false;
  for (final part in danmakuExpressionParts(item.text)) {
    final count = (part.glyphs ?? part.original).characters.length;
    if (count <= remaining) {
      buffer.write(part.original);
      remaining -= count;
    } else {
      if (!part.expression)
        buffer.write(part.original.characters.take(remaining));
      clipped = true;
      break;
    }
  }
  final text = '$buffer${clipped ? '…' : ''}';
  return item.repeatCount > 1 ? '$text  ♥ ${item.repeatCount}' : text;
}

class DanmakuFlight {
  const DanmakuFlight(
    this.item,
    this.text,
    this.lane,
    this.width, {
    this.lifetimeMs = danmakuLifetimeMs,
  });
  final DanmakuItem item;
  final String text;
  final int lane;
  final double width;
  final int lifetimeMs;
}

List<DanmakuFlight> planDanmaku(
  List<DanmakuItem> items, {
  required double width,
  required int rows,
  required double Function(String) measure,
  int lifetimeMs = danmakuLifetimeMs,
}) {
  if (!width.isFinite || width <= 0 || rows < 1 || lifetimeMs <= 0) {
    return const [];
  }
  final lanes = List<DanmakuFlight?>.filled(rows.clamp(1, 5), null);
  final sorted = items.toList()..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final seen = <String>{};
  final flights = <DanmakuFlight>[];
  for (final item in sorted) {
    if (item.id.isEmpty ||
        item.text.trim().isEmpty ||
        item.timeMs < 0 ||
        !seen.add(item.id)) {
      continue;
    }
    if (flights.reversed
            .takeWhile(
              (flight) => item.timeMs - flight.item.timeMs < lifetimeMs,
            )
            .length >=
        24) {
      continue;
    }
    final text = danmakuFlightText(item);
    final size = measure(text).ceilToDouble() + 8;
    final lane = lanes.indexWhere((previous) {
      if (previous == null) return true;
      final gap = item.timeMs - previous.item.timeMs;
      if (gap >= lifetimeMs) return true;
      return (width + previous.width) * gap / lifetimeMs - previous.width >=
              24 &&
          width - (width + size) * (lifetimeMs - gap) / lifetimeMs >= 24;
    });
    if (lane < 0) continue;
    final flight = DanmakuFlight(item, text, lane, size);
    lanes[lane] = flight;
    flights.add(flight);
  }
  return flights;
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.television = false,
    this.mobile = false,
    this.speed,
    this.opacity,
    this.desktop = false,
    this.animationBehavior,
    this.currentVisible = true,
    this.topAlignedLandscapeVideo = false,
  });
  final DanmakuController controller;
  final double aspectRatio;
  final bool television;
  final bool mobile;
  final double? speed;
  final double? opacity;
  final bool desktop;
  final AnimationBehavior? animationBehavior;
  final bool currentVisible;
  final bool topAlignedLandscapeVideo;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _RetiringDanmakuFlight {
  _RetiringDanmakuFlight({
    required this.identity,
    required this.flight,
    required this.motion,
    required this.startedAt,
    required this.viewport,
    required this.top,
    required this.height,
    required this.content,
  });
  final int identity;
  final DanmakuFlight flight;
  final DanmakuExitMotion motion;
  final Duration startedAt;
  final Rect viewport;
  final double top;
  final double height;
  final Widget content;
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with TickerProviderStateMixin {
  Object? _layout;
  List<DanmakuFlight> _schedule = const [];
  int _realtimePositionMs = 0;
  double _realtimeBaseMs = 0;
  int _realtimeElapsedMs = 0;
  late final Ticker _realtimeTicker;
  final _realtimeSeen = <String>{};
  List<DanmakuFlight> _realtimeFlights = [];
  Object? _realtimeLayout;
  final _emojiCache = DanmakuEmojiCache();
  Object? _emojiWarmRevision;
  int _realtimeEmojiRevision = 0;
  int? _mobileTimelineRevision;
  Object? _realtimeItemsRevision;
  Map<String, DanmakuItem> _realtimeItems = {};
  final _motionKeys = <String, GlobalKey<_DanmakuMotionState>>{};
  final _retiring = <_RetiringDanmakuFlight>[];
  final _exitClock = ValueNotifier<Duration>(Duration.zero);
  final _exitStructure = ValueNotifier<int>(0);
  late final Ticker _exitTicker;
  Duration _exitElapsed = Duration.zero;
  Duration _exitOrigin = Duration.zero;
  late int _planRevision;
  late int _exitResetRevision;
  int? _endedPlanRevision;
  int _exitIdentity = 0;
  Rect _viewport = Rect.zero;
  List<double> _laneTops = const [];
  double _rowHeight = 0;

  bool get _mobile => widget.mobile && !widget.television;
  bool get _realtime => widget.television || _mobile;
  double get _realtimeSpeed {
    final speed = widget.speed ?? (_mobile ? 1.15 : 1.0);
    return (speed.isFinite ? speed.clamp(.5, 2.0) : (_mobile ? 1.15 : 1.0)) *
        danmakuBaselineSpeed;
  }

  @override
  void initState() {
    super.initState();
    _planRevision = widget.controller.planRevision;
    _exitResetRevision = widget.controller.exitResetRevision;
    widget.controller.addListener(_controllerChanged);
    _emojiCache.addListener(_emojiReady);
    _realtimeTicker = createTicker((elapsed) {
      final delta = elapsed.inMilliseconds - _realtimeElapsedMs;
      _realtimeElapsedMs = elapsed.inMilliseconds;
      _realtimeBaseMs += delta * _realtimeSpeed;
      _realtimePositionMs = _realtimeBaseMs.round();
    });
    _exitTicker = createTicker((_) {
      if (!widget.controller.exitsAllowed) {
        _clearRetiring();
        return;
      }
      _exitElapsed =
          SchedulerBinding.instance.currentSystemFrameTimeStamp - _exitOrigin;
      final previous = _retiring.length;
      _retiring.removeWhere(
        (flight) => flight.motion.completedAt(_exitElapsed - flight.startedAt),
      );
      _exitClock.value = _exitElapsed;
      if (_retiring.length != previous) _exitStructure.value++;
      if (_retiring.isEmpty) _exitTicker.stop();
    });
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      _clearRetiring();
      _motionKeys.clear();
      _planRevision = widget.controller.planRevision;
      _exitResetRevision = widget.controller.exitResetRevision;
      _endedPlanRevision = null;
      widget.controller.addListener(_controllerChanged);
    }
  }

  void _clearRetiring() {
    _exitTicker.stop();
    if (_retiring.isEmpty) return;
    _retiring.clear();
    _exitStructure.value++;
  }

  void _retireVisible() {
    if (_viewport.isEmpty || !widget.controller.exitsAllowed) return;
    if (_retiring.isEmpty) {
      _exitElapsed = Duration.zero;
      _exitOrigin = SchedulerBinding.instance.currentSystemFrameTimeStamp;
      _exitClock.value = Duration.zero;
    } else {
      _exitElapsed =
          SchedulerBinding.instance.currentSystemFrameTimeStamp - _exitOrigin;
    }
    final previous = _retiring.length;
    for (final key in _motionKeys.values) {
      if (_retiring.length >= maxDanmakuFlights) break;
      final state = key.currentState;
      if (state == null ||
          state.widget.flight.lane >= _laneTops.length ||
          state.x >= _viewport.width ||
          state.x + state.widget.flight.width <= 0) {
        continue;
      }
      final motion = state.widget;
      _retiring.add(
        _RetiringDanmakuFlight(
          identity: ++_exitIdentity,
          flight: motion.flight,
          motion: DanmakuExitMotion(
            startX: state.x,
            width: motion.flight.width,
            velocityPxPerSecond: state.velocity,
          ),
          startedAt: _exitElapsed,
          viewport: _viewport,
          top: _laneTops[motion.flight.lane],
          height: _rowHeight,
          content: RepaintBoundary(
            child: DanmakuEmojiText(
              text: motion.flight.text,
              style: motion.style,
              scaler: motion.scaler,
              cache: _emojiCache,
            ),
          ),
        ),
      );
    }
    _motionKeys.clear();
    if (_retiring.length == previous) return;
    _exitStructure.value++;
    if (!_exitTicker.isActive) {
      _exitTicker.start();
    }
  }

  void _controllerChanged() {
    final controller = widget.controller;
    if (!controller.exitsAllowed ||
        _exitResetRevision != controller.exitResetRevision) {
      _exitResetRevision = controller.exitResetRevision;
      _clearRetiring();
      _motionKeys.clear();
    }
    if (_planRevision != controller.planRevision) {
      _retireVisible();
      _planRevision = controller.planRevision;
      _endedPlanRevision = null;
      _realtimeLayout = null;
      _layout = null;
      _realtimeFlights.clear();
      _realtimeSeen.clear();
    } else if (controller.atEnd && _endedPlanRevision != _planRevision) {
      _retireVisible();
      _endedPlanRevision = _planRevision;
    }
  }

  Widget _retiringLayer() => AnimatedBuilder(
    animation: _exitStructure,
    builder: (context, _) => Stack(
      children: [
        for (final flight in _retiring)
          Positioned.fromRect(
            key: ValueKey('danmaku-exit-item-${flight.identity}'),
            rect: flight.viewport,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: flight.top,
                    width: flight.flight.width,
                    height: flight.height,
                    child: AnimatedBuilder(
                      animation: _exitClock,
                      child: flight.content,
                      builder: (context, child) => Transform.translate(
                        key: ValueKey(
                          'danmaku-exit-motion-${flight.identity}-${flight.flight.item.id}',
                        ),
                        offset: Offset(
                          flight.motion.positionAt(
                            _exitClock.value - flight.startedAt,
                          ),
                          0,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  void _emojiReady() {
    if (mounted) setState(() {});
  }

  void _updateRealtime(
    DanmakuController controller,
    double width,
    int rows,
    Object layout,
    double Function(String) measure,
  ) {
    if (_realtimeLayout != layout) {
      _realtimeLayout = layout;
      _realtimeTicker.stop();
      _realtimePositionMs = 0;
      _realtimeBaseMs = 0;
      _realtimeSeen.clear();
      _realtimeFlights.clear();
    }
    if (_mobile ? controller.mobileMoving : controller.moving) {
      if (!_realtimeTicker.isActive) {
        _realtimeElapsedMs = 0;
        _realtimeTicker.start();
      }
    } else {
      _realtimeTicker.stop();
    }
    final now = _realtimePositionMs;
    final pixelsPerSecond = width / (_mobile ? 10 : 32);
    _realtimeFlights.removeWhere(
      (flight) => now - flight.item.timeMs >= flight.lifetimeMs,
    );
    final revision = (controller, controller.dataRevision);
    if (_realtimeItemsRevision != revision) {
      _realtimeItemsRevision = revision;
      _realtimeItems = {for (final item in controller.items) item.id: item};
    }
    final currentItems = _realtimeItems;
    final emojiChanged = _realtimeEmojiRevision != _emojiCache.imageCount;
    _realtimeEmojiRevision = _emojiCache.imageCount;
    for (var index = 0; index < _realtimeFlights.length; index++) {
      final flight = _realtimeFlights[index];
      final current = currentItems[flight.item.id];
      if (current == null ||
          !emojiChanged && current.repeatCount == flight.item.repeatCount) {
        continue;
      }
      final text = danmakuFlightText(current);
      final size = measure(text).ceilToDouble() + 8;
      _realtimeFlights[index] = DanmakuFlight(
        DanmakuItem(
          id: current.id,
          text: current.text,
          timeMs: flight.item.timeMs,
          repeatCount: current.repeatCount,
        ),
        text,
        flight.lane,
        size,
        lifetimeMs: ((width + size) / pixelsPerSecond * 1000).ceil(),
      );
    }
    if (_mobile) {
      final activeIds = _realtimeFlights
          .map((flight) => flight.item.id)
          .toSet();
      if (_mobileTimelineRevision != controller.timelineRevision) {
        _mobileTimelineRevision = controller.timelineRevision;
        _realtimeSeen.retainAll(activeIds);
      }
      _realtimeSeen.retainAll({...currentItems.keys, ...activeIds});
      if (controller.seeking) return;
    }
    for (final item in controller.items) {
      if (item.timeMs > controller.positionMs ||
          item.timeMs < controller.positionMs - 1000 ||
          _realtimeSeen.contains(item.id))
        continue;
      if (_realtimeFlights.length + _retiring.length >= maxDanmakuFlights)
        break;
      _realtimeSeen.add(item.id);
      var lane = -1;
      for (var candidate = 0; candidate < rows; candidate++) {
        if (_realtimeFlights
            .where((flight) => flight.lane == candidate)
            .every(
              (flight) =>
                  (now - flight.item.timeMs) * pixelsPerSecond / 1000 -
                      flight.width >=
                  24,
            )) {
          lane = candidate;
          break;
        }
      }
      if (lane < 0) continue;
      final text = danmakuFlightText(item);
      final size = measure(text).ceilToDouble() + 8;
      _realtimeFlights.add(
        DanmakuFlight(
          DanmakuItem(
            id: item.id,
            text: item.text,
            timeMs: now,
            repeatCount: item.repeatCount,
          ),
          text,
          lane,
          size,
          lifetimeMs: ((width + size) / pixelsPerSecond * 1000).ceil(),
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _exitTicker.dispose();
    _exitClock.dispose();
    _exitStructure.dispose();
    _emojiCache.dispose();
    _realtimeTicker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.desktop && !widget.mobile && !widget.television
      ? WindowsDanmakuOverlay(
          controller: widget.controller,
          aspectRatio: widget.aspectRatio,
          flightText: danmakuFlightText,
          speed: widget.speed ?? 1,
          opacity: widget.opacity ?? .62,
          currentVisible: widget.currentVisible,
        )
      : _legacy(context);

  Widget _legacy(BuildContext context) => RepaintBoundary(
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                constraints.maxWidth <= 0 ||
                constraints.maxHeight <= 0) {
              return const SizedBox.shrink();
            }
            final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
                ? widget.aspectRatio
                : 16 / 9;
            final width = _mobile
                ? constraints.maxWidth
                : math.min(
                    constraints.maxWidth,
                    constraints.maxHeight * aspect,
                  );
            final height = _mobile
                ? constraints.maxHeight
                : math.min(
                    constraints.maxHeight,
                    constraints.maxWidth / aspect,
                  );
            final fontSize = _mobile
                ? 16.0
                : widget.television
                ? 14.0
                : width < 600
                ? 12.0
                : 14.0;
            final lifetimeMs = widget.television
                ? 32000
                : (danmakuLifetimeMs / danmakuBaselineSpeed).round();
            final topInset = _mobile
                ? (height > width
                      ? MediaQuery.paddingOf(context).top + 8.0
                      : 64.0)
                : widget.television
                ? 12.0
                : 8.0;
            final scaler = MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: 1.15);
            final rowHeight = scaler.scale(fontSize) * (_mobile ? 1.75 : 1.5);
            final portrait = _mobile && height > width;
            final videoRect = widget.topAlignedLandscapeVideo
                ? portraitLandscapeVideoRect(
                    constraints.biggest,
                    aspect,
                    verticalOffset: PortraitVideoPosition.of(context),
                    padding: MediaQuery.paddingOf(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )
                : null;
            final fitted = applyBoxFit(
              BoxFit.contain,
              Size(aspect, 1),
              constraints.biggest,
            ).destination;
            final picture =
                videoRect ??
                Rect.fromLTWH(
                  (width - fitted.width) / 2,
                  (height - fitted.height) / 2,
                  fitted.width,
                  fitted.height,
                );
            final portraitTops = portraitDanmakuLaneTops(
              picture,
              height,
              rowHeight,
              MediaQuery.paddingOf(context),
            );
            final rows = portrait
                ? portraitTops.length
                : ((height * (widget.television ? .18 : .38) - topInset) /
                          rowHeight)
                      .floor()
                      .clamp(0, _mobile ? 5 : (widget.television ? 2 : 3));
            final style = TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(
                alpha: widget.opacity?.isFinite == true
                    ? widget.opacity!.clamp(.2, 1.0)
                    : _mobile
                    ? .95
                    : (widget.television ? .55 : .62),
              ),
              height: 1.2,
              shadows: const [
                Shadow(
                  color: Color(0x66000000),
                  blurRadius: 1,
                  offset: Offset(0, .5),
                ),
              ],
            );
            _viewport = Rect.fromLTWH(
              (constraints.maxWidth - width) / 2,
              (constraints.maxHeight - height) / 2,
              width,
              height,
            );
            final laneTops = portrait
                ? portraitTops
                : [
                    for (var lane = 0; lane < rows; lane++)
                      topInset + lane * rowHeight,
                  ];
            _laneTops = laneTops;
            _rowHeight = rowHeight;
            final live = Positioned.fromRect(
              rect: _viewport,
              child: SizedBox(
                width: width,
                height: height,
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: widget.controller,
                    builder: (context, _) {
                      final controller = widget.controller;
                      final visible =
                          widget.currentVisible &&
                          (_mobile
                              ? controller.mobileVisible
                              : controller.visible);
                      if (!visible || rows == 0) {
                        _realtimeTicker.stop();
                        _realtimeLayout = null;
                        return const SizedBox.shrink();
                      }
                      double measure(String text) {
                        return DanmakuEmojiContent.parse(
                          text,
                        ).measure(style, scaler, cache: _emojiCache);
                      }

                      final emojiRevision = (
                        controller,
                        controller.dataRevision,
                      );
                      if (_emojiWarmRevision != emojiRevision) {
                        _emojiWarmRevision = emojiRevision;
                        _emojiCache.ensureLoaded(
                          controller.items.map(danmakuFlightText),
                        );
                      }

                      final layout = (
                        controller,
                        controller.dataRevision,
                        width,
                        rows,
                        lifetimeMs,
                        fontSize,
                        scaler,
                        _emojiCache.imageCount,
                      );
                      if (_realtime) {
                        _updateRealtime(controller, width, rows, (
                          controller,
                          _mobile,
                          _mobile
                              ? controller.contentRevision
                              : controller.timelineRevision,
                          width,
                          rows,
                          fontSize,
                          scaler,
                        ), measure);
                      } else {
                        _realtimeTicker.stop();
                        _realtimeLayout = null;
                      }
                      if (!_realtime && _layout != layout) {
                        _layout = layout;
                        _schedule = planDanmaku(
                          controller.items,
                          width: width,
                          rows: rows,
                          lifetimeMs: lifetimeMs,
                          measure: measure,
                        );
                      }
                      final flights = _realtime ? _realtimeFlights : _schedule;
                      final position = _realtime
                          ? _realtimePositionMs
                          : controller.positionMs;
                      final visibleFlights = flights
                          .where(
                            (flight) =>
                                position >= flight.item.timeMs &&
                                position <
                                    flight.item.timeMs +
                                        (_realtime
                                            ? flight.lifetimeMs
                                            : lifetimeMs),
                          )
                          .take(maxDanmakuFlights - _retiring.length)
                          .toList();
                      final activeIds = visibleFlights
                          .map((flight) => flight.item.id)
                          .toSet();
                      _motionKeys.removeWhere(
                        (id, _) => !activeIds.contains(id),
                      );
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final flight in visibleFlights)
                            Positioned(
                              key: ValueKey('danmaku-item-${flight.item.id}'),
                              left: 0,
                              top: laneTops[flight.lane],
                              width: flight.width,
                              height: rowHeight,
                              child: _DanmakuMotion(
                                key: _motionKeys.putIfAbsent(
                                  flight.item.id,
                                  () => GlobalKey<_DanmakuMotionState>(),
                                ),
                                animationBehavior:
                                    widget.animationBehavior ??
                                    (widget.television
                                        ? AnimationBehavior.preserve
                                        : AnimationBehavior.normal),
                                flight: flight,
                                lifetimeMs: _realtime
                                    ? flight.lifetimeMs
                                    : lifetimeMs,
                                width: width,
                                positionMs: position,
                                moving: _mobile
                                    ? controller.mobileMoving
                                    : controller.moving,
                                rate: _realtime
                                    ? _realtimeSpeed
                                    : controller.rate,
                                revision: _mobile
                                    ? (
                                        controller.motionRevision,
                                        _realtimeLayout,
                                      )
                                    : widget.television
                                    ? _realtimeLayout!
                                    : controller.motionRevision,
                                style: style,
                                scaler: scaler,
                                emojiCache: _emojiCache,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
            return Stack(
              fit: StackFit.expand,
              children: [live, _retiringLayer()],
            );
          },
        ),
      ),
    ),
  );
}

class _DanmakuMotion extends StatefulWidget {
  const _DanmakuMotion({
    super.key,
    required this.animationBehavior,
    required this.flight,
    required this.lifetimeMs,
    required this.width,
    required this.positionMs,
    required this.moving,
    required this.rate,
    required this.revision,
    required this.style,
    required this.scaler,
    required this.emojiCache,
  });
  final DanmakuFlight flight;
  final int lifetimeMs;
  final double width;
  final int positionMs;
  final bool moving;
  final double rate;
  final Object revision;
  final TextStyle style;
  final TextScaler scaler;
  final DanmakuEmojiCache emojiCache;
  final AnimationBehavior animationBehavior;

  @override
  State<_DanmakuMotion> createState() => _DanmakuMotionState();
}

class _DanmakuMotionState extends State<_DanmakuMotion>
    with TickerProviderStateMixin {
  late AnimationController _motion = AnimationController(
    vsync: this,
    animationBehavior: widget.animationBehavior,
  );

  double get x =>
      widget.width - (widget.width + widget.flight.width) * _motion.value;
  double get velocity =>
      (widget.width + widget.flight.width) * _motion.velocity;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DanmakuMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationBehavior != widget.animationBehavior) {
      _motion.dispose();
      _motion = AnimationController(
        vsync: this,
        animationBehavior: widget.animationBehavior,
      );
      _sync();
      return;
    }
    if (oldWidget.moving != widget.moving ||
        oldWidget.rate != widget.rate ||
        oldWidget.lifetimeMs != widget.lifetimeMs ||
        oldWidget.revision != widget.revision ||
        oldWidget.width != widget.width ||
        oldWidget.flight.width != widget.flight.width ||
        oldWidget.flight.item.timeMs != widget.flight.item.timeMs) {
      final retainPosition =
          oldWidget.moving == widget.moving &&
          oldWidget.rate == widget.rate &&
          oldWidget.revision == widget.revision &&
          oldWidget.width == widget.width &&
          oldWidget.flight.item.timeMs == widget.flight.item.timeMs;
      final x =
          oldWidget.width -
          (oldWidget.width + oldWidget.flight.width) * _motion.value;
      _sync(
        progress: retainPosition
            ? ((widget.width - x) / (widget.width + widget.flight.width)).clamp(
                0.0,
                1.0,
              )
            : null,
      );
    }
  }

  void _sync({double? progress}) {
    _motion.stop();
    final elapsed = (widget.positionMs - widget.flight.item.timeMs).clamp(
      0,
      widget.lifetimeMs,
    );
    _motion.value = progress ?? elapsed / widget.lifetimeMs;
    final remaining = widget.lifetimeMs * (1 - _motion.value);
    if (widget.moving && remaining > 0) {
      _motion.animateTo(
        1,
        duration: Duration(
          microseconds: (remaining * 1000 / widget.rate).round().clamp(
            1,
            86400000000,
          ),
        ),
        curve: Curves.linear,
      );
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _motion,
    child: RepaintBoundary(
      child: DanmakuEmojiText(
        text: widget.flight.text,
        style: widget.style,
        scaler: widget.scaler,
        cache: widget.emojiCache,
      ),
    ),
    builder: (context, child) => Transform.translate(
      key: ValueKey('danmaku-motion-${widget.flight.item.id}'),
      offset: Offset(
        widget.width - (widget.width + widget.flight.width) * _motion.value,
        0,
      ),
      child: child,
    ),
  );
}
