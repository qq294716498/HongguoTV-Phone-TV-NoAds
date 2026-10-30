import 'dart:async';
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
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixtures.dart';
import 'windows_video_pixels.dart';

class LayoutRepository extends FixtureRepository {
  LayoutRepository(this.path, {required this.beforeResolve});
  final String path;
  final Future<void> beforeResolve;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    await beforeResolve;
    return PlaybackPlan(url: Uri.file(path).toString(), local: true);
  }
}

List<double> rectangle(Rect rect) => [
  rect.left,
  rect.top,
  rect.width,
  rect.height,
];

List<String> geometryChainFailures(Map<String, Object?> sample) {
  final failures = <String>[];
  final native = sample['native'] as Map;
  if (native['geometryAvailable'] != true)
    return ['native geometry unavailable'];
  Rect rect(Object? value) {
    final values = (value as List).cast<num>();
    return Rect.fromLTWH(
      values[0].toDouble(),
      values[1].toDouble(),
      values[2].toDouble(),
      values[3].toDouble(),
    );
  }

  void same(Rect actual, Rect expected, String stage) {
    if ([
      actual.left - expected.left,
      actual.top - expected.top,
      actual.right - expected.right,
      actual.bottom - expected.bottom,
    ].any((delta) => delta.abs() > 2)) {
      failures.add('$stage actual=$actual expected=$expected');
    }
  }

  final client = rect(native['clientBounds']);
  same(
    rect(native['flutterChildClientBounds']),
    client,
    'Flutter child client',
  );
  final physical = (sample['viewPhysicalSize'] as List).cast<num>();
  same(
    Rect.fromLTWH(0, 0, physical[0].toDouble(), physical[1].toDouble()),
    Offset.zero & client.size,
    'Flutter physical view',
  );
  final dpr = (sample['devicePixelRatio'] as num).toDouble();
  final dpi = native['dpi'] as num;
  if (dpi > 0 && (dpi / 96 - dpr).abs() > .01)
    failures.add('native DPI / Flutter DPR mismatch');
  final logical = Rect.fromLTWH(0, 0, physical[0] / dpr, physical[1] / dpr);
  same(rect(sample['page']), logical, 'Flutter page');
  same(rect(sample['scaffold']), logical, 'Scaffold');
  if (sample['fullscreen'] == true) {
    same(client, rect(native['monitorBounds']), 'fullscreen client / monitor');
    same(rect(sample['pane']), logical, 'fullscreen video viewport');
  }
  return failures;
}

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
      final native = await desktop.channel.invokeMapMethod<String, dynamic>(
        'windowGeometry',
      );
      expect(native, isNotNull);
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
        pixels = syntheticVideoBounds(
          data.buffer.asUint8List(),
          image.width,
          image.height,
        )?.shift(origin);
        final expectedPixels = bakedBottom
            ? Rect.fromLTWH(
                expected.left,
                expected.top,
                expected.width,
                expected.height * 15 / 16,
              )
            : expected;
        failures.addAll(
          decodedVideoPixelFailures(
            pixels,
            expectedPixels,
          ).map((failure) => '$name $failure'),
        );
      }
      final query = MediaQuery.of(tester.element(videoFinder));
      final view = View.of(tester.element(videoFinder));
      final platform = video.controller.player.platform! as NativePlayer;
      final decoder = <String, String>{};
      for (final property in [
        'mpv-version',
        'ffmpeg-version',
        'hwdec',
        'hwdec-current',
        'gpu-hwdec-interop',
        'current-vo',
        'video-codec',
        'video-params',
        'video-dec-params',
        'video-out-params',
      ]) {
        try {
          final value = await platform.getProperty(property);
          decoder[property] = value.isEmpty ? '<unavailable>' : value;
        } catch (error) {
          decoder[property] = '<unavailable: $error>';
        }
      }
      final sample = <String, Object?>{
        'name': name,
        'source': [source.width, source.height],
        'pane': rectangle(pane),
        'expected': rectangle(expected),
        'texture': rectangle(texture),
        'decodedPixels': pixels == null ? null : rectangle(pixels),
        'textureSize': video.controller.rect.value?.toString(),
        'decoder': decoder,
        'padding': query.padding.toString(),
        'viewInsets': query.viewInsets.toString(),
        'devicePixelRatio': query.devicePixelRatio,
        'viewPhysicalSize': [view.physicalSize.width, view.physicalSize.height],
        'viewPadding': [
          view.padding.left,
          view.padding.top,
          view.padding.right,
          view.padding.bottom,
        ],
        'page': rectangle(tester.getRect(find.byKey(boundaryKey))),
        'scaffold': rectangle(tester.getRect(find.byType(Scaffold))),
        'controlsRect': rectangle(
          tester.getRect(find.byKey(const ValueKey('player-chrome'))),
        ),
        'native': native,
        'fullscreen': desktop.fullscreen,
        'mini': desktop.mini,
        'controlsHidden': hidden,
        'sourceContainsBottomBlack': bakedBottom,
      };
      failures.addAll(
        geometryChainFailures(sample).map((failure) => '$name $failure'),
      );
      if (name.contains('-restored-maximized-')) {
        if (native!['maximized'] != true)
          failures.add('$name maximized state not restored');
        if (native['captionButtons'] != true ||
            (native['captionInset'] as num) <= 0)
          failures.add('$name normal native caption not restored');
      }
      if (hidden) {
        final shown = samples.last;
        for (final field in [
          'pane',
          'page',
          'scaffold',
          'controlsRect',
          'viewPhysicalSize',
        ]) {
          if (!listEquals(sample[field] as List, shown[field] as List))
            failures.add('$name controls visibility changed $field');
        }
      }
      samples.add(sample);
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
        'landscape-1080': const Size(1920, 1080),
        'portrait-1080': const Size(1080, 1920),
        'unaligned-width': const Size(854, 480),
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
          final sourceReady = Completer<void>();
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
                  repository: LayoutRepository(
                    path,
                    beforeResolve: sourceReady.future,
                  ),
                  store: store,
                  playerFactory: () => player,
                ),
              ),
            ),
          );
          await until(
            () => find.byType(Video).evaluate().isNotEmpty,
            'video controller created ${fixture.key}',
          );
          const requestedDecoder = String.fromEnvironment(
            'WINDOWS_VIDEO_HWDEC',
          );
          final native = player.platform! as NativePlayer;
          if (requestedDecoder.isNotEmpty) {
            await native.setProperty('hwdec', requestedDecoder);
            expect(await native.getProperty('hwdec'), requestedDecoder);
          } else {
            expect(await native.getProperty('hwdec'), 'auto');
          }
          sourceReady.complete();
          await until(
            () =>
                player.state.position.inMilliseconds > 400 &&
                find.byType(Texture).evaluate().isNotEmpty,
            'video ready ${fixture.key}',
          );
          final unaligned =
              fixture.key.contains('1080') || fixture.key == 'unaligned-width';
          for (final mode in [
            'window',
            'fullscreen-window',
            if (!unaligned) ...['maximized', 'fullscreen-maximized'],
            'mini',
            'restored-fullscreen',
            if (unaligned) 'restored-window' else 'restored-maximized',
          ]) {
            if (mode == 'maximized') {
              await desktop.setFullscreen(false);
              await windowManager.maximize();
            }
            if (mode == 'fullscreen-window' || mode == 'fullscreen-maximized')
              await desktop.setFullscreen(true);
            if (mode == 'mini') {
              await desktop.enterMini(aspectRatio: fixture.value.aspectRatio);
            }
            if (mode == 'restored-fullscreen') await desktop.leaveMini();
            if (mode == 'restored-maximized' || mode == 'restored-window')
              await desktop.setFullscreen(false);
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
          await windowManager.unmaximize();
          await windowManager.setSize(const Size(1200, 800));
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
  }, timeout: const Timeout(Duration(minutes: 15)));
}
