import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/windows_danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, updateDanmaku, flushDanmaku;

void main() {
  test('desktop type scales with logical video area and remains bounded', () {
    expect(windowsDanmakuFontSize(const Size(960, 540)), 18);
    expect(windowsDanmakuFontSize(const Size(320, 180)), 12);
    expect(windowsDanmakuFontSize(const Size(7680, 4320)), 28);
    expect(
      windowsDanmakuFontSize(const Size(960, 540), textScale: 3),
      closeTo(20.7, .01),
    );
  });
  testWidgets(
    'resize and DPI preserve active identities and positions; speed moves without video-rate coupling',
    (tester) async {
      tester.view.physicalSize = const Size(2000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = DanmakuFixtureRepository()
        ..response = (request) => DanmakuPage(
          episodeId: request.plan.danmakuId,
          startMs: 0,
          nextMs: 30000,
          items: const [DanmakuItem(id: 'pc', text: '桌面合成弹幕🤭', timeMs: 0)],
        );
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      Future<void> render(Size size, {double speed = 1, double dpi = 1}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: MediaQuery(
                    data: MediaQueryData(devicePixelRatio: dpi),
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: DanmakuOverlay(
                        controller: controller,
                        aspectRatio: 16 / 9,
                        desktop: true,
                        speed: speed,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
      final item = find.byKey(const ValueKey('danmaku-item-pc'));
      double x() => tester
          .widget<Transform>(find.byKey(const ValueKey('danmaku-motion-pc')))
          .transform
          .storage[12];
      double font() => tester
          .widget<DanmakuEmojiText>(find.byType(DanmakuEmojiText))
          .style
          .fontSize!;
      await render(const Size(960, 540));
      await tester.pump();
      final initialState = tester.state(find.byType(WindowsDanmakuOverlay));
      final start = x();
      await tester.pump(const Duration(milliseconds: 500));
      final normalTravel = start - x();
      expect(normalTravel, closeTo(48, .1));
      final position = x();
      for (final size in [
        const Size(480, 270),
        const Size(1920, 1080),
        const Size(968, 600),
        const Size(1280, 600),
        const Size(960, 540),
      ]) {
        await render(size);
        expect(item, findsOneWidget);
        expect(x(), closeTo(position, .01));
        expect(
          tester.state(find.byType(WindowsDanmakuOverlay)),
          same(initialState),
        );
        expect(font(), inInclusiveRange(12, 28));
      }
      final normalFont = font();
      await render(const Size(960, 540), dpi: 2);
      expect(font(), normalFont);
      expect(x(), closeTo(position, .01));
      await render(const Size(960, 540), speed: 2);
      expect(x(), closeTo(position, .01));
      await tester.pump(const Duration(milliseconds: 500));
      expect(position - x(), closeTo(normalTravel * 2, .1));
      updateDanmaku(controller, speed: 3);
      await tester.pump();
      final fast = x();
      await tester.pump(const Duration(milliseconds: 500));
      expect(fast - x(), closeTo(normalTravel * 2, .1));
      updateDanmaku(controller, playing: false);
      await tester.pump();
      final paused = x();
      await tester.pump(const Duration(seconds: 1));
      expect(x(), closeTo(paused, .01));
      expect(item, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Windows menu exposes exact persisted danmaku speed independently of playback speed',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlayerMenu(
                section: PlayerMenuSection.settings,
                episodes: const [],
                currentIndex: 0,
                preferences: store.playbackPreferences,
                qualities: const [],
                actualQuality: 0,
                local: false,
                favorite: false,
                mobile: false,
                showDanmaku: true,
                onEpisode: (_) {},
                onFavorite: () async {},
                onPreferences: store.setPlaybackPreferences,
              ),
            ),
          ),
        ),
      );
      final speed = find.byKey(const ValueKey('menu-danmaku-speed-1.5'));
      await tester.ensureVisible(speed);
      await tester.tap(speed);
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.danmakuSpeed, 1.5);
      expect(store.playbackPreferences.speed, 1);
      await store.flushPendingWrites();
      final restored = LocalStore(preferences);
      expect(restored.playbackPreferences.danmakuSpeed, 1.5);
      await tester.pumpWidget(const SizedBox.shrink());
      restored.dispose();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
