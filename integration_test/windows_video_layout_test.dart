import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/video_enhancement_preferences.dart';
import 'package:duanju_app/windows_desktop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixtures.dart';

class LayoutRepository extends FixtureRepository {
  LayoutRepository(this.path);
  final String path;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan(url: Uri.file(path).toString(), local: true);
}

List<double> rectangle(Rect rect) => [
  rect.left,
  rect.top,
  rect.width,
  rect.height,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Windows video geometry and pixels across window modes', (
    tester,
  ) async {
    expect(Platform.isWindows, true);
    expect(const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'), true);
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(360, 240));
    await windowManager.setSize(const Size(1200, 800));
    await windowManager.show();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final desktop = WindowsDesktop(preferences);
    await desktop.initialize();
    WindowsDesktop.current = desktop;
    final directory = Directory(
      Platform.environment['HG_VIDEO_LAYOUT_CAPTURE_DIR'] ??
          '${Directory.systemTemp.path}/hongguo-video-layout',
    );
    await directory.create(recursive: true);
    final samples = <Map<String, Object?>>[];
    final failures = <String>[];
    final boundaryKey = GlobalKey();
    final executor = FFmpegExecutor();

    Future<void> until(bool Function() ready, String phase) async {
      final watch = Stopwatch()..start();
      while (!ready()) {
        if (watch.elapsed > const Duration(seconds: 35)) fail(phase);
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> capture(
      String name,
      Size source, {
      required bool hidden,
      bool bakedBottom = false,
    }) async {
      final videoFinder = find.byType(Video);
      final video = tester.widget<Video>(videoFinder);
      final pane = tester.getRect(videoFinder);
      final fitted = applyBoxFit(BoxFit.contain, source, pane.size);
      final expected = Alignment.center.inscribe(fitted.destination, pane);
      final textures = find.descendant(
        of: videoFinder,
        matching: find.byType(Texture),
      );
      final texture = tester.getRect(textures.first);
      for (final delta in [
        texture.left - expected.left,
        texture.top - expected.top,
        texture.right - expected.right,
        texture.bottom - expected.bottom,
      ]) {
        if (delta.abs() > 2) failures.add('$name texture geometry $delta');
      }
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final origin = boundary.localToGlobal(Offset.zero);
      final image = await boundary.toImage(pixelRatio: 1);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(png.buffer.asUint8List());
      Rect? pixels;
      if (hidden) {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final bytes = data.buffer.asUint8List();
        var left = image.width, top = image.height, right = -1, bottom = -1;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final offset = (y * image.width + x) * 4;
            if (bytes[offset] < 155 &&
                bytes[offset + 1] > 175 &&
                bytes[offset + 2] > 195) {
              if (x < left) left = x;
              if (x > right) right = x;
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
        }
        pixels = Rect.fromLTRB(
          left.toDouble(),
          top.toDouble(),
          (right + 1).toDouble(),
          (bottom + 1).toDouble(),
        ).shift(origin);
        final expectedPixels = bakedBottom
            ? Rect.fromLTWH(
                expected.left,
                expected.top,
                expected.width,
                expected.height * 15 / 16,
              )
            : expected;
        for (final delta in [
          pixels.left - expectedPixels.left,
          pixels.top - expectedPixels.top,
          pixels.right - expectedPixels.right,
          pixels.bottom - expectedPixels.bottom,
        ]) {
          if (delta.abs() > 3) failures.add('$name decoded pixels $delta');
        }
      }
      final query = MediaQuery.of(tester.element(videoFinder));
      samples.add({
        'name': name,
        'source': [source.width, source.height],
        'pane': rectangle(pane),
        'expected': rectangle(expected),
        'texture': rectangle(texture),
        'decodedPixels': pixels == null ? null : rectangle(pixels),
        'textureSize': video.controller.rect.value?.toString(),
        'padding': query.padding.toString(),
        'viewInsets': query.viewInsets.toString(),
        'devicePixelRatio': query.devicePixelRatio,
        'fullscreen': desktop.fullscreen,
        'mini': desktop.mini,
        'controlsHidden': hidden,
        'sourceContainsBottomBlack': bakedBottom,
      });
      image.dispose();
      await File(
        '${directory.path}/layout.json',
      ).writeAsString(jsonEncode({'samples': samples, 'failures': failures}));
    }

    try {
      for (final fixture in {
        'landscape': const Size(1280, 720),
        'portrait': const Size(720, 1280),
        'wide': const Size(1920, 800),
        'baked-bottom': const Size(1280, 720),
      }.entries) {
        final path = '${directory.path}/${fixture.key}.mp4';
        await executor.run([
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=0x6BCADE:s=${fixture.value.width.toInt()}x${fixture.value.height.toInt()}:r=10',
          if (fixture.key == 'baked-bottom') ...[
            '-vf',
            'drawbox=x=0:y=ih*15/16:w=iw:h=ih/16:color=black:t=fill',
          ],
          '-t',
          '120',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-threads',
          '1',
          '-pix_fmt',
          'yuv420p',
          path,
        ]);
        for (final enhancement in [
          VideoEnhancementMode.off,
          VideoEnhancementMode.economy,
        ]) {
          final store = LocalStore(preferences);
          await store.setPlaybackPreferences(
            store.playbackPreferences.copyWith(
              danmaku: false,
              autoAdvance: false,
              preload: false,
              enhancement: VideoEnhancementPreferences(mode: enhancement),
            ),
          );
          final player = Player(
            configuration: const PlayerConfiguration(muted: true),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              home: RepaintBoundary(
                key: boundaryKey,
                child: PlayerScreen(
                  detail: DramaDetail(
                    Drama(
                      id: fixture.key,
                      source: 'layout',
                      title: fixture.key,
                    ),
                    [
                      Episode({'id': '1'}, 1),
                    ],
                  ),
                  initialIndex: 0,
                  repository: LayoutRepository(path),
                  store: store,
                  playerFactory: () => player,
                ),
              ),
            ),
          );
          await until(
            () =>
                find.byType(Video).evaluate().isNotEmpty &&
                player.state.position.inMilliseconds > 400 &&
                find.byType(Texture).evaluate().isNotEmpty,
            'video ready ${fixture.key}',
          );
          for (final mode in ['window', 'fullscreen', 'mini']) {
            if (mode == 'fullscreen') await desktop.setFullscreen(true);
            if (mode == 'mini')
              await desktop.enterMini(aspectRatio: fixture.value.aspectRatio);
            await tester.pump(const Duration(seconds: 1));
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(
              location: tester.getCenter(find.byType(Video)),
            );
            await mouse.moveBy(const Offset(1, 0));
            await tester.pump(const Duration(milliseconds: 200));
            final prefix = '${fixture.key}-${enhancement.name}-$mode';
            await capture('$prefix-shown', fixture.value, hidden: false);
            await mouse.removePointer();
            await tester.pump(const Duration(seconds: 2));
            await until(
              () =>
                  tester
                      .widget<AnimatedOpacity>(
                        find.byKey(const ValueKey('player-chrome')),
                      )
                      .opacity ==
                  0,
              'controls hidden $prefix',
            );
            await tester.pump(const Duration(milliseconds: 250));
            await capture(
              '$prefix-hidden',
              fixture.value,
              hidden: true,
              bakedBottom: fixture.key == 'baked-bottom',
            );
          }
          await desktop.leaveMini();
          await desktop.setFullscreen(false);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 300));
          await desktop.playbackDisposal;
          await store.flushPendingWrites();
          store.dispose();
        }
      }
      expect(failures, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      WindowsDesktop.current = null;
      desktop.dispose();
      await windowManager.setPreventClose(false);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
