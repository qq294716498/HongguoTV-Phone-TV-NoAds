import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:duanju_app/watch_reminder_models.dart';
import 'package:duanju_app/watch_reminder_runtime.dart';
import 'package:duanju_app/watch_reminder_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

void main() {
  setUp(mockPlayerDevice);
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  for (final size in [
    const Size(420, 880),
    const Size(880, 420),
    const Size(960, 540),
    const Size(1000, 500),
  ]) {
    final tv = size.width == 960;
    final excluded = size.width >= 960;
    testWidgets(
      'reminders only render on actual mobile playback $size TV=$tv',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        await store.setPlaybackPreferences(
          const PlaybackPreferences(
            reminders: WatchReminderPreferences(
              dailyEnabled: true,
              dailyLimitMinutes: 1,
              bedtimeEnabled: true,
              bedtimeMinute: 60,
            ),
          ),
        );
        var now = DateTime(2026, 10, 14, 0, 59);
        var elapsed = Duration.zero;
        final runtime = WatchReminderRuntime(
          store,
          now: () => now,
          elapsed: () => elapsed,
          startTimer: false,
        );
        WatchReminderRuntime.current = runtime;
        final repository = RouteRepository();
        final player = ScriptedPlayer();
        final detail = await repository.detail(FixtureRepository.free);
        final page = PlayerScreen(
          detail: detail,
          initialIndex: 0,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: player),
          videoBuilder: (controls) => controls,
        );
        await tester.pumpWidget(
          tv
              ? televisionHost(child: page)
              : MaterialApp(
                  builder: (_, child) => AppLayout(
                    television: false,
                    mobileReminders: !excluded,
                    child: child!,
                  ),
                  home: page,
                ),
        );
        await settle(tester);
        expect(player.state.playing, true);
        now = now.add(const Duration(minutes: 1));
        elapsed += const Duration(minutes: 1);
        runtime.tick();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('watch-reminder-dialog')),
          excluded ? findsNothing : findsOneWidget,
        );
        expect(runtime.engine.progress.watchedMs, excluded ? 0 : 60000);
        if (!excluded) {
          expect(find.text('已到你设置的睡觉时间，早点休息吧。'), findsOneWidget);
          tester.view.physicalSize = Size(size.height, size.width);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('watch-reminder-dialog')),
            findsOneWidget,
          );
          if (size.width > size.height) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.tap(
              find.byKey(const ValueKey('watch-reminder-dismiss')),
            );
          }
          await tester.pump();
          expect(
            find.byKey(const ValueKey('watch-reminder-dialog')),
            findsNothing,
          );
          now = now.add(const Duration(minutes: 5));
          elapsed += const Duration(minutes: 5);
          runtime.tick();
          await tester.pump();
          expect(
            find.byKey(const ValueKey('watch-reminder-dialog')),
            findsOneWidget,
          );
          await player.pause();
          await settle(tester);
          expect(
            find.byKey(const ValueKey('watch-reminder-dialog')),
            findsNothing,
          );
          final total = runtime.engine.progress.watchedMs;
          now = now.add(const Duration(minutes: 10));
          elapsed += const Duration(minutes: 10);
          runtime.tick();
          await tester.pump();
          expect(runtime.engine.progress.watchedMs, total);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await runtime.flush();
        runtime.dispose();
        await runtime.flush();
        WatchReminderRuntime.current = null;
        store.dispose();
        expect(player.disposed, true);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile settings validate custom numbers, cancel safely, set local bedtime',
    (tester) async {
      var preferences = const WatchReminderPreferences();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => WatchReminderSettings(
                  preferences: preferences,
                  onChanged: (value) async {
                    setState(() => preferences = value);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(preferences.dailyEnabled, false);
      expect(preferences.bedtimeEnabled, false);
      expect(find.text('4.00 小时'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reminder-daily-enabled')));
      await tester.pumpAndSettle();
      expect(preferences.dailyEnabled, true);
      expect(preferences.bedtimeEnabled, false);
      await tester.tap(find.byKey(const ValueKey('reminder-daily-limit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reminder-number-input')),
        '-1',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入1分钟至24小时的时长'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reminder-number-input')),
        '1.5',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(preferences.dailyLimitMinutes, 90);
      await tester.tap(find.byKey(const ValueKey('reminder-daily-repeat')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reminder-number-input')),
        '2.5',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入1至120之间的整数'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(preferences.dailyRepeatMinutes, 5);
      await tester.ensureVisible(
        find.byKey(const ValueKey('reminder-bedtime-time')),
      );
      await tester.tap(find.byKey(const ValueKey('reminder-bedtime-time')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '23');
      await tester.enterText(find.byType(TextField).at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(preferences.bedtimeMinute, 1410);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV settings contain opacity but no reminder controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      televisionHost(
        child: TelevisionSettingsDialog(
          speed: 1,
          quality: 0,
          qualities: const [],
          favorite: false,
          onFavorite: () {},
          showDanmaku: true,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('tv-danmaku-opacity-0.35')),
      findsOneWidget,
    );
    expect(find.byType(WatchReminderSettings), findsNothing);
    expect(
      find.byKey(const ValueKey('reminder-bedtime-enabled')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop player menu does not show mobile reminders', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerMenu(
          section: PlayerMenuSection.settings,
          episodes: const [],
          currentIndex: 0,
          preferences: const PlaybackPreferences(),
          qualities: const [],
          actualQuality: 0,
          local: false,
          favorite: false,
          mobile: false,
          onEpisode: (_) {},
          onPreferences: (_) async {},
          onFavorite: () async {},
        ),
      ),
    );
    expect(find.byType(WatchReminderSettings), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
