import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/lan_controller.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_interactions.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  setUp(mockPlayerDevice);
  testWidgets(
    'taps, jitter and holding never adjust brightness; holding restores selected speed',
    (tester) async {
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      await player.setRate(1.25);
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1.25,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (_) => '',
      );
      await tester.pump();
      interactions.pointerDown(
        const PointerDownEvent(
          pointer: 1,
          position: Offset(30, 180),
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
        ),
        swipeEnabled: true,
        width: 390,
        height: 400,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(interactions.hudState.type, SwipeAction.none);
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 1, position: Offset(34, 184)),
      );
      expect(interactions.hudState.type, SwipeAction.none);
      interactions.pointerUp(
        const PointerUpEvent(pointer: 1, position: Offset(34, 184)),
      );
      expect(platform.state.rate, 1.25);
      interactions.pointerDown(
        const PointerDownEvent(
          pointer: 2,
          position: Offset(30, 180),
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
        ),
        swipeEnabled: true,
        width: 390,
        height: 400,
      );
      await tester.pump(const Duration(milliseconds: 410));
      await interactions.pendingRates;
      expect(platform.state.rate, 2);
      expect(interactions.hudState.type, SwipeAction.none);
      expect(interactions.boosting, isTrue);
      interactions.pointerUp(
        const PointerUpEvent(pointer: 2, position: Offset(30, 180)),
      );
      await tester.pump();
      await interactions.pendingRates;
      expect(platform.state.rate, 1.25);
      expect(interactions.boosting, isFalse);
      interactions.dispose();
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'intentional fullscreen side swipes control brightness and volume; seek commits only on release',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        if (call.method == 'getMediaVolume') return .8;
        if (call.method == 'setMediaVolume')
          return (call.arguments as Map)['volume'];
        if (call.method == 'getBrightness') return .5;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      await player.seek(const Duration(seconds: 30));
      final seeks = <Duration>[];
      var episodes = 0;
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (direction) {
          episodes += direction;
          return '';
        },
        onSeek: (position) async {
          seeks.add(position);
        },
      );
      await tester.pump();
      void down(int pointer, Offset at) => interactions.pointerDown(
        PointerDownEvent(
          pointer: pointer,
          position: at,
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
        ),
        swipeEnabled: true,
        fullscreen: true,
        width: 390,
        height: 400,
      );
      down(1, const Offset(70, 200));
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 1, position: Offset(70, 190)),
      );
      expect(interactions.hudState.type, SwipeAction.none);
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 1, position: Offset(70, 150)),
      );
      expect(interactions.hudState.type, SwipeAction.brightness);
      expect(interactions.brightness, greaterThan(.5));
      interactions.pointerUp(
        const PointerUpEvent(pointer: 1, position: Offset(70, 150)),
      );
      down(2, const Offset(320, 200));
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 2, position: Offset(320, 270)),
      );
      await tester.pump();
      expect(interactions.hudState.type, SwipeAction.volume);
      expect(platform.state.volume, 100);
      expect(interactions.hudState.value, lessThan(.8));
      interactions.pointerUp(
        const PointerUpEvent(pointer: 2, position: Offset(320, 270)),
      );
      down(3, const Offset(180, 180));
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 3, position: Offset(245, 180)),
      );
      expect(seeks, isEmpty);
      expect(interactions.hudState.type, SwipeAction.seek);
      interactions.pointerUp(
        const PointerUpEvent(pointer: 3, position: Offset(245, 180)),
      );
      expect(seeks, [const Duration(seconds: 50)]);
      down(4, const Offset(180, 200));
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 4, position: Offset(180, 110)),
      );
      interactions.pointerUp(
        const PointerUpEvent(
          pointer: 4,
          position: Offset(180, 110),
          timeStamp: Duration(milliseconds: 100),
        ),
      );
      expect(episodes, 0);
      down(5, const Offset(180, 180));
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 5, position: Offset(245, 180)),
      );
      interactions.pointerCancel(const PointerCancelEvent(pointer: 5));
      expect(seeks.length, 1);
      interactions.dispose();
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<ThemeData> previewTheme(WidgetTester tester) async {
    final font = Platform.environment['HG_UI_FONT'];
    if (font == null) return AppTheme.dark;
    await tester.runAsync(() async {
      final icons = Platform.environment['HG_UI_ICON_FONT'];
      if (icons != null) {
        final data = await File(icons).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(data)))).load();
      }
      final data = await File(font).readAsBytes();
      await (FontLoader(
        'UiPreviewCJK',
      )..addFont(Future.value(ByteData.sublistView(data)))).load();
    });
    return AppTheme.dark.copyWith(
      textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'UiPreviewCJK'),
    );
  }

  for (final size in [
    const Size(320, 800),
    const Size(390, 844),
    const Size(960, 540),
  ]) {
    testWidgets(
      'mobile controls place danmaku above video and fullscreen before play at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        final link = LanController(FixtureRepository(), store, kind: 'mobile');
        LanController.current = link;
        final platform = ScriptedPlayer();
        final player = Player(platformPlayer: platform);
        await player.open(Media('https://example.test/synthetic.mp4'));
        var fullscreen = 0;
        var danmaku = 0;
        final interactions = PlayerInteractions(
          player: player,
          available: () => true,
          baseSpeed: () => 1,
          onTogglePlayback: () => player.playOrPause(),
          onFullscreen: () => fullscreen++,
          onEpisode: (_) => '',
        );
        final theme = await previewTheme(tester);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('capture'),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ColoredBox(
                            color: const Color(0xFF243A4C),
                            child: const Center(child: Text('合成视频画面')),
                          ),
                        ),
                      ),
                      PlayerControls(
                        player: player,
                        interactions: interactions,
                        enabled: true,
                        fullscreen: size.width > size.height,
                        showOnPlaybackReady: true,
                        swipeEnabled: true,
                        showDanmaku: true,
                        danmakuEnabled: true,
                        title: '这是一部名称特别长的合成短剧标题用来验证集数不会被挤掉',
                        episodeLabel: '第 22 集',
                        speed: 1,
                        qualityLabel: '自动',
                        onFullscreen: () => fullscreen++,
                        onBack: () {},
                        onPrevious: null,
                        onNext: null,
                        onFocusSurface: () {},
                        onTogglePlayback: () => player.playOrPause(),
                        onForward: () => interactions.seek(15),
                        onEpisodes: () async {},
                        onSpeed: () async {},
                        onQuality: () async {},
                        onDanmaku: () async => danmaku++,
                        onPush: () async {},
                        onPictureInPicture: () async {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('player-danmaku-toggle'));
        final expand = find.byKey(const ValueKey('player-fullscreen'));
        final play = find.byKey(const ValueKey('player-mobile-play'));
        final a = tester.getRect(expand);
        final b = tester.getRect(play);
        expect(a.right, lessThanOrEqualTo(b.left));
        expect(a.center.dy, b.center.dy);
        final forward = find.byKey(const ValueKey('player-mobile-forward'));
        final next = find.byKey(const ValueKey('player-mobile-next'));
        expect(tester.getRect(forward).left, b.right);
        expect(tester.getRect(forward).center.dy, b.center.dy);
        expect(tester.getRect(forward).size, const Size(48, 48));
        if (size.width > size.height) {
          expect(tester.getRect(next).left, tester.getRect(forward).right);
        } else {
          expect(next, findsNothing);
        }
        final speed = tester.getRect(
          find.byKey(const ValueKey('player-speed')),
        );
        final pictureInPicture = tester.getRect(
          find.byKey(const ValueKey('player-picture-in-picture')),
        );
        expect(pictureInPicture.right, lessThanOrEqualTo(size.width));
        expect(
          speed.center.dy,
          size.width < 348 ? greaterThan(b.center.dy) : b.center.dy,
        );
        expect(tester.getRect(toggle).bottom, lessThan(100));
        final header = tester.widget<Text>(
          find.byKey(const ValueKey('player-header-title')),
        );
        expect(header.style!.color, Colors.white);
        expect(header.style!.fontWeight, FontWeight.w700);
        final episode = find.byKey(const ValueKey('player-header-episode'));
        expect(tester.widget<Text>(episode).data, '第 22 集');
        expect(
          tester.getRect(episode).top,
          greaterThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('player-header-title')))
                .bottom,
          ),
        );
        if (size.width < size.height) {
          final videoTop = (size.height - size.width * 9 / 16) / 2;
          expect(tester.getRect(toggle).bottom, lessThan(videoTop));
        }
        expect(tester.takeException(), isNull);
        await capture(tester, 'mobile-controls-${size.width.toInt()}');
        await tester.tap(toggle);
        await tester.pump();
        expect(danmaku, 1);
        await tester.tap(expand);
        await tester.pump();
        expect(fullscreen, 1);
        await tester.tap(play);
        await tester.pump();
        expect(platform.state.playing, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        interactions.dispose();
        await player.dispose();
        LanController.current = null;
        link.dispose();
        store.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile tap, double tap and screen lock work without brightness interference',
    (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      await player.seek(const Duration(seconds: 30));
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1.25,
        onTogglePlayback: () => player.playOrPause(),
        onFullscreen: () {},
        onEpisode: (_) => '',
      );
      final theme = await previewTheme(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: ColoredBox(
                color: const Color(0xFF10131D),
                child: PlayerControls(
                  player: player,
                  interactions: interactions,
                  enabled: true,
                  fullscreen: false,
                  showOnPlaybackReady: true,
                  swipeEnabled: true,
                  title: '暗夜归途 · 第 12 集',
                  speed: 1.25,
                  qualityLabel: '1080p',
                  onFullscreen: () {},
                  onBack: () {},
                  onPrevious: () {},
                  onNext: () {},
                  onFocusSurface: () {},
                  onTogglePlayback: () => player.playOrPause(),
                  onForward: () => interactions.seek(15),
                  onEpisodes: () async {},
                  onSpeed: () async {},
                  onQuality: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'mobile-controls');
      await tester.tapAt(const Offset(50, 180));
      await tester.pump(const Duration(milliseconds: 350));
      expect(platform.state.playing, isFalse);
      expect(interactions.hudState.type, SwipeAction.none);
      await tester.tap(find.byKey(const ValueKey('player-mobile-play')));
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(180, 180));
      await tester.pump(const Duration(milliseconds: 450));
      await interactions.pendingRates;
      expect(platform.state.rate, 2);
      await tester.pump(const Duration(milliseconds: 220));
      final hint = tester.getRect(
        find.byKey(const ValueKey('player-mobile-feedback')),
      );
      expect(hint.bottom, greaterThan(650));
      expect(hint.height, lessThan(24));
      await capture(tester, 'mobile-hold');
      await gesture.up();
      await tester.pump();
      await interactions.pendingRates;
      expect(platform.state.rate, 1.25);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(platform.state.playing, isTrue);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('player-chrome')),
            )
            .opacity,
        0,
      );
      expect(find.text('恢复 1.25 倍速'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-mobile-feedback')),
        findsNothing,
      );
      await tester.tapAt(const Offset(180, 180));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('锁定屏幕'));
      await tester.pumpAndSettle();
      final before = platform.state.playing;
      await tester.tapAt(const Offset(50, 180));
      await tester.pump(const Duration(milliseconds: 350));
      expect(platform.state.playing, before);
      expect(find.byTooltip('解锁屏幕'), findsOneWidget);
      await tester.tap(find.byTooltip('解锁屏幕'));
      await tester.pump();
      await player.seek(const Duration(seconds: 30));
      await tester.tapAt(const Offset(355, 180));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(355, 180));
      await tester.pump(const Duration(milliseconds: 200));
      expect(platform.state.position, const Duration(seconds: 45));
      await tester.pumpWidget(const SizedBox.shrink());
      interactions.dispose();
      await player.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile fullscreen holding never turns release into a delayed single tap',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () => player.playOrPause(),
        onFullscreen: () {},
        onEpisode: (_) => '',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: PlayerControls(
              player: player,
              interactions: interactions,
              enabled: true,
              fullscreen: true,
              showOnPlaybackReady: true,
              swipeEnabled: true,
              title: '合成测试视频',
              speed: 1,
              qualityLabel: '1080p',
              onFullscreen: () {},
              onBack: () {},
              onPrevious: null,
              onNext: null,
              onFocusSurface: () {},
              onTogglePlayback: () => player.playOrPause(),
              onForward: () => interactions.seek(15),
              onEpisodes: () async {},
              onSpeed: () async {},
              onQuality: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final milliseconds in [410, 900]) {
        final gesture = await tester.startGesture(const Offset(480, 200));
        await tester.pump(Duration(milliseconds: milliseconds));
        await interactions.pendingRates;
        expect(platform.state.rate, 2);
        await gesture.up();
        await interactions.pendingRates;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(platform.state.rate, 1);
        expect(platform.state.playing, isTrue);
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('player-chrome')),
              )
              .opacity,
          0,
        );
        expect(
          find.byKey(const ValueKey('player-mobile-feedback')),
          findsNothing,
        );
      }
      await tester.tapAt(const Offset(480, 200));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('player-chrome')),
            )
            .opacity,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      interactions.dispose();
      await player.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV holds preview one target and commits once while paused; controls restore focus',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      await player.seek(const Duration(seconds: 20));
      final seeks = <Duration>[];
      final theme = await previewTheme(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: TelevisionControls(
                player: player,
                title: '暗夜归途 · 第 12 集',
                enabled: true,
                showOnPlaybackReady: true,
                speed: 1.25,
                qualityLabel: '1080p',
                onTogglePlayback: () => player.playOrPause(),
                onSeek: (_) {},
                onSeekTo: (target) async {
                  seeks.add(target);
                  await player.seek(target);
                },
                onPrevious: () {},
                onNext: () {},
                onEpisodes: () async {},
                onSettings: () async {},
                onBack: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'tv-controls');
      await player.pause();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      expect(seeks, isEmpty);
      expect(find.byKey(const ValueKey('tv-seek-preview')), findsOneWidget);
      await capture(tester, 'tv-seeking');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks, [const Duration(seconds: 65)]);
      expect(platform.state.playing, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('tv-play-pause')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(platform.state.playing, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
