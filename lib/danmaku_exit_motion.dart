import 'dart:math' as math;

const danmakuExitDuration = Duration(milliseconds: 600);
const maxDanmakuFlights = 24;

class DanmakuExitMotion {
  DanmakuExitMotion({
    required double startX,
    required double width,
    required double velocityPxPerSecond,
    Duration duration = danmakuExitDuration,
  }) : startX = startX.isFinite ? startX : 0,
       width = width.isFinite ? math.max(0, width) : 0,
       velocityPxPerSecond = velocityPxPerSecond.isFinite
           ? math.max(0, velocityPxPerSecond)
           : 0,
       duration = duration > Duration.zero
           ? duration
           : const Duration(microseconds: 1);

  final double startX;
  final double width;
  final double velocityPxPerSecond;
  final Duration duration;

  double positionAt(Duration elapsed) {
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    final progress = (elapsed.inMicroseconds / duration.inMicroseconds).clamp(
      0.0,
      1.0,
    );
    final extra = math.max(
      0.0,
      startX + width + 1 - velocityPxPerSecond * seconds,
    );
    return startX -
        velocityPxPerSecond * seconds * progress -
        extra * progress * progress * progress;
  }

  bool completedAt(Duration elapsed) =>
      elapsed >= duration || positionAt(elapsed) + width <= 0;
}
