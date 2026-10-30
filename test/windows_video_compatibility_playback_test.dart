import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/video_controller_settings.dart';
import 'package:duanju_app/video_enhancement_policy.dart';
import 'package:duanju_app/video_enhancement_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

Future<void> compatibilityFrames(WidgetTester tester) async {
  for (var index = 0; index < 30; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

class CompatibilityPlayer extends ScriptedPlayer {
  final seeks = <Duration>[];
  var disposeCalls = 0;

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await super.seek(position);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}

bool hardwareEligible(String actualDecoder) => videoHardwareEnhancementEligible(
  windows: true,
  gpu: true,
  recentMpv: true,
  vendor: 'intel',
  hwdec: actualDecoder,
  format: 'nv12',
);

VideoEnhancementBackend enhancementBackend(String actualDecoder) =>
    chooseVideoEnhancement(
      preferences: const VideoEnhancementPreferences(
        mode: VideoEnhancementMode.quality,
      ),
      parameters: const VideoParams(
        w: 640,
        h: 360,
        dw: 640,
        dh: 360,
        par: 1,
        rotate: 0,
        pixelformat: 'nv12',
        gamma: 'bt.1886',
        primaries: 'bt.709',
        sigPeak: 1,
      ),
      viewport: const Size(1280, 720),
      ready: true,
      android: false,
      television: false,
      gpu: true,
      luma: true,
      hardware: hardwareEligible(actualDecoder),
      animation: false,
      power: const VideoEnhancementPower(onBattery: false),
      rate: 1,
      costLimit: 4,
      rejected: const {},
    ).backend;

void main() {
  setUp(mockPlayerDevice);

  test('only newly created Windows outputs use a changed saved choice', () {
    final oldPreferences = PlaybackPreferences.fromJson({
      'speed': 1.5,
      'quality': 720,
    });
    final active = playbackVideoConfiguration(
      operatingSystem: 'windows',
      preferences: oldPreferences,
    );
    final enabled = oldPreferences.copyWith(windowsVideoCompatibility: true);
    final reopened = playbackVideoConfiguration(
      operatingSystem: 'windows',
      preferences: enabled,
    );
    final disabled = playbackVideoConfiguration(
      operatingSystem: 'windows',
      preferences: enabled.copyWith(windowsVideoCompatibility: false),
    );
    expect(active.hwdec, 'auto');
    expect(reopened.hwdec, 'd3d11va-copy');
    expect(disabled.hwdec, 'auto');
    expect(active.hwdec, 'auto');
    expect(reopened.enableHardwareAcceleration, isTrue);
    expect(enabled.speed, 1.5);
    expect(enabled.quality, 720);
  });

  test('Windows preference leaves other platform decoder policies intact', () {
    const enabled = PlaybackPreferences(windowsVideoCompatibility: true);
    for (final operatingSystem in ['android', 'ios', 'linux', 'macos']) {
      final configured = playbackVideoConfiguration(
        operatingSystem: operatingSystem,
        preferences: enabled,
      );
      expect(configured.hwdec, isNull, reason: operatingSystem);
    }
    final macFallback = playbackVideoConfiguration(
      operatingSystem: 'macos',
      preferences: enabled,
      macHardwareVideoOutput: false,
    );
    expect(macFallback.hwdec, 'videotoolbox-copy');
    expect(macFallback.enableHardwareAcceleration, isFalse);
  });

  test(
    'hardware enhancement follows actual decoding through pending changes',
    () {
      var saved = const PlaybackPreferences();
      final active = playbackVideoConfiguration(
        operatingSystem: 'windows',
        preferences: saved,
      );
      expect(enhancementBackend('d3d11va'), VideoEnhancementBackend.hardware);
      saved = saved.copyWith(windowsVideoCompatibility: true);
      expect(active.hwdec, 'auto');
      expect(enhancementBackend('d3d11va'), VideoEnhancementBackend.hardware);
      final reopened = playbackVideoConfiguration(
        operatingSystem: 'windows',
        preferences: saved,
      );
      expect(reopened.hwdec, 'd3d11va-copy');
      expect(
        enhancementBackend('d3d11va-copy'),
        VideoEnhancementBackend.fsrcnnx,
      );
      expect(enhancementBackend('no'), isNot(VideoEnhancementBackend.hardware));
      saved = saved.copyWith(windowsVideoCompatibility: false);
      expect(
        playbackVideoConfiguration(
          operatingSystem: 'windows',
          preferences: saved,
        ).hwdec,
        'auto',
      );
      expect(enhancementBackend('d3d11va'), VideoEnhancementBackend.hardware);
    },
  );

  test(
    'copy, software fallback and unavailable decoders cannot qualify for VSR',
    () {
      expect(hardwareEligible('d3d11va'), isTrue);
      for (final actual in ['d3d11va-copy', 'no', '', 'dxva2-copy']) {
        expect(hardwareEligible(actual), isFalse, reason: actual);
      }
      for (final guard in ['windows', 'gpu', 'recentMpv', 'vendor', 'format']) {
        expect(
          videoHardwareEnhancementEligible(
            windows: guard != 'windows',
            gpu: guard != 'gpu',
            recentMpv: guard != 'recentMpv',
            vendor: guard == 'vendor' ? 'unknown' : 'intel',
            hwdec: 'd3d11va',
            format: guard == 'format' ? 'p010' : 'nv12',
          ),
          isFalse,
          reason: guard,
        );
      }
    },
  );

  for (final initialCompatibility in [false, true]) {
    for (final playing in [false, true]) {
      testWidgets(
        'saved compatibility from $initialCompatibility keeps active playback playing=$playing and survives a stale menu',
        (tester) async {
          tester.view.physicalSize = const Size(1000, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final shared = await SharedPreferences.getInstance();
          final store = LocalStore(shared);
          final repository = RouteRepository();
          final detail = await repository.detail(FixtureRepository.free);
          final platform = CompatibilityPlayer();
          final player = Player(platformPlayer: platform);
          var creations = 0;
          await store.setWindowsVideoCompatibility(initialCompatibility);
          await tester.pumpWidget(
            MaterialApp(
              home: PlayerScreen(
                detail: detail,
                initialIndex: 0,
                initialPosition: 43.5,
                initiallyPlaying: playing,
                repository: repository,
                store: store,
                playerFactory: () {
                  creations++;
                  return player;
                },
                videoBuilder: (controls) =>
                    ColoredBox(color: Colors.black, child: controls),
              ),
            ),
          );
          await compatibilityFrames(tester);
          final screenState = tester.state(find.byType(PlayerScreen));
          final controls = tester.widget<PlayerControls>(
            find.byType(PlayerControls),
          );
          final closeMenu = controls.onSettings!();
          await tester.pumpAndSettle();
          final oldMenu = tester.widget<PlayerMenu>(find.byType(PlayerMenu));
          final oldPreferences = oldMenu.preferences;
          final seekCount = platform.seeks.length;
          expect(
            oldPreferences.windowsVideoCompatibility,
            initialCompatibility,
          );
          await store.setWindowsVideoCompatibility(!initialCompatibility);
          await tester.pump();
          await oldMenu.onPreferences(oldPreferences.copyWith(speed: 1.5));
          await tester.pump();
          expect(
            store.playbackPreferences.windowsVideoCompatibility,
            !initialCompatibility,
          );
          expect(store.playbackPreferences.speed, 1.5);
          expect(tester.state(find.byType(PlayerScreen)), same(screenState));
          expect(creations, 1);
          expect(platform.opened, hasLength(1));
          expect(platform.disposeCalls, 0);
          expect(platform.seeks, hasLength(seekCount));
          expect(platform.state.position.inMilliseconds, 43500);
          expect(platform.state.playing, playing);
          expect(platform.rates.last, 1.5);
          Navigator.of(tester.element(find.byType(PlayerMenu))).pop();
          await tester.pumpAndSettle();
          await closeMenu;
          expect(
            tester.widget<PlayerControls>(find.byType(PlayerControls)).player,
            same(player),
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await compatibilityFrames(tester);
          await store.flushPendingWrites();
          expect(platform.disposeCalls, 1);
          expect(platform.disposalComplete, isTrue);
          expect(store.watched(detail.drama.id)?.position, 43.5);
          final restored = LocalStore(shared);
          expect(
            restored.playbackPreferences.windowsVideoCompatibility,
            !initialCompatibility,
          );
          expect(restored.watched(detail.drama.id)?.position, 43.5);
          restored.dispose();
          store.dispose();
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }

  testWidgets(
    'pending mode survives episode reuse and reopening resumes the saved episode',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final shared = await SharedPreferences.getInstance();
      final store = LocalStore(shared);
      final repository = RouteRepository();
      final detail = await repository.detail(FixtureRepository.free);
      final first = CompatibilityPlayer();
      final second = CompatibilityPlayer();
      var creations = 0;

      Future<void> mount(
        CompatibilityPlayer platform,
        int index,
        double position,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              detail: detail,
              initialIndex: index,
              initialPosition: position,
              initiallyPlaying: false,
              repository: repository,
              store: store,
              playerFactory: () {
                creations++;
                return Player(platformPlayer: platform);
              },
              videoBuilder: (controls) =>
                  ColoredBox(color: Colors.black, child: controls),
            ),
          ),
        );
        await compatibilityFrames(tester);
      }

      await mount(first, 0, 43.5);
      await store.setWindowsVideoCompatibility(true);
      await tester.pump();
      tester.widget<PlayerControls>(find.byType(PlayerControls)).onNext!();
      await compatibilityFrames(tester);
      expect(creations, 1);
      expect(first.opened, hasLength(2));
      expect(first.disposeCalls, 0);
      expect(store.playbackPreferences.windowsVideoCompatibility, isTrue);
      await first.pause();
      await first.seek(const Duration(milliseconds: 26750));
      await tester.pumpWidget(const SizedBox.shrink());
      await compatibilityFrames(tester);
      await store.flushPendingWrites();
      expect(first.disposeCalls, 1);
      final watch = store.watched(detail.drama.id)!;
      expect(watch.episode, 2);
      expect(watch.position, 26.75);
      await mount(second, watch.episode - 1, watch.position);
      expect(creations, 2);
      expect(second.opened, hasLength(1));
      expect(second.state.position.inMilliseconds, 26750);
      expect(second.state.playing, isFalse);
      expect(store.playbackPreferences.windowsVideoCompatibility, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await compatibilityFrames(tester);
      await store.flushPendingWrites();
      expect(second.disposeCalls, 1);
      store.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
