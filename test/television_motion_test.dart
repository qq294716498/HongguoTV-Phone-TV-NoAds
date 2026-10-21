import 'dart:math' as math;

import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, updateDanmaku, flushDanmaku;

void main() {
  for (final configuration in [
    (size: const Size(960, 540), dpr: 1.0, fps: 60, aspect: 16 / 9),
    (size: const Size(1920, 1080), dpr: 1.0, fps: 60, aspect: 16 / 9),
    (size: const Size(3840, 2160), dpr: 2.0, fps: 120, aspect: 16 / 9),
    (size: const Size(960, 540), dpr: 1.0, fps: 30, aspect: 9 / 16),
  ]) {
    for (final reduced in [false, true]) {
      for (final speed in [.5, 1.0]) {
        testWidgets('TV motion $configuration reduced=$reduced speed=$speed', (
          tester,
        ) async {
          tester.view.physicalSize = configuration.size;
          tester.view.devicePixelRatio = configuration.dpr;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var now = DateTime(2026);
          final repository = DanmakuFixtureRepository();
          final controller = DanmakuController(repository, now: () => now)
            ..setPlan(danmakuPlan);
          updateDanmaku(controller, speed: 3);
          await flushDanmaku();
          controller.items = List.generate(
            500,
            (index) => DanmakuItem(
              id: 'batch-$index',
              text: index == 1 ? '合成长弹幕验证文字长度和批量数据不改变实际移动速度' : '合成 $index',
              timeMs: 0,
            ),
          );
          expect(controller.items, hasLength(500));
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: Scaffold(
                body: DanmakuOverlay(
                  controller: controller,
                  aspectRatio: configuration.aspect,
                  television: true,
                  speed: speed,
                ),
              ),
            ),
          );
          await tester.pump();
          double x(int index) => tester
              .widget<Transform>(
                find.byKey(ValueKey('danmaku-motion-batch-$index')),
              )
              .transform
              .storage[12];
          final starts = [x(0), x(1)];
          expect(
            find.byKey(const ValueKey('danmaku-item-batch-2')),
            findsNothing,
          );
          final frame = Duration(
            microseconds: (1000000 / configuration.fps).round(),
          );
          for (var i = 0; i < configuration.fps; i++) {
            now = now.add(frame);
            await tester.pump(frame);
            updateDanmaku(
              controller,
              position: now.difference(DateTime(2026)).inMilliseconds * 3,
              speed: 3,
            );
          }
          final width = math.min(
            configuration.size.width / configuration.dpr,
            configuration.size.height /
                configuration.dpr *
                configuration.aspect,
          );
          final expected =
              width /
              32 *
              speed *
              frame.inMicroseconds *
              configuration.fps /
              1000000;
          expect(starts[0] - x(0), closeTo(expected, .06));
          expect(starts[1] - x(1), closeTo(expected, .06));
          updateDanmaku(controller, position: 3000, speed: 3, playing: false);
          await tester.pump();
          final paused = x(0);
          await tester.pump(const Duration(seconds: 1));
          expect(x(0), closeTo(paused, .01));
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
