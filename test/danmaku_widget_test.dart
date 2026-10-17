import 'dart:convert';

import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, updateDanmaku, flushDanmaku;
import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  setUp(mockPlayerDevice);
  for (final television in [false, true]) {
    testWidgets('merged hearts render once on television=$television', (
      tester,
    ) async {
      final repository = DanmakuFixtureRepository()
        ..response = (request) => DanmakuPage(
          episodeId: request.plan.danmakuId,
          startMs: 0,
          nextMs: 30000,
          items: const [
            DanmakuItem(id: 'a', text: '合成弹幕[偷笑]', timeMs: 0),
            DanmakuItem(id: 'b', text: '合成弹幕🤭', timeMs: 0),
            DanmakuItem(id: 'c', text: '合成弹幕[偷笑]', timeMs: 500),
          ],
        );
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuOverlay(
              controller: controller,
              aspectRatio: 16 / 9,
              television: television,
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DanmakuEmojiText && widget.text == '合成弹幕🤭  ♥ 3',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('danmaku-item-b')), findsNothing);
      expect(find.byKey(const ValueKey('danmaku-item-c')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'TV danmaku uses equal real-time speed for long text and 2x playback, with pause and seek isolation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 540);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var now = DateTime(2026);
      final repository = DanmakuFixtureRepository()
        ..response = (request) => DanmakuPage(
          episodeId: request.plan.danmakuId,
          startMs: 0,
          nextMs: 30000,
          items: List.generate(
            6,
            (index) => DanmakuItem(
              id: 'top-$index',
              text: index == 1 ? '合成 TV 长弹幕用于验证长句不会加速移动' : '合成 TV 弹幕 $index',
              timeMs: 0,
            ),
          ),
        );
      final controller = DanmakuController(repository, now: () => now)
        ..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      Future<void> render(bool television) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuOverlay(
              controller: controller,
              aspectRatio: 16 / 9,
              television: television,
            ),
          ),
        ),
      );
      double x() => tester
          .widget<Transform>(find.byKey(const ValueKey('danmaku-motion-top-0')))
          .transform
          .storage[12];
      Finder flights() => find.byWidgetPredicate(
        (w) =>
            w is Positioned &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('danmaku-item-'),
      );
      await render(true);
      await tester.pump();
      expect(flights(), findsNWidgets(2));
      final text = tester.widget<Text>(find.text('合成 TV 弹幕 0'));
      expect(text.style!.fontSize, 14);
      expect(text.style!.fontWeight, FontWeight.w400);
      expect(text.style!.color!.a, closeTo(.55, .01));
      for (final element in flights().evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.top, greaterThanOrEqualTo(12));
        expect(rect.bottom, lessThanOrEqualTo(96));
      }
      final start = x();
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      final tvTravel = start - x();
      expect(tvTravel, closeTo(60, .1));
      final longX = tester
          .widget<Transform>(find.byKey(const ValueKey('danmaku-motion-top-1')))
          .transform
          .storage[12];
      expect(start - longX, closeTo(tvTravel, .1));
      updateDanmaku(controller, position: 2000, speed: 2);
      await tester.pump();
      final beforeDoubleSpeed = x();
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      updateDanmaku(controller, position: 4000, speed: 2);
      await tester.pump();
      expect(beforeDoubleSpeed - x(), closeTo(30, .1));
      updateDanmaku(controller, position: 4000, playing: false);
      await tester.pump();
      final paused = x();
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(x(), closeTo(paused, .01));
      await render(false);
      expect(flights(), findsNWidgets(3));
      final phoneText = tester.widget<Text>(find.text('合成 TV 弹幕 0'));
      expect(phoneText.style!.fontSize, 14);
      expect(phoneText.style!.color!.a, closeTo(.62, .01));
      expect(start - x(), greaterThan(tvTravel * 4));
      await render(true);
      controller.beginSeek();
      await tester.pump();
      expect(flights(), findsNothing);
      controller.endSeek(const Duration(seconds: 10));
      await tester.pump();
      expect(flights(), findsNothing);
      controller.endSeek(const Duration(seconds: 32));
      await tester.pump();
      expect(flights(), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<LocalStore> createStore([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<LocalStore> mount(
    WidgetTester tester,
    DanmakuFixtureRepository repository,
    ScriptedPlayer player, {
    LocalStore? store,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 880);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final local = store ?? await createStore();
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          repository: repository,
          store: local,
          playerFactory: () => Player(platformPlayer: player),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settle(tester);
    return local;
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    expect(player.disposed, isTrue);
    expect(tester.takeException(), isNull);
  }

  for (final landscape in [false, true]) {
    testWidgets(
      'mobile ${landscape ? 'landscape' : 'portrait'} short tap and long press share global danmaku settings',
      (tester) async {
        final repository = DanmakuFixtureRepository();
        final platform = ScriptedPlayer();
        final store = await mount(tester, repository, platform);
        if (landscape) {
          tester.view.physicalSize = const Size(880, 420);
          await settle(tester);
        }
        final beforePlaying = platform.state.playing;
        final opened = platform.opened.length;
        final settings = find.byKey(const ValueKey('player-danmaku-toggle'));
        expect(find.byTooltip('播放设置'), findsNothing);
        expect(settings, findsOneWidget);
        await tester.tap(settings);
        await settle(tester);
        expect(store.playbackPreferences.danmaku, false);
        expect(find.byType(PlayerMenu), findsNothing);
        await tester.longPress(settings);
        await settle(tester);
        expect(store.playbackPreferences.danmaku, false);
        expect(find.byType(PlayerMenu), findsOneWidget);
        expect(
          tester.widget<PlayerMenu>(find.byType(PlayerMenu)).section,
          PlayerMenuSection.danmaku,
        );
        final speed = find.byKey(const ValueKey('menu-danmaku-speed-1.5'));
        await tester.ensureVisible(speed);
        await tester.tap(speed);
        await settle(tester);
        final opacity = find.byKey(const ValueKey('menu-danmaku-opacity-0.35'));
        await tester.ensureVisible(opacity);
        await tester.tap(opacity);
        await settle(tester);
        expect(store.playbackPreferences.danmakuSpeed, 1.5);
        expect(store.playbackPreferences.danmakuOpacity, .35);
        Navigator.of(tester.element(find.byType(PlayerMenu))).pop();
        await settle(tester);
        final overlay = tester.widget<DanmakuOverlay>(
          find.byType(DanmakuOverlay),
        );
        expect(overlay.speed, 1.5);
        expect(overlay.opacity, .35);
        expect(platform.opened, hasLength(opened));
        expect(platform.state.playing, beforePlaying);
        await tester.tap(settings);
        await settle(tester);
        expect(store.playbackPreferences.danmaku, true);
        final context = tester.element(find.byType(PlayerScreen));
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                SettingsScreen(repository: repository, store: store),
          ),
        );
        await settle(tester);
        expect(find.byType(SettingsScreen), findsOneWidget);
        final global = find.byKey(const ValueKey('global-danmaku-settings'));
        await tester.ensureVisible(global);
        await tester.tap(global);
        await settle(tester);
        expect(
          tester.widget<PlayerMenu>(find.byType(PlayerMenu)).section,
          PlayerMenuSection.danmaku,
        );
        final globalOpacity = find.byKey(
          const ValueKey('menu-danmaku-opacity-0.8'),
        );
        await tester.ensureVisible(globalOpacity);
        await tester.tap(globalOpacity);
        await settle(tester);
        Navigator.of(tester.element(find.byType(PlayerMenu))).pop();
        await settle(tester);
        Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
        await settle(tester);
        expect(
          tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).opacity,
          .8,
        );
        expect(
          tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).speed,
          1.5,
        );
        expect(platform.opened, hasLength(opened));
        await store.flushPendingWrites();
        final restored = LocalStore(store.preferences);
        expect(restored.playbackPreferences.danmakuSpeed, 1.5);
        expect(restored.playbackPreferences.danmakuOpacity, .8);
        restored.dispose();
        await tester.tap(find.byTooltip('锁定屏幕'));
        await settle(tester);
        await tester.longPress(settings, warnIfMissed: false);
        await settle(tester);
        expect(find.byType(PlayerMenu), findsNothing);
        expect(platform.state.playing, beforePlaying);
        await tester.tap(find.byTooltip('解锁屏幕'));
        await settle(tester);
        await unmount(tester, platform);
      },
    );
  }

  testWidgets(
    'danmaku uses continuous linear motion and synchronizes pause, buffering, speed and seek',
    (tester) async {
      var now = DateTime(2026);
      final controller = DanmakuController(
        DanmakuFixtureRepository(),
        now: () => now,
      )..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 300,
                child: DanmakuOverlay(
                  controller: controller,
                  aspectRatio: 4 / 3,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      double x() => tester
          .widget<Transform>(
            find.byKey(const ValueKey('danmaku-motion-1001-0')),
          )
          .transform
          .storage[12];
      final start = x();
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      final afterTwo = x();
      expect(afterTwo, lessThan(start));
      final travel = (start - afterTwo) * 4;
      updateDanmaku(controller, position: 2000, playing: false);
      await tester.pump();
      final paused = x();
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(x(), closeTo(paused, .01));
      updateDanmaku(controller, position: 2000, speed: 2);
      await tester.pump();
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(x(), closeTo(start - travel * .5, .1));
      updateDanmaku(controller, position: 4000, speed: 2, buffering: true);
      await tester.pump();
      final buffered = x();
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(x(), closeTo(buffered, .01));
      controller.beginSeek();
      await tester.pump();
      expect(find.text('合成弹幕 1001'), findsNothing);
      controller.endSeek(const Duration(seconds: 6));
      await tester.pump();
      expect(x(), closeTo(start - travel * .75, .1));
      controller.setEnabled(false);
      await tester.pump();
      expect(find.text('合成弹幕 1001'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'optional requests do not delay video and late replies never appear on another episode',
    (tester) async {
      final repository = DanmakuFixtureRepository()..holdDanmaku = true;
      final player = ScriptedPlayer();
      final store = await mount(tester, repository, player);
      expect(player.opened.length, 1);
      expect(player.state.playing, isTrue);
      expect(find.text('正在准备播放'), findsNothing);
      expect(
        tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).mobile,
        isTrue,
      );
      final old = repository.danmakuCalls.single;
      await tester.tap(find.byKey(const ValueKey('player-portrait-episodes')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settle(tester);
      final current = repository.danmakuCalls.last;
      expect(current.plan.danmakuId, '1002');
      old.result.complete(DanmakuFixtureRepository.page(old));
      await settle(tester);
      expect(find.text('合成弹幕 1001'), findsNothing);
      current.result.complete(DanmakuFixtureRepository.page(current));
      await settle(tester);
      expect(find.text('合成弹幕 1002'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-danmaku-toggle')));
      await settle(tester);
      expect(store.playbackPreferences.danmaku, isFalse);
      expect(find.text('合成弹幕 1002'), findsNothing);
      expect(repository.primaryCalls, 2);
      expect(repository.fallbackCalls, 0);
      await unmount(tester, player);
    },
  );

  testWidgets(
    'danmaku failure and manual retry stay on player controls without interrupting playback',
    (tester) async {
      final repository = DanmakuFixtureRepository()..failDanmaku = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      expect(player.state.playing, isTrue);
      expect(find.text('暂时无法播放'), findsNothing);
      repository.failDanmaku = false;
      await tester.tap(find.byKey(const ValueKey('player-danmaku-toggle')));
      await settle(tester);
      expect(repository.danmakuCalls.length, 2);
      expect(repository.primaryCalls, 1);
      expect(repository.fallbackCalls, 0);
      expect(player.state.playing, isTrue);
      expect(find.text('合成弹幕 1001'), findsOneWidget);
      await unmount(tester, player);
    },
  );

  testWidgets('local playback skips danmaku even when the switch is on', (
    tester,
  ) async {
    final repository = DanmakuFixtureRepository()..local = true;
    final player = ScriptedPlayer();
    final store = await mount(tester, repository, player);
    expect(repository.danmakuCalls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('player-danmaku-toggle')));
    await settle(tester);
    expect(store.playbackPreferences.danmaku, isFalse);
    expect(repository.danmakuCalls, isEmpty);
    await unmount(tester, player);
  });

  testWidgets(
    'switching users clears in-flight danmaku before a delayed response returns',
    (tester) async {
      final store = await createStore({
        'profiles': jsonEncode(
          [
            LocalProfile(
              id: 'default',
              name: '管理员',
              admin: true,
              salt: ''.padLeft(32, 'a'),
              pinHash: ''.padLeft(64, 'b'),
            ),
            const LocalProfile(
              id: 'viewer',
              name: '观看用户',
              sources: ['hongguo'],
            ),
            const LocalProfile(id: 'visitor', name: '访客', download: false),
          ].map((profile) => profile.toJson()).toList(),
        ),
        'activeProfile': 'viewer',
      });
      final repository = DanmakuFixtureRepository()..holdDanmaku = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player, store: store);
      final pending = repository.danmakuCalls.single;
      await store.switchProfile('visitor');
      pending.result.complete(DanmakuFixtureRepository.page(pending));
      await settle(tester);
      expect(repository.danmakuCancellations, 1);
      expect(find.text('合成弹幕 1001'), findsNothing);
      await unmount(tester, player);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  testWidgets(
    'large text settings and TV controls expose the danmaku preference',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      PlaybackPreferences? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: PlayerMenu(
                section: PlayerMenuSection.settings,
                episodes: const [],
                currentIndex: 0,
                preferences: const PlaybackPreferences(),
                qualities: const [1080, 720],
                actualQuality: 1080,
                local: false,
                favorite: false,
                mobile: true,
                showDanmaku: true,
                danmakuStatus: '这段暂无弹幕',
                onEpisode: (_) {},
                onFavorite: () async {},
                onPreferences: (value) async {
                  chosen = value;
                },
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('player-danmaku-enabled')),
      );
      await tester.tap(find.byKey(const ValueKey('player-danmaku-enabled')));
      await settle(tester);
      expect(chosen?.danmaku, isFalse);
      expect(tester.takeException(), isNull);
      final faster = find.byKey(const ValueKey('menu-danmaku-speed-2.0'));
      await tester.ensureVisible(faster);
      await tester.tap(faster);
      await settle(tester);
      expect(chosen?.danmakuSpeed, 2);
      final opacity = find.byKey(const ValueKey('menu-danmaku-opacity-0.35'));
      await tester.ensureVisible(opacity);
      await tester.tap(opacity);
      await settle(tester);
      expect(chosen?.danmakuOpacity, .35);

      expect(chosen?.speed, 1);
      expect(tester.takeException(), isNull);
      TelevisionPlaybackSetting? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDialog<TelevisionPlaybackSetting>(
                    context: context,
                    builder: (_) => TelevisionSettingsDialog(
                      speed: 1,
                      quality: 0,
                      qualities: const [],
                      favorite: false,
                      onFavorite: () {},
                      showDanmaku: true,
                      danmaku: true,
                      danmakuStatus: '这段暂无弹幕',
                    ),
                  );
                },
                child: const Text('打开电视设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开电视设置'));
      await settle(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('tv-danmaku-enabled')),
      );
      await tester.tap(find.byKey(const ValueKey('tv-danmaku-enabled')));
      await settle(tester);
      expect(selected?.danmaku, isFalse);
      await tester.tap(find.text('打开电视设置'));
      await settle(tester);
      final tvFaster = find.byKey(const ValueKey('tv-danmaku-speed-1.5'));
      await tester.ensureVisible(tvFaster);
      Focus.of(
        tester.element(
          find
              .descendant(of: tvFaster, matching: find.byType(GestureDetector))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(selected?.danmakuSpeed, 1.5);
      await tester.tap(find.text('打开电视设置'));
      await settle(tester);
      final tvOpacity = find.byKey(const ValueKey('tv-danmaku-opacity-0.35'));
      await tester.ensureVisible(tvOpacity);
      Focus.of(
        tester.element(
          find
              .descendant(of: tvOpacity, matching: find.byType(GestureDetector))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(selected?.danmakuOpacity, .35);

      expect(selected?.speed, isNull);

      expect(tester.takeException(), isNull);
    },
  );
}
