import 'dart:convert';

import 'package:duanju_app/danmaku_exit_motion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'exit motion keeps the existing flight budget and a bounded deadline',
    () {
      expect(danmakuExitDuration, const Duration(milliseconds: 600));
      expect(maxDanmakuFlights, 24);
    },
  );

  for (final speed in [1.0, 1.5]) {
    test('exit preserves actual x and initial velocity at ${speed}x', () {
      final velocity = 42 * speed;
      final motion = DanmakuExitMotion(
        startX: 287.25,
        width: 103.5,
        velocityPxPerSecond: velocity,
      );
      const firstStep = Duration(microseconds: 100);
      final derivative =
          (motion.positionAt(Duration.zero) - motion.positionAt(firstStep)) /
          .0001;
      expect(motion.positionAt(Duration.zero), 287.25);
      expect(derivative, closeTo(velocity, .001));
      expect(motion.completedAt(Duration.zero), isFalse);
      expect(
        motion.positionAt(danmakuExitDuration) + motion.width,
        lessThan(0),
      );
      expect(motion.completedAt(danmakuExitDuration), isTrue);
      print(
        'DANMAKU_EXIT_MOTION=${jsonEncode({
          'speed': speed,
          'startX': motion.startX,
          'velocityPxPerSecond': velocity,
          'measuredInitialVelocity': derivative,
          'positions': {
            for (final ms in [0, 100, 300, 600]) '$ms': motion.positionAt(Duration(milliseconds: ms)),
          },
          'offscreenByMs': danmakuExitDuration.inMilliseconds,
        })}',
      );
    });

    test('exit accelerates left smoothly without reversing at ${speed}x', () {
      final motion = DanmakuExitMotion(
        startX: 320,
        width: 140,
        velocityPxPerSecond: 42 * speed,
      );
      var previousX = motion.positionAt(Duration.zero);
      var previousDistance = 0.0;
      for (var ms = 20; ms <= 600; ms += 20) {
        final x = motion.positionAt(Duration(milliseconds: ms));
        final distance = previousX - x;
        expect(x.isFinite, isTrue);
        expect(x, lessThan(previousX));
        expect(distance, greaterThanOrEqualTo(previousDistance));
        if (ms < 600)
          expect(motion.completedAt(Duration(milliseconds: ms)), isFalse);
        previousX = x;
        previousDistance = distance;
      }
      expect(previousX + motion.width, lessThan(0));
    });
  }

  test('a paused flight starts from rest and still leaves by the deadline', () {
    final motion = DanmakuExitMotion(
      startX: 190,
      width: 60,
      velocityPxPerSecond: 0,
    );
    final derivative =
        (motion.positionAt(Duration.zero) -
            motion.positionAt(const Duration(microseconds: 100))) /
        .0001;
    expect(derivative, closeTo(0, .001));
    expect(motion.positionAt(const Duration(milliseconds: 100)), lessThan(190));
    expect(motion.positionAt(danmakuExitDuration), closeTo(-61, .000001));
    expect(motion.completedAt(danmakuExitDuration), isTrue);
  });

  test('a nearby edge keeps natural velocity and completes before 600ms', () {
    final motion = DanmakuExitMotion(
      startX: -35,
      width: 40,
      velocityPxPerSecond: 60,
    );
    for (final ms in [0, 25, 50, 100, 200]) {
      expect(
        motion.positionAt(Duration(milliseconds: ms)),
        closeTo(-35 - 60 * ms / 1000, .000001),
      );
    }
    expect(motion.completedAt(const Duration(milliseconds: 50)), isFalse);
    expect(motion.completedAt(const Duration(milliseconds: 100)), isTrue);
    final first = motion.positionAt(const Duration(milliseconds: 25));
    final second = motion.positionAt(const Duration(milliseconds: 50));
    expect((first - second) / .025, closeTo(60, .000001));
  });

  test('partially clipped flights preserve their real location', () {
    final motion = DanmakuExitMotion(
      startX: -50,
      width: 80,
      velocityPxPerSecond: 40,
    );
    expect(motion.positionAt(Duration.zero), -50);
    expect(motion.completedAt(Duration.zero), isFalse);
    expect(motion.positionAt(danmakuExitDuration) + 80, lessThan(0));
  });

  test('negative time and time after completion cannot restart a flight', () {
    final motion = DanmakuExitMotion(
      startX: 260,
      width: 90,
      velocityPxPerSecond: 45,
    );
    expect(motion.positionAt(const Duration(seconds: -1)), 260);
    final finalX = motion.positionAt(danmakuExitDuration);
    expect(motion.positionAt(const Duration(seconds: 1)), finalX);
    expect(motion.positionAt(const Duration(hours: 1)), finalX);
    expect(motion.completedAt(const Duration(hours: 1)), isTrue);
  });

  test(
    'nonfinite positions, widths and velocities remain finite and bounded',
    () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final motion = DanmakuExitMotion(
          startX: value,
          width: value,
          velocityPxPerSecond: value,
        );
        for (final ms in [0, 100, 300, 600]) {
          expect(
            motion.positionAt(Duration(milliseconds: ms)).isFinite,
            isTrue,
          );
        }
        expect(motion.width, 0);
        expect(motion.velocityPxPerSecond, 0);
        expect(motion.completedAt(danmakuExitDuration), isTrue);
      }
    },
  );

  test('negative width or velocity cannot produce rightward movement', () {
    final motion = DanmakuExitMotion(
      startX: 20,
      width: -50,
      velocityPxPerSecond: -80,
    );
    expect(motion.width, 0);
    expect(motion.velocityPxPerSecond, 0);
    expect(motion.positionAt(const Duration(milliseconds: 100)), lessThan(20));
    expect(motion.positionAt(danmakuExitDuration), lessThan(0));
  });

  test('a nonpositive custom duration still has a finite completion point', () {
    for (final duration in [Duration.zero, const Duration(milliseconds: -5)]) {
      final motion = DanmakuExitMotion(
        startX: 10,
        width: 20,
        velocityPxPerSecond: 30,
        duration: duration,
      );
      expect(motion.duration, const Duration(microseconds: 1));
      expect(motion.positionAt(Duration.zero), 10);
      expect(motion.positionAt(motion.duration).isFinite, isTrue);
      expect(motion.positionAt(motion.duration) + motion.width, lessThan(0));
      expect(motion.completedAt(motion.duration), isTrue);
    }
  });
}
