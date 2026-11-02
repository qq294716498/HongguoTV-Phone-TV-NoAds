import 'dart:async';
import 'dart:ui' as ui;

import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fixtures.dart';
import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;
import 'player_fixtures.dart' show mockPlayerDevice;

class _ExitPositionPlatform extends DiagnosticVideoPlatform {
  Duration position = const Duration(milliseconds: 300);

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
  }
}

class _ExitPlaybackRepository extends FixtureRepository {
  final active = <String>{};
  final danmakuEpisodes = <String>[];

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final session = 'exit-episode-${episode.number}';
    active.add(session);
    return PlaybackPlan(
      url: 'file:///synthetic-$session.mp4',
      session: session,
      danmakuId: 'e${episode.number}',
    );
  }

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    danmakuEpisodes.add(plan.danmakuId);
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: (startMs + 30000).clamp(0, durationMs),
      items: [
        DanmakuItem(
          id: 'same-item',
          text: '${plan.danmakuId} flight',
          timeMs: startMs,
        ),
      ],
    );
  }

  @override
  Future<void> release(String session) async {
    active.remove(session);
  }
}

Future<Uint8List> _retainedFrameBytes() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 18);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List frameBytes;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    frameBytes = await _retainedFrameBytes();
  });

  Finder retiring() => find.byWidgetPredicate(
    (widget) =>
        widget is Transform &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'danmaku-exit-motion-',
        ),
  );

  double x(WidgetTester tester, Finder motion) =>
      tester.widget<Transform>(motion).transform.storage[12];

  for (final origin in ['manual', 'automatic']) {
    testWidgets(
      '$origin PlayerScreen switch keeps old danmaku while the same video controller loads',
      (tester) async {
        mockPlayerDevice();
        final previous = VideoPlayerPlatform.instance;
        final platform = _ExitPositionPlatform();
        VideoPlayerPlatform.instance = platform;
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        SharedPreferences.setMockInitialValues({});
        final store = testStore(await SharedPreferences.getInstance());
        await store.setPlaybackPreferences(
          const PlaybackPreferences(preload: false),
        );
        final repository = _ExitPlaybackRepository();
        final player = LunaExoPlayer();
        final pending = Completer<Map<String, Object>>();
        final firstFramePending = Completer<Map<String, Object>>();
        var transitions = 0;
        var captures = 0;
        messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
          call,
        ) {
          if (call.method == 'captureFrame') {
            captures++;
            return Future.value(frameBytes);
          }
          if (call.method == 'transition') {
            transitions++;
            return pending.future;
          }
          if (call.method == 'waitForFirstFrame') {
            return firstFramePending.future;
          }
          return Future.value(<String, Object>{});
        });
        Future<void> pumpSteps(int count) async {
          for (var i = 0; i < count; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              home: PlayerScreen(
                detail: await repository.detail(FixtureRepository.free),
                initialIndex: 0,
                repository: repository,
                store: store,
                playerFactory: () => player,
                videoBuilder: (controls) =>
                    ColoredBox(color: Colors.blueGrey, child: controls),
              ),
            ),
          );
          await pumpSteps(20);
          final native = player.controller!;
          native.value = native.value.copyWith(
            position: platform.position,
            buffered: [DurationRange(Duration.zero, native.value.duration)],
          );
          await pumpSteps(10);
          await tester.pump(const Duration(milliseconds: 700));
          final live = find.byKey(const ValueKey('danmaku-motion-same-item'));
          expect(live, findsOneWidget);
          final overlayState = tester.state(find.byType(DanmakuOverlay));
          final before = x(tester, live);
          if (origin == 'manual') {
            await tester.tap(find.byKey(const ValueKey('player-mobile-next')));
          } else {
            platform.position = native.value.duration;
            native.value = native.value.copyWith(
              position: native.value.duration,
            );
            platform.streams[native.playerId]!.add(
              VideoEvent(eventType: VideoEventType.completed),
            );
          }
          await tester.pump();
          expect(retiring(), findsOneWidget);
          expect(x(tester, retiring()), closeTo(before, .1));
          expect(tester.state(find.byType(DanmakuOverlay)), same(overlayState));
          await pumpSteps(5);
          if (origin == 'automatic') {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            });
            await pumpSteps(10);
          }
          expect(transitions, 1);
          expect(platform.created, 1);
          expect(player.controller, same(native));
          expect(pending.isCompleted, isFalse);
          if (origin == 'automatic') {
            expect(captures, 1);
            expect(player.frameHold.active, isTrue);
            expect(
              tester.state(find.byType(DanmakuOverlay)),
              same(overlayState),
            );
          }
          final first = x(tester, retiring());
          await tester.pump(const Duration(milliseconds: 200));
          expect(x(tester, retiring()), lessThan(first));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(retiring(), findsNothing);
          expect(pending.isCompleted, isFalse);
          expect(player.controller, same(native));
          platform.position = Duration.zero;
          pending.complete({
            'durationMs': 90000,
            'width': 1920,
            'height': 1080,
            'elapsedMs': 650,
            'firstFrame': origin != 'automatic',
            if (origin == 'automatic') 'transitionGeneration': 7,
          });
          await pumpSteps(20);
          expect(player.controller, same(native));
          expect(platform.created, 1);
          expect(repository.danmakuEpisodes, contains('e2'));
          expect(find.text('e1 flight'), findsNothing);
          var overlay = tester.widget<DanmakuOverlay>(
            find.byType(DanmakuOverlay),
          );
          expect(overlay.controller.positionMs, lessThan(1000));
          expect(overlay.controller.items.single.text, 'e2 flight');
          if (origin == 'automatic') {
            expect(player.frameHold.active, isTrue);
            expect(overlay.currentVisible, isFalse);
            expect(find.text('e2 flight'), findsNothing);
            player.clearRetainedFrame();
            firstFramePending.complete({'firstFrame': true, 'generation': 7});
            await tester.pump();
            await tester.pump();
            overlay = tester.widget<DanmakuOverlay>(
              find.byType(DanmakuOverlay),
            );
            expect(overlay.currentVisible, isTrue);
            expect(
              tester.state(find.byType(DanmakuOverlay)),
              same(overlayState),
            );
          }
          expect(find.text('e2 flight'), findsOneWidget);
          expect(retiring(), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          if (!pending.isCompleted) {
            pending.complete({
              'durationMs': 90000,
              'width': 1920,
              'height': 1080,
              'elapsedMs': 0,
              'firstFrame': true,
            });
          }
          if (!firstFramePending.isCompleted) {
            firstFramePending.complete({'firstFrame': true, 'generation': 7});
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpSteps(10);
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await pumpSteps(5);
          await player.dispose();
          store.dispose();
          messenger.setMockMethodCallHandler(
            LunaExoPlayer.diagnosticChannel,
            null,
          );
          VideoPlayerPlatform.instance = previous;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
