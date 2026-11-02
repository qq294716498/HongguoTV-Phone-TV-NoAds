import 'package:duanju_app/danmaku_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, flushDanmaku;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late DanmakuFixtureRepository repository;
  late DanmakuController controller;

  void update({
    int position = 0,
    int duration = 180000,
    double speed = 1,
    bool playing = true,
    bool buffering = false,
    bool foreground = true,
    bool available = true,
    bool discontinuity = false,
  }) => controller.update(
    position: Duration(milliseconds: position),
    duration: Duration(milliseconds: duration),
    speed: speed,
    playing: playing,
    buffering: buffering,
    foreground: foreground,
    available: available,
    discontinuity: discontinuity,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 2);
    repository = DanmakuFixtureRepository();
    controller = DanmakuController(repository, now: () => now)
      ..setPlan(danmakuPlan);
  });

  tearDown(() => controller.dispose());

  for (final speed in [1.0, 1.5]) {
    test(
      'duplicate samples do not rebuild an advancing ${speed}x timeline',
      () async {
        update(speed: speed);
        await flushDanmaku();
        var notifications = 0;
        controller.addListener(() => notifications++);
        final content = controller.contentRevision;
        final timeline = controller.timelineRevision;
        final motion = controller.motionRevision;
        for (var i = 1; i <= 10; i++) {
          now = now.add(const Duration(milliseconds: 100));
          final position = (i * 100 * speed).round();
          update(position: position, speed: speed);
          for (var duplicate = 0; duplicate < 5; duplicate++) {
            update(position: position, speed: speed);
          }
        }
        expect(notifications, 10);
        expect(controller.positionMs, (1000 * speed).round());
        expect(controller.contentRevision, content);
        expect(controller.timelineRevision, timeline);
        expect(controller.motionRevision, motion);
        expect(repository.danmakuCalls, hasLength(1));
      },
    );

    test(
      'identical positions still correct actual ${speed}x clock drift',
      () async {
        update(speed: speed);
        await flushDanmaku();
        final motion = controller.motionRevision;
        var notifications = 0;
        controller.addListener(() => notifications++);
        now = now.add(const Duration(seconds: 1));
        update(speed: speed);
        expect(controller.motionRevision, motion + 1);
        expect(notifications, 1);
        update(speed: speed);
        expect(notifications, 1);
      },
    );
  }

  test('duplicate paused updates still retry an expired failed page', () async {
    repository.failDanmaku = true;
    update(playing: false);
    await flushDanmaku();
    expect(repository.danmakuCalls, hasLength(1));
    expect(controller.canRetry, isTrue);
    update(playing: false);
    await flushDanmaku();
    expect(repository.danmakuCalls, hasLength(1));
    now = now.add(const Duration(seconds: 16));
    repository.failDanmaku = false;
    update(playing: false);
    await flushDanmaku();
    expect(repository.danmakuCalls, hasLength(2));
    expect(controller.items, isNotEmpty);
    expect(controller.canRetry, isFalse);
  });

  test(
    'buffering, playback and visibility changes notify without position changes',
    () async {
      update();
      await flushDanmaku();
      var notifications = 0;
      controller.addListener(() => notifications++);
      update(buffering: true);
      expect(notifications, 1);
      expect(controller.mobileMoving, isFalse);
      update(buffering: false, playing: false);
      expect(notifications, 2);
      expect(controller.mobileMoving, isFalse);
      update(playing: false, foreground: false);
      expect(notifications, 3);
      expect(controller.mobileVisible, isFalse);
      update(playing: false, foreground: true, available: false);
      expect(notifications, 4);
      expect(controller.mobileVisible, isFalse);
      update();
      expect(notifications, 5);
      expect(controller.mobileMoving, isTrue);
    },
  );

  test(
    'an explicit same-position discontinuity still resets the timeline',
    () async {
      update();
      await flushDanmaku();
      final timeline = controller.timelineRevision;
      final motion = controller.motionRevision;
      var notifications = 0;
      controller.addListener(() => notifications++);
      update(discontinuity: true);
      expect(controller.timelineRevision, timeline + 1);
      expect(controller.motionRevision, motion + 1);
      expect(notifications, 1);
    },
  );

  test(
    'ignored positions during seeking do not redraw or replace the seek timeline',
    () async {
      update();
      await flushDanmaku();
      controller.beginSeek();
      var notifications = 0;
      controller.addListener(() => notifications++);
      update(position: 50000);
      expect(notifications, 0);
      expect(controller.positionMs, 0);
      controller.endSeek(const Duration(seconds: 20));
      expect(controller.positionMs, 20000);
      expect(notifications, greaterThan(0));
      expect(controller.seeking, isFalse);
    },
  );
}
