import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, updateDanmaku, flushDanmaku;

void main() {
  late DateTime now;
  late DanmakuController controller;

  setUp(() {
    now = DateTime(2026);
    final repository = DanmakuFixtureRepository()
      ..response = (request) => DanmakuPage(
        episodeId: request.plan.danmakuId,
        startMs: request.startMs,
        nextMs: request.startMs + 30000,
        items: [
          for (var lane = 0; lane < 5; lane++)
            DanmakuItem(
              id: '${request.plan.danmakuId}-${request.startMs}-$lane',
              text: lane == 1 ? '合成的长句弹幕[偷笑]也保持相同滚动速度' : '合成弹幕 $lane',
              timeMs: request.startMs,
            ),
          DanmakuItem(
            id: '${request.plan.danmakuId}-skipped',
            text: '跳过的弹幕不补刷',
            timeMs: request.startMs + 5000,
          ),
        ],
      );
    controller = DanmakuController(repository, now: () => now)
      ..setPlan(danmakuPlan);
    updateDanmaku(controller);
  });

  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(420, 880),
    double? speed,
    double? opacity,
    bool television = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await flushDanmaku();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: DanmakuOverlay(
            controller: controller,
            aspectRatio: 16 / 9,
            mobile: !television,
            television: television,
            speed: speed,
            opacity: opacity,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double x(WidgetTester tester, [String id = '1001-0-0']) => tester
      .widget<Transform>(find.byKey(ValueKey('danmaku-motion-$id')))
      .transform
      .storage[12];

  Future<void> advance(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }

  for (final television in [false, true]) {
    testWidgets(
      'opacity changes text and emoji without resetting flight on TV=$television',
      (tester) async {
        await mount(tester, television: television);
        await advance(tester, const Duration(seconds: 1));
        final before = x(tester);
        await mount(tester, television: television, opacity: .35);
        expect(x(tester), closeTo(before, .1));
        final text = tester.widget<Text>(find.text('合成弹幕 0'));
        expect(text.style!.color!.a, closeTo(.35, .01));
        await advance(tester, const Duration(seconds: 1));
        expect(x(tester), lessThan(before));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final television in [false, true]) {
    testWidgets(
      'live speed changes preserve positions and pauses on TV=$television',
      (tester) async {
        await mount(tester, television: television);
        await advance(tester, const Duration(seconds: 1));
        final before = x(tester);
        final pixels = television ? 420 / 32 : 42.0;
        await mount(tester, speed: 2, television: television);
        expect(x(tester), closeTo(before, .15));
        await advance(tester, const Duration(seconds: 1));
        expect(before - x(tester), closeTo(pixels * 2, .15));
        updateDanmaku(controller, position: 1000, playing: false);
        await tester.pump();
        final paused = x(tester);
        await mount(tester, speed: .5, television: television);
        expect(x(tester), closeTo(paused, .15));
        await advance(tester, const Duration(seconds: 2));
        expect(x(tester), closeTo(paused, .15));
        updateDanmaku(controller, position: 1000, speed: 3);
        await tester.pump();
        await advance(tester, const Duration(seconds: 1));
        expect(paused - x(tester), closeTo(pixels * .5, .15));
        expect(
          find.byKey(const ValueKey('danmaku-item-1001-0-0')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'changing speed during seek keeps flights and does not replay skipped items',
    (tester) async {
      await mount(tester);
      await advance(tester, const Duration(seconds: 1));
      controller.beginSeek();
      await tester.pump();
      final before = x(tester);
      await mount(tester, speed: 1.5);
      expect(x(tester), closeTo(before, .15));
      await advance(tester, const Duration(seconds: 1));
      expect(before - x(tester), closeTo(63, .15));
      expect(x(tester, '1001-0-1'), closeTo(x(tester), .15));
      controller.endSeek(const Duration(seconds: 30));
      await tester.pump();
      expect(before - x(tester), closeTo(63, .15));
      expect(find.text('跳过的弹幕不补刷'), findsNothing);
      await mount(tester, speed: .5);
      expect(before - x(tester), closeTo(63, .15));
      expect(
        find.byKey(const ValueKey('danmaku-item-1001-0-0')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile uses four top lanes above a letterboxed landscape video',
    (tester) async {
      await mount(tester);
      for (var lane = 0; lane < 4; lane++) {
        final rect = tester.getRect(
          find.byKey(ValueKey('danmaku-item-1001-0-$lane')),
        );
        expect(rect.top, 64 + lane * 28);
        expect(rect.bottom, lessThan((880 - 420 / (16 / 9)) / 2));
      }
      expect(find.byKey(const ValueKey('danmaku-item-1001-0-4')), findsNothing);
      final text = tester.widget<Text>(find.text('合成弹幕 0'));
      expect(text.style!.fontSize, 16);
      expect(text.style!.color!.a, closeTo(.95, .01));
      expect(x(tester), 420);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile long and short flights stay at real-time speed during 2x and seek',
    (tester) async {
      await mount(tester);
      final start = x(tester);
      await advance(tester, const Duration(seconds: 2));
      expect(start - x(tester), closeTo(96.6, .1));
      expect(x(tester, '1001-0-1'), closeTo(x(tester), .1));
      updateDanmaku(controller, position: 2000, speed: 2);
      await tester.pump();
      final beforeDouble = x(tester);
      await advance(tester, const Duration(seconds: 1));
      updateDanmaku(controller, position: 4000, speed: 2);
      await tester.pump();
      expect(beforeDouble - x(tester), closeTo(48.3, .1));
      final beforeSeek = x(tester);
      controller.beginSeek();
      await tester.pump();
      expect(x(tester), closeTo(beforeSeek, .1));
      await advance(tester, const Duration(milliseconds: 500));
      expect(beforeSeek - x(tester), closeTo(24.15, .1));
      controller.endSeek(const Duration(seconds: 30));
      await tester.pump();
      expect(beforeSeek - x(tester), closeTo(24.15, .1));
      expect(find.text('跳过的弹幕不补刷'), findsNothing);
      controller.beginSeek();
      controller.endSeek(Duration.zero);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('danmaku-item-1001-0-0')),
        findsOneWidget,
      );
      expect(beforeSeek - x(tester), closeTo(24.15, .1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile freezes on pause and buffering and clears on background, disable and episode',
    (tester) async {
      await mount(tester);
      await advance(tester, const Duration(seconds: 1));
      updateDanmaku(controller, position: 1000, playing: false);
      await tester.pump();
      final paused = x(tester);
      await advance(tester, const Duration(seconds: 2));
      expect(x(tester), closeTo(paused, .1));
      updateDanmaku(controller, position: 1000, buffering: true);
      await tester.pump();
      await advance(tester, const Duration(seconds: 2));
      expect(x(tester), closeTo(paused, .1));
      updateDanmaku(controller, position: 1000);
      await tester.pump();
      await advance(tester, const Duration(seconds: 1));
      expect(paused - x(tester), closeTo(48.3, .1));
      updateDanmaku(controller, position: 2000, foreground: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('danmaku-item-1001-0-0')), findsNothing);
      updateDanmaku(controller);
      await tester.pump();
      controller.setEnabled(false);
      await tester.pump();
      expect(find.text('合成弹幕 0'), findsNothing);
      controller.setEnabled(true);
      controller.setPlan(
        const PlaybackPlan(
          url: 'https://media.example.test/new.mp4',
          session: 'next',
          danmakuId: '1002',
        ),
      );
      updateDanmaku(controller);
      await tester.pump();
      expect(find.byKey(const ValueKey('danmaku-item-1001-0-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('danmaku-item-1002-0-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('mobile landscape clips rows into the available top band', (
    tester,
  ) async {
    await mount(tester, size: const Size(880, 420));
    expect(
      tester.getRect(find.byKey(const ValueKey('danmaku-item-1001-0-0'))).top,
      64,
    );
    expect(find.byKey(const ValueKey('danmaku-item-1001-0-3')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile seeks do not reset content, but duration and plans do', (
    tester,
  ) async {
    await mount(tester);
    final revision = controller.contentRevision;
    controller.beginSeek();
    expect(controller.mobileVisible, isTrue);
    expect(controller.visible, isFalse);
    controller.endSeek(const Duration(seconds: 20));
    expect(controller.contentRevision, revision);
    await tester.pump();
    expect(find.byKey(const ValueKey('danmaku-item-1001-0-0')), findsOneWidget);
    updateDanmaku(controller, position: 20000, duration: 200000);
    expect(controller.contentRevision, revision + 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('danmaku-item-1001-0-0')), findsNothing);
    controller.endSeek(const Duration(seconds: 200));
    await tester.pump();
    expect(controller.mobileVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'mobile direct position discontinuities preserve existing flight positions',
    (tester) async {
      await mount(tester);
      await advance(tester, const Duration(seconds: 1));
      final beforeJump = x(tester);
      updateDanmaku(controller, position: 15000);
      await tester.pump();
      expect(x(tester), closeTo(beforeJump, .1));
      updateDanmaku(controller, position: 1000);
      await tester.pump();
      expect(x(tester), closeTo(beforeJump, .1));
      expect(
        find.byKey(const ValueKey('danmaku-item-1001-0-0')),
        findsOneWidget,
      );
      expect(find.text('跳过的弹幕不补刷'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile pause and buffering during an unfinished seek stop and resume motion',
    (tester) async {
      await mount(tester);
      await advance(tester, const Duration(seconds: 1));
      controller.beginSeek();
      await tester.pump();
      updateDanmaku(controller, position: 1000, playing: false);
      await tester.pump();
      final paused = x(tester);
      await advance(tester, const Duration(seconds: 1));
      expect(x(tester), closeTo(paused, .1));
      updateDanmaku(controller, position: 1000);
      await tester.pump();
      await advance(tester, const Duration(seconds: 1));
      expect(paused - x(tester), closeTo(48.3, .1));
      updateDanmaku(controller, position: 1000, buffering: true);
      await tester.pump();
      final buffered = x(tester);
      await advance(tester, const Duration(seconds: 1));
      expect(x(tester), closeTo(buffered, .1));
      updateDanmaku(controller, position: 1000);
      await tester.pump();
      await advance(tester, const Duration(seconds: 1));
      expect(buffered - x(tester), closeTo(48.3, .1));
      controller.endSeek(const Duration(seconds: 30));
      await tester.pump();
      expect(buffered - x(tester), closeTo(48.3, .1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile height-only lane changes reset the shared and flight clocks together',
    (tester) async {
      await mount(tester);
      await advance(tester, const Duration(seconds: 1));
      expect(x(tester), lessThan(420));
      tester.view.physicalSize = const Size(420, 400);
      await tester.pump();
      expect(x(tester), closeTo(420, .1));
      expect(find.byKey(const ValueKey('danmaku-item-1001-0-3')), findsNothing);
      await advance(tester, const Duration(seconds: 1));
      expect(x(tester), closeTo(371.7, .1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
