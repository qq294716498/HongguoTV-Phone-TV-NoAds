import 'dart:async';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:duanju_app/tv_decoder_settings.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class DecoderFailurePlayer extends ScriptedPlayer {
  void decoderFailure() => errorController.add(
    'MediaCodecVideoRenderer error, format_supported=NO_EXCEEDS_CAPABILITIES',
  );
}

void main() {
  setUp(mockPlayerDevice);
  Future<void> nativeBack(WidgetTester tester) async {
    final completed = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      AppDevice.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('televisionBackPressed'),
      ),
      (_) => completed.complete(),
    );
    await tester.pump();
    await completed.future;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 24; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  Future<LocalStore> mount(
    WidgetTester tester,
    RouteRepository repository,
    ScriptedPlayer player, {
    int initialIndex = 0,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final detail = DramaDetail(
      FixtureRepository.free,
      List.generate(100, (index) => Episode({'id': '${index + 1}'}, index + 1)),
    );
    await tester.pumpWidget(
      televisionHost(
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                child: const Text('打开测试视频'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerScreen(
                      detail: detail,
                      initialIndex: initialIndex,
                      initialPosition: 7,
                      repository: repository,
                      store: store,
                      playerFactory: () => Player(platformPlayer: player),
                      videoBuilder: (controls) => controls,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开测试视频'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    return store;
  }

  Future<void> leave(
    WidgetTester tester,
    RouteRepository repository,
    ScriptedPlayer player,
  ) async {
    await press(tester, LogicalKeyboardKey.escape);
    if (find.byType(PlayerScreen).evaluate().isNotEmpty) {
      await press(tester, LogicalKeyboardKey.escape);
    }
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(find.text('打开测试视频'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(player.disposed, isTrue);
    expect(repository.active, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  }

  testWidgets(
    'TV decoder failure stops retries and keeps settings and route switch accessible',
    (tester) async {
      final repository = RouteRepository();
      final player = DecoderFailurePlayer();
      await mount(tester, repository, player);
      final opens = player.opened.length;
      player.decoderFailure();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(find.text('暂时无法播放'), findsOneWidget);
      expect(find.textContaining('当前视频规格或解码器不兼容'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(player.opened.length, opens);
      expect(repository.fallbackCalls, 0);
      final settings = find.byKey(const ValueKey('tv-recovery-settings'));
      await tester.ensureVisible(settings);
      await tester.tap(settings);
      await settle(tester);
      expect(find.text('播放设置'), findsWidgets);
      await press(tester, LogicalKeyboardKey.escape);
      final source = find.byKey(const ValueKey('tv-recovery-source'));
      await tester.ensureVisible(source);
      await tester.tap(source);
      await settle(tester);
      expect(repository.fallbackCalls, 1);
      expect(player.opened.length, opens + 1);
      expect(find.text('暂时无法播放'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(repository.active, isEmpty);
    },
  );

  test(
    'TV decoder preferences migrate safely and preserve other playback settings',
    () {
      final old = PlaybackPreferences.fromJson({'speed': 1.25, 'quality': 720});
      expect(old.tvDecoderMode, TvDecoderMode.automatic);
      final saved = old.copyWith(
        tvDecoderMode: TvDecoderMode.software,
        tvTextureOutput: true,
      );
      final restored = PlaybackPreferences.fromJson(saved.toJson());
      expect(restored.tvDecoderMode, TvDecoderMode.software);
      expect(restored.tvTextureOutput, true);
      expect(restored.speed, 1.25);
      expect(restored.quality, 720);
      expect(
        PlaybackPreferences.fromJson({
          'tvDecoderMode': 'unknown',
        }).tvDecoderMode,
        TvDecoderMode.automatic,
      );
      expect(isDecoderCompatibilityError('HTTP 403'), false);
    },
  );

  testWidgets(
    'TV and global danmaku settings persist and update live without changing video rate',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      final store = await mount(tester, repository, player);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.select);
      final half = find.byKey(const ValueKey('tv-danmaku-speed-0.5'));
      await tester.ensureVisible(half);
      await tester.tap(half);
      await settle(tester);
      expect(store.playbackPreferences.danmakuSpeed, .5);
      expect(
        tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).speed,
        .5,
      );
      expect(
        tester
            .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
            .animationBehavior,
        AnimationBehavior.preserve,
      );
      final context = tester.element(find.byType(PlayerScreen));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(repository: repository, store: store),
        ),
      );
      await tester.pumpAndSettle();
      final settings = find.byKey(const ValueKey('global-danmaku-settings'));
      await tester.ensureVisible(settings);
      await tester.tap(settings);
      await tester.pumpAndSettle();
      final slower = find.byKey(const ValueKey('menu-danmaku-speed-0.75'));
      await tester.ensureVisible(slower);
      await tester.tap(slower);
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.danmakuSpeed, .75);
      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await tester.pumpAndSettle();
      final overlay = tester.widget<DanmakuOverlay>(
        find.byType(DanmakuOverlay),
      );
      expect(overlay.speed, .75);
      expect(overlay.television, isTrue);
      expect(player.state.rate, 1);
      expect(player.opened, hasLength(1));
      await store.flushPendingWrites();
      final restored = testStore(await SharedPreferences.getInstance());
      expect(restored.playbackPreferences.danmakuSpeed, .75);
      restored.dispose();
      await leave(tester, repository, player);
    },
  );

  testWidgets(
    'TV remote pauses, seeks when hidden, navigates the visible timeline and returns',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      final store = await mount(tester, repository, player);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
      await press(tester, LogicalKeyboardKey.select);
      expect(player.state.playing, isFalse);
      await press(tester, LogicalKeyboardKey.select);
      expect(player.state.playing, isTrue);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      await press(tester, LogicalKeyboardKey.select);
      expect(player.state.playing, isFalse);
      await press(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(player.state.position, const Duration(seconds: 22));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(player.state.position, Duration.zero);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-progress',
      );
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(player.state.position, Duration.zero);
      await leave(tester, repository, player);
      expect(store.watched(FixtureRepository.free.id)?.position, 7);
    },
  );

  testWidgets(
    'TV selection restores the current episode and panels keep focus during playback',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, initialIndex: 70);
      focusRemote(tester, find.byKey(const ValueKey('tv-episodes')));
      await settle(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-episodes',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-71');
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-71');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      expect(repository.requestedEpisodes.last, 72);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-surface',
      );
      expect(repository.active.length, 1);
      await press(tester, LogicalKeyboardKey.arrowDown);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('倍速'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      expect(player.state.rate, 1.25);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-surface',
      );
      await press(tester, LogicalKeyboardKey.arrowUp);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await settle(tester);
      await player.seek(const Duration(seconds: 28));
      await player.pause();
      await settle(tester);
      await press(tester, LogicalKeyboardKey.select);
      focusRemote(tester, find.byKey(const ValueKey('tv-quality-1080')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      expect(repository.requestedQualities.last, 720);
      expect(player.state.position, const Duration(seconds: 28));
      expect(player.state.rate, 1.25);
      expect(player.state.playing, isFalse);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-surface',
      );
      await leave(tester, repository, player);
    },
  );

  testWidgets('TV system back hides controls before leaving playback', (
    tester,
  ) async {
    final repository = RouteRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(player.disposed, isTrue);
    expect(repository.active, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'native TV back closes the modal into paused playback, then leaves playback',
    (tester) async {
      final active = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppDevice.channel,
        (call) async {
          if (call.method == 'setTelevisionPlaybackActive') {
            active.add((call.arguments as Map)['active'] as bool);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AppDevice.channel,
          null,
        ),
      );
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      expect(active, [true]);
      await player.pause();
      await settle(tester);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('播放设置'), findsOneWidget);
      await nativeBack(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.text('播放设置'), findsNothing);
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(player.state.playing, false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      expect(
        ModalRoute.of(
          tester.element(find.byType(PlayerScreen)),
        )!.popDisposition,
        RoutePopDisposition.pop,
      );
      await nativeBack(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(player.disposed, true);
      expect(repository.active, isEmpty);
      expect(active, [true, false]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV framework back closes modal into paused playback and then route',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await player.pause();
      await settle(tester);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('播放设置'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.text('播放设置'), findsNothing);
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(player.state.playing, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('打开测试视频'), findsOneWidget);
      expect(player.disposed, isTrue);
      expect(repository.active, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native TV back dismisses a seek preview without leaving playback',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byKey(const ValueKey('tv-seek-preview')), findsOneWidget);
      await nativeBack(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('tv-seek-preview')), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(player.state.playing, true);
      await leave(tester, repository, player);
    },
  );

  testWidgets(
    'TV playback error puts remote focus on retry and restores controls after retry',
    (tester) async {
      final repository = RouteRepository()..broken = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (var attempt = 0; attempt < 5; attempt++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(find.text('重试播放'), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      repository.broken = false;
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('重试播放'), findsNothing);
      expect(player.state.position, const Duration(seconds: 7));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
      await leave(tester, repository, player);
    },
  );
  testWidgets(
    'stopped playback with play intent recovers, but an intentional pause does not',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await player.pause();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 21)),
      );
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(repository.fallbackCalls, 1);
      expect(player.state.playing, true);
      await press(tester, LogicalKeyboardKey.select);
      expect(player.state.playing, false);
      final opens = player.opened.length;
      for (var second = 0; second < 25; second++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(player.opened.length, opens);
      expect(player.state.playing, false);
      await leave(tester, repository, player);
    },
  );

  testWidgets(
    'automatic episode advancement survives twenty episodes without retained sessions',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (var episode = 2; episode <= 20; episode++) {
        player.finishEpisode();
        await settle(tester);
        expect(repository.requestedEpisodes.last, episode);
        expect(player.state.playing, true);
        expect(repository.active.length, 1);
      }
      await leave(tester, repository, player);
    },
  );
}
