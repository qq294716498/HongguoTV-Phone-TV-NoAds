import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_interactions.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class TransportFixture {
  final platform = ScriptedPlayer();
  late final Player player;
  late final PlayerInteractions interactions;
  late StateSetter rebuild;
  final seeks = <Duration>[];
  var enabled = true;
  var hasNext = true;
  var nextCalls = 0;
  var forwardCalls = 0;
  var toggleCalls = 0;
  var unmounted = false;
  bool? fullscreenValue;
  Future<void> Function()? openMenu;

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(960, 540),
    bool fullscreen = true,
    bool showOnPlaybackReady = true,
    bool mobile = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    player = Player(platformPlayer: platform);
    await player.open(Media('file:///synthetic-transport.mp4'));
    await player.seek(const Duration(seconds: 29));
    await player.pause();
    interactions = PlayerInteractions(
      player: player,
      available: () => enabled,
      baseSpeed: () => 1.25,
      onTogglePlayback: player.playOrPause,
      onFullscreen: () {},
      onEpisode: (_) => '',
      onSeek: (target) async {
        seeks.add(target);
        await player.seek(target);
      },
    );
    var theme = AppTheme.dark;
    final font = Platform.environment['HG_UI_FONT'];
    if (font != null) {
      await tester.runAsync(() async {
        for (final entry in {
          'TransportPreviewCJK': font,
          'MaterialIcons': Platform.environment['HG_UI_ICON_FONT'],
        }.entries) {
          if (entry.value == null) continue;
          final bytes = await File(entry.value!).readAsBytes();
          await (FontLoader(
            entry.key,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'TransportPreviewCJK'),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('transport-capture'),
            child: ColoredBox(
              color: const Color(0xFF17212A),
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PlayerControls(
                    player: player,
                    interactions: interactions,
                    enabled: enabled,
                    fullscreen: fullscreenValue ?? fullscreen,
                    showOnPlaybackReady: showOnPlaybackReady,
                    swipeEnabled: mobile,
                    title: '合成视频 · 播放按钮验证',
                    episodeLabel: '第 1 集',
                    onFullscreen: () {},
                    onBack: () {},
                    onPrevious: null,
                    onNext: hasNext ? () => nextCalls++ : null,
                    onTogglePlayback: () {
                      toggleCalls++;
                      player.playOrPause();
                    },
                    onForward: () async {
                      forwardCalls++;
                      final resume = !player.state.playing;
                      final target = Duration(
                        milliseconds:
                            (player.state.position.inMilliseconds + 15000)
                                .clamp(0, player.state.duration.inMilliseconds),
                      );
                      seeks.add(target);
                      await player.seek(target);
                      if (resume && target < player.state.duration) {
                        await player.playOrPause();
                      }
                    },
                    onEpisodes: () async {},
                    onSpeed: () async {},
                    onQuality: () async => openMenu?.call(),
                    onPictureInPicture: () async {},
                    speed: 1.25,
                    qualityLabel: '自动',
                    onFocusSurface: () {},
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => unmount(tester));
  }

  Future<void> unmount(WidgetTester tester) async {
    if (unmounted) return;
    unmounted = true;
    await tester.pumpWidget(const SizedBox.shrink());
    interactions.dispose();
    await player.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void main() {
  setUp(mockPlayerDevice);
  final forward = find.byKey(const ValueKey('player-mobile-forward'));
  final next = find.byKey(const ValueKey('player-mobile-next'));

  testWidgets(
    'desktop forward button seeks fifteen seconds and resumes playback',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(
        tester,
        size: const Size(800, 600),
        fullscreen: false,
        mobile: false,
      );
      final forward = find.byKey(const ValueKey('player-desktop-forward'));
      expect(forward, findsOneWidget);
      await tester.tap(forward);
      await tester.pumpAndSettle();
      expect(fixture.forwardCalls, 1);
      expect(fixture.platform.state.position, const Duration(seconds: 44));
      expect(fixture.platform.state.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fullscreen play, forward fifteen and next keep order and seek bounds',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester);
      final play = tester.getRect(
        find.byKey(const ValueKey('player-mobile-play')),
      );
      final jump = tester.getRect(forward);
      final skip = tester.getRect(next);
      expect(jump.left, play.right);
      expect(skip.left, jump.right);
      expect(jump.center.dy, play.center.dy);
      expect(skip.center.dy, play.center.dy);
      expect(jump.size, const Size(48, 48));
      expect(skip.size, const Size(48, 48));
      expect(find.text('+15s'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(forward)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      await tester.tap(forward);
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.seeks, [
        const Duration(seconds: 44),
        const Duration(seconds: 59),
      ]);
      expect(fixture.platform.state.playing, isTrue);
      expect(fixture.forwardCalls, 2);
      expect(fixture.toggleCalls, 0);
      await fixture.player.seek(const Duration(seconds: 115));
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.seeks.sublist(2), [
        const Duration(seconds: 120),
        const Duration(seconds: 120),
      ]);
      await tester.tap(next);
      await tester.pump();
      expect(fixture.nextCalls, 1);
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    },
  );

  testWidgets(
    'unknown duration, final episode and loading disable transport safely',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester);
      fixture.platform.state = fixture.platform.state.copyWith(
        duration: Duration.zero,
      );
      fixture.rebuild(() => fixture.hasNext = false);
      await tester.pump();
      expect(tester.widget<GestureDetector>(forward).onTap, isNull);
      expect(tester.widget<GestureDetector>(next).onTap, isNull);
      await tester.tap(forward);
      await tester.tap(next);
      expect(fixture.seeks, isEmpty);
      expect(fixture.nextCalls, 0);
      fixture.platform.state = fixture.platform.state.copyWith(
        duration: const Duration(minutes: 2),
      );
      fixture.rebuild(() => fixture.hasNext = true);
      await tester.pump();
      expect(tester.widget<GestureDetector>(forward).onTap, isNotNull);
      expect(tester.widget<GestureDetector>(next).onTap, isNotNull);
      fixture.rebuild(() => fixture.enabled = false);
      await tester.pump();
      expect(tester.widget<GestureDetector>(forward).onTap, isNull);
      expect(tester.widget<GestureDetector>(next).onTap, isNull);
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    },
  );

  testWidgets('screen lock blocks transport taps and unlock restores them', (
    tester,
  ) async {
    final fixture = TransportFixture();
    await fixture.mount(tester);
    final jump = tester.getCenter(forward);
    final skip = tester.getCenter(next);
    await tester.tap(find.byTooltip('锁定屏幕'));
    await tester.pumpAndSettle();
    await tester.tapAt(jump);
    await tester.tapAt(skip);
    await tester.pump();
    expect(fixture.seeks, isEmpty);
    expect(fixture.nextCalls, 0);
    await tester.tap(find.byTooltip('解锁屏幕'));
    await tester.pumpAndSettle();
    await tester.tap(forward);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 44)]);
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });

  testWidgets(
    'portrait forward follows play, resumes once and preserves seek bounds',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(
        tester,
        size: const Size(390, 844),
        fullscreen: false,
      );
      final play = tester.getRect(
        find.byKey(const ValueKey('player-mobile-play')),
      );
      final jump = tester.getRect(forward);
      expect(jump.left, play.right);
      expect(jump.center.dy, play.center.dy);
      expect(jump.size, const Size(48, 48));
      expect(next, findsNothing);
      final semantics = tester.ensureSemantics();
      final data = tester.getSemantics(forward).getSemanticsData();
      expect(data.label, contains('快进15秒'));
      expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
      await tester.tap(forward);
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.seeks, [
        const Duration(seconds: 44),
        const Duration(seconds: 59),
      ]);
      expect(fixture.platform.state.playing, isTrue);
      expect(fixture.forwardCalls, 2);
      expect(fixture.toggleCalls, 0);
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.seeks.last, const Duration(seconds: 74));
      expect(fixture.platform.state.playing, isTrue);
      await fixture.player.seek(const Duration(seconds: 115));
      await fixture.player.pause();
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.seeks.sublist(3), [
        const Duration(seconds: 120),
        const Duration(seconds: 120),
      ]);
      expect(fixture.platform.state.playing, isFalse);
      expect(fixture.nextCalls, 0);
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    },
  );

  testWidgets('portrait unknown duration and loading disable forward', (
    tester,
  ) async {
    final fixture = TransportFixture();
    await fixture.mount(tester, size: const Size(390, 844), fullscreen: false);
    fixture.platform.state = fixture.platform.state.copyWith(
      duration: Duration.zero,
    );
    fixture.rebuild(() {});
    await tester.pump();
    expect(tester.widget<GestureDetector>(forward).onTap, isNull);
    await tester.tapAt(tester.getCenter(forward));
    await tester.pump(const Duration(milliseconds: 350));
    expect(fixture.seeks, isEmpty);
    expect(fixture.platform.state.playing, isFalse);
    fixture.platform.state = fixture.platform.state.copyWith(
      duration: const Duration(minutes: 2),
    );
    fixture.rebuild(() => fixture.enabled = false);
    await tester.pump();
    expect(tester.widget<GestureDetector>(forward).onTap, isNull);
    await tester.tapAt(tester.getCenter(forward));
    await tester.pump(const Duration(milliseconds: 350));
    expect(fixture.seeks, isEmpty);
    expect(fixture.platform.state.playing, isFalse);
    fixture.rebuild(() => fixture.enabled = true);
    await tester.pump();
    await tester.tap(forward);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 44)]);
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });

  testWidgets('portrait screen lock blocks forward until unlocked', (
    tester,
  ) async {
    final fixture = TransportFixture();
    await fixture.mount(tester, size: const Size(390, 844), fullscreen: false);
    final jump = tester.getCenter(forward);
    await tester.tap(find.byTooltip('锁定屏幕'));
    await tester.pumpAndSettle();
    await tester.tapAt(jump);
    await tester.pump(const Duration(milliseconds: 350));
    expect(fixture.seeks, isEmpty);
    await tester.tap(find.byTooltip('解锁屏幕'));
    await tester.pumpAndSettle();
    await tester.tap(forward);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 44)]);
    expect(fixture.platform.state.playing, isTrue);
    expect(fixture.toggleCalls, 0);
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });

  for (final playing in [false, true]) {
    testWidgets(
      'portrait hidden tap only reveals controls when playing=$playing',
      (tester) async {
        final fixture = TransportFixture();
        await fixture.mount(
          tester,
          size: const Size(390, 844),
          fullscreen: false,
          showOnPlaybackReady: false,
        );
        if (playing) {
          await fixture.player.playOrPause();
          await tester.pump();
        }
        final chrome = find.byKey(const ValueKey('player-chrome'));
        expect(tester.widget<AnimatedOpacity>(chrome).opacity, 0);
        final position = fixture.player.state.position;
        await tester.tapAt(const Offset(100, 250));
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
        expect(fixture.platform.state.playing, playing);
        expect(fixture.player.state.position, position);
        expect(fixture.toggleCalls, 0);
        expect(fixture.forwardCalls, 0);
        await tester.tapAt(const Offset(100, 250));
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.platform.state.playing, !playing);
        expect(fixture.toggleCalls, 1);
        expect(tester.takeException(), isNull);
        await fixture.unmount(tester);
      },
    );
  }

  testWidgets(
    'portrait auto-hidden forward location reveals without activating',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(
        tester,
        size: const Size(390, 844),
        fullscreen: false,
      );
      final jump = tester.getCenter(forward);
      await fixture.player.playOrPause();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      final chrome = find.byKey(const ValueKey('player-chrome'));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 0);
      await tester.tapAt(jump);
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      expect(fixture.platform.state.playing, isTrue);
      expect(fixture.seeks, isEmpty);
      expect(fixture.toggleCalls, 0);
      expect(fixture.forwardCalls, 0);
      await tester.tap(forward);
      await tester.pump();
      expect(fixture.forwardCalls, 1);
      expect(fixture.toggleCalls, 0);
      expect(fixture.seeks, [const Duration(seconds: 44)]);
      await fixture.unmount(tester);
    },
  );

  testWidgets('fullscreen surface taps keep visibility-only behavior', (
    tester,
  ) async {
    final fixture = TransportFixture();
    await fixture.mount(tester);
    await fixture.player.playOrPause();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final chrome = find.byKey(const ValueKey('player-chrome'));
    expect(tester.widget<AnimatedOpacity>(chrome).opacity, 0);
    for (final opacity in [1.0, 0.0]) {
      await tester.tapAt(const Offset(350, 200));
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, opacity);
      expect(fixture.platform.state.playing, isTrue);
      expect(fixture.toggleCalls, 0);
    }
    await fixture.unmount(tester);
  });

  testWidgets(
    'TV remote keeps play, forward and next focus order and actions',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester);
      await tester.pumpWidget(
        televisionHost(
          child: Scaffold(
            body: TelevisionControls(
              player: fixture.player,
              title: '合成视频 · 第 1 集',
              enabled: true,
              showOnPlaybackReady: true,
              onTogglePlayback: fixture.player.playOrPause,
              onSeek: (_) {},
              onSeekTo: (target) async {
                fixture.seeks.add(target);
                await fixture.player.seek(target);
              },
              onPrevious: null,
              onNext: () => fixture.nextCalls++,
              onEpisodes: () async {},
              onSettings: () async {},
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focusRemote(tester, find.byKey(const ValueKey('tv-play-pause')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-forward',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 250));
      expect(fixture.seeks, [const Duration(seconds: 44)]);
      expect(fixture.platform.state.playing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-next');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(fixture.nextCalls, 1);
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    },
  );

  for (final size in [const Size(960, 540), const Size(390, 844)]) {
    testWidgets('fullscreen transport renders without overflow at $size', (
      tester,
    ) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, size: size);
      final play = tester.getRect(
        find.byKey(const ValueKey('player-mobile-play')),
      );
      expect(tester.getRect(forward).left, play.right);
      expect(tester.getRect(next).left, tester.getRect(forward).right);
      expect(tester.getRect(next).right, lessThan(size.width));
      final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
      if (directory != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('transport-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$directory/fullscreen-transport-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    });
  }
}
