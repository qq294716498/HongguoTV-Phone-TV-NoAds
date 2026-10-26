import 'dart:async';

import 'package:duanju_app/luna_exo_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart' show mockPlayerDevice;
import 'playback_preloader_test.dart' show PendingPreloadRepository;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;

class TransitionRepository extends FixtureRepository {
  final active = <String>{};
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final session = 'episode-${episode.number}';
    active.add(session);
    return PlaybackPlan(
      url: 'file:///synthetic-$session.mp4',
      session: session,
    );
  }

  @override
  Future<void> release(String session) async {
    active.remove(session);
  }
}

class PreparedTransitionRepository extends TransitionRepository {
  int resolutions = 0;
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) {
    resolutions++;
    return super.resolve(drama, episode, quality: quality);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    final session = 'episode-${episode.number}';
    active.add(session);
    return PlaybackPlan(
      url: 'file:///synthetic-$session.mp4',
      session: session,
      preloadState: 'caching',
      startupReady: true,
      mediaType: 'mp4',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DiagnosticVideoPlatform platform;
  late VideoPlayerPlatform previous;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const response = {
    'durationMs': 90000,
    'width': 1280,
    'height': 720,
    'elapsedMs': 120,
  };
  setUp(() {
    mockPlayerDevice();
    previous = VideoPlayerPlatform.instance;
    platform = DiagnosticVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = previous;
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
  });
  for (final origin in ['button', 'automatic']) {
    testWidgets(
      '$origin promotes prepared next samples on the same controller',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        final repository = PreparedTransitionRepository();
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        final player = LunaExoPlayer();
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'prepareNext') {
            return {'prepared': true, 'elapsedMs': 20};
          }
          if (call.method == 'transition') {
            expect(player.state.playing, isFalse);
            return {
              ...response,
              'firstFrame': true,
              'usedPrepared': true,
              'preloadReady': true,
            };
          }
          return {};
        });
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
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          final controller = player.controller!;
          controller.value = controller.value.copyWith(
            position: const Duration(seconds: 1),
            buffered: [
              DurationRange(Duration.zero, const Duration(seconds: 10)),
            ],
          );
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(
            calls.where((call) => call.method == 'prepareNext'),
            hasLength(1),
          );
          if (origin == 'button') {
            await tester.tap(find.byKey(const ValueKey('player-mobile-next')));
          } else {
            controller.value = controller.value.copyWith(
              position: controller.value.duration,
            );
            platform.streams[0]!.add(
              VideoEvent(eventType: VideoEventType.completed),
            );
          }
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          final transition = calls.singleWhere(
            (call) => call.method == 'transition',
          );
          expect(transition.arguments['identity'], 'episode-2');
          expect(transition.arguments['mediaType'], 'mp4');
          expect(transition.arguments['requestElapsedMs'], isA<int>());
          expect(repository.resolutions, 1);
          expect(player.controller, same(controller));
          expect(player.lastTransitionUsedPrepared, true);
          expect(platform.created, 1);
          expect(platform.peakLive, 1);
          expect(
            calls.where(
              (call) =>
                  call.method == 'clearNext' &&
                  call.arguments['identity'] == 'episode-2',
            ),
            isEmpty,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          store.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets(
    'completed cache retries a transient native sample preparation failure',
    (tester) async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'prepareNext') {
          if (++attempts == 1) throw PlatformException(code: 'prepare_timeout');
          return {'prepared': true, 'elapsedMs': 2};
        }
        return {};
      });
      final player = LunaExoPlayer(preparationRetryDelay: Duration.zero);
      await player.open(Media('file:///retry-current.mp4'));
      final repository = PendingPreloadRepository();
      final next = Episode({'id': '2', 'currentEpisode': 2}, 2);
      final preloader = PlaybackPreloader(
        repository,
        onPrepared: (plan) {
          unawaited(
            player.prepareNext(
              Media(plan.url),
              identity: plan.session,
              mediaType: plan.mediaType,
            ),
          );
        },
        onRelease: (plan) => player.clearPreparedNext(identity: plan.session),
      );
      preloader.prepare(FixtureRepository.free, next, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending.single.complete(
        const PlaybackPlan(
          url: 'file:///retry-next.mp4',
          session: 'retry-next',
          preloadComplete: true,
          startupReady: true,
          mediaType: 'mp4',
        ),
      );
      await tester.pump();
      expect(attempts, 1);
      preloader.prepare(FixtureRepository.free, next, immediate: true);
      await tester.pump();
      expect(attempts, 2);
      preloader.prepare(FixtureRepository.free, next, immediate: true);
      await tester.pump();
      expect(attempts, 2);
      preloader.dispose();
      await tester.pump();
      await tester.runAsync(player.dispose);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    },
  );

  test(
    'same session with changed effective headers prepares a new source',
    () async {
      final prepared = <MethodCall>[];
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'prepareNext') {
          prepared.add(call);
          return {'prepared': true, 'elapsedMs': 1};
        }
        return {};
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///first.mp4'));
      for (final referer in ['first', 'first', 'updated']) {
        await player.prepareNext(
          Media('file:///next.mp4', httpHeaders: {'Referer': referer}),
          identity: 'next',
          mediaType: 'mp4',
        );
      }
      expect(prepared, hasLength(2));
      expect(prepared.last.arguments['headers']['Referer'], 'updated');
    },
  );

  test(
    'outgoing frame capture rejects a reply from a previous media generation',
    () async {
      final capture = Completer<Uint8List?>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        if (call.method == 'captureFrame') return capture.future;
        if (call.method == 'transition') return Future.value(response);
        return Future.value({});
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///capture-old.mp4'));
      final frame = player.captureFrame();
      await player.transitionTo(Media('file:///capture-new.mp4'));
      capture.complete(Uint8List.fromList([1, 2, 3]));
      expect(await frame, isNull);
      expect(platform.created, 1);
    },
  );

  test('outgoing frame capture is bounded and unavailable for TV', () async {
    var captures = 0;
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
      call,
    ) async {
      if (call.method == 'captureFrame') {
        captures++;
        return Uint8List(4 * 1024 * 1024 + 1);
      }
      return {};
    });
    var television = false;
    final player = LunaExoPlayer(television: () => television);
    addTearDown(player.dispose);
    await player.open(Media('file:///capture.mp4'));
    expect(await player.captureFrame(), isNull);
    player.controller!.value = player.controller!.value.copyWith(
      rotationCorrection: 90,
    );
    expect(await player.captureFrame(), isNull);
    player.controller!.value = player.controller!.value.copyWith(
      rotationCorrection: 0,
    );
    television = true;
    expect(await player.captureFrame(), isNull);
    expect(captures, 1);
  });

  test(
    'late preparation and mismatched clear cannot disturb the consumed entry',
    () async {
      final ready = Completer<Map<String, Object>>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        calls.add(call);
        if (call.method == 'prepareNext') return ready.future;
        if (call.method == 'transition') {
          return Future.value({...response, 'usedPrepared': true});
        }
        return Future.value({});
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///first.mp4'));
      final preparation = player.prepareNext(
        Media('file:///next.mp4'),
        identity: 'next',
        mediaType: 'mp4',
      );
      await player.clearPreparedNext(identity: 'unrelated');
      await player.transitionTo(
        Media('file:///next.mp4'),
        identity: 'next',
        mediaType: 'mp4',
      );
      ready.complete({'prepared': true, 'elapsedMs': 200});
      await preparation;
      expect(calls.where((call) => call.method == 'clearNext'), isEmpty);
      expect(platform.created, 1);
      expect(player.lastTransitionUsedPrepared, true);
    },
  );
  testWidgets(
    'automatic next episode keeps the view and omits the full screen loading curtain',
    (tester) async {
      final repository = TransitionRepository();
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final player = LunaExoPlayer();
      final pending = Completer<Map<String, Object>>();
      var transitions = 0;
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        if (call.method != 'transition') return Future.value({});
        transitions++;
        return pending.future;
      });
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
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(player.controller, isNotNull);
      final controller = player.controller!;
      controller.value = controller.value.copyWith(
        position: controller.value.duration,
      );
      platform.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(transitions, 1);
      expect(platform.created, 1);
      expect(platform.disposed, isEmpty);
      expect(player.controller, same(controller));
      expect(find.text('正在准备播放'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.active, {'episode-1', 'episode-2'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在衔接下一集…'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('正在衔接下一集…'), findsOneWidget);
      pending.complete(response);
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('正在衔接下一集…'), findsNothing);
      expect(player.state.playing, true);
      expect(repository.active, {'episode-2'});
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(repository.active, isEmpty);
      expect(player.controller, isNull);
      expect(platform.disposed, [0]);
      store.dispose();
    },
  );
  testWidgets(
    'failed handoff and failed fresh load leave loading and offer retry',
    (tester) async {
      final repository = TransitionRepository();
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final player = LunaExoPlayer(
        initializationTimeout: const Duration(milliseconds: 30),
        transitionTimeout: const Duration(milliseconds: 30),
      );
      final pending = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        return call.method == 'transition' ? pending.future : Future.value({});
      });
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
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final controller = player.controller!;
      controller.value = controller.value.copyWith(
        position: controller.value.duration,
      );
      platform.initialize = false;
      platform.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
      for (var i = 0; i < 1200; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('正在衔接下一集…'), findsNothing);
      expect(find.text('是否尝试较低清晰度？'), findsOneWidget);
      expect(find.text('重试播放'), findsOneWidget);
      expect(platform.created, 3);
      pending.complete(response);
      await tester.pump();
      expect(player.controller, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(repository.active, isEmpty);
      store.dispose();
    },
  );

  test(
    'late transition duration is refreshed without reopening the player',
    () async {
      var durationMs = 0;
      var snapshots = 0;
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'transition') return {...response, 'durationMs': 0};
        snapshots++;
        return {'durationMs': durationMs};
      });
      final player = LunaExoPlayer();
      final durations = <Duration>[];
      final subscription = player.stream.duration.listen(durations.add);
      await player.open(Media('file:///synthetic-1.mp4'));
      final controller = player.controller;
      await player.transitionTo(Media('file:///synthetic-2.mp4'));
      expect(player.state.duration, Duration.zero);
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(player.state.duration, Duration.zero);
      durationMs = 90000;
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(player.controller, same(controller));
      expect(controller!.value.duration, const Duration(seconds: 90));
      expect(player.state.duration, const Duration(seconds: 90));
      expect(durations.last, const Duration(seconds: 90));
      expect(platform.created, 1);
      final calls = snapshots;
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(snapshots, calls);
      await subscription.cancel();
      await player.dispose();
    },
  );

  test('stale duration snapshot cannot change a newer transition', () async {
    final pending = Completer<Map<String, Object>>();
    var hold = false;
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (call) {
      if (call.method == 'transition') {
        return Future.value({...response, 'durationMs': 0});
      }
      return hold ? pending.future : Future.value({});
    });
    final player = LunaExoPlayer();
    addTearDown(player.dispose);
    await player.open(Media('file:///synthetic-1.mp4'));
    await player.transitionTo(Media('file:///synthetic-2.mp4'));
    await Future<void>.delayed(Duration.zero);
    hold = true;
    final stale = player.reportNativeDiagnostics(log: false);
    await Future<void>.delayed(Duration.zero);
    await player.transitionTo(Media('file:///synthetic-3.mp4'));
    pending.complete({'durationMs': 90000});
    await stale;
    expect(player.state.duration, Duration.zero);
    expect(player.controller!.value.duration, Duration.zero);
    expect(platform.created, 1);
  });

  test(
    'twenty automatic transitions retain one initialized controller and reset each episode',
    () async {
      final ids = <int>[];
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method != 'transition') return {};
        ids.add((call.arguments as Map)['playerId'] as int);
        expect(
          (call.arguments as Map)['headers']['Referer'],
          'https://synthetic.test',
        );
        return response;
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-1.mp4'));
      final controller = player.controller;
      for (var episode = 2; episode <= 21; episode++) {
        await player.transitionTo(
          Media(
            'file:///synthetic-$episode.mp4',
            httpHeaders: {'Referer': 'https://synthetic.test'},
          ),
        );
        expect(player.controller, same(controller));
        expect(player.state.duration, const Duration(seconds: 90));
        expect(player.state.position, Duration.zero);
        expect(player.state.completed, false);
        expect(player.state.playing, true);
      }
      expect(ids, List.filled(20, 0));
      expect(platform.created, 1);
      expect(platform.disposed, isEmpty);
      expect(platform.peakLive, 1);
    },
  );
  test(
    'first frame wait keeps old view attached and background pause survives completion',
    () async {
      final pending = Completer<Map<String, Object>>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        if (call.method != 'transition') return Future.value({});
        started.complete();
        return pending.future;
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-1.mp4'));
      final controller = player.controller;
      final changing = player.transitionTo(Media('file:///synthetic-2.mp4'));
      await started.future;
      expect(player.controller, same(controller));
      expect(controller!.value.isInitialized, true);
      expect(platform.disposed, isEmpty);
      await player.pause();
      pending.complete(response);
      await changing;
      expect(player.state.playing, false);
      expect(player.controller, same(controller));
    },
  );
  test(
    'failed transition falls back with old controller released before recreation',
    () async {
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'transition')
          throw PlatformException(code: 'transition_failed');
        return {};
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-1.mp4'));
      await player.transitionTo(Media('file:///synthetic-2.mp4'));
      expect(platform.created, 2);
      expect(platform.disposed, [0]);
      expect(platform.peakLive, 1);
      expect(player.state.playing, true);
    },
  );
  test(
    'missing native reply has a deadline and late reply cannot reset the replacement',
    () async {
      final pending = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        return call.method == 'transition' ? pending.future : Future.value({});
      });
      final player = LunaExoPlayer(
        transitionTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-1.mp4'));
      await player.transitionTo(Media('file:///synthetic-2.mp4'));
      final current = player.controller;
      expect(platform.created, 2);
      expect(platform.disposed, [0]);
      expect(player.state.playing, true);
      pending.complete(response);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(player.controller, same(current));
      expect(platform.created, 2);
    },
  );

  test(
    'failed preloaded transition requests fresh resolution without reopening the same URL',
    () async {
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'transition')
          throw PlatformException(code: 'transition_timeout');
        return {};
      });
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-1.mp4'));
      await expectLater(
        player.transitionTo(
          Media('file:///expired-cache.mp4'),
          reopenOnFailure: false,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(platform.created, 1);
      expect(player.canTransition, false);
      expect(platform.disposed, [0]);
    },
  );

  test(
    'leaving during first frame wait does not resurrect the disposed controller',
    () async {
      final pending = Completer<Map<String, Object>>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        if (call.method != 'transition') return Future.value({});
        started.complete();
        return pending.future;
      });
      final player = LunaExoPlayer();
      await player.open(Media('file:///synthetic-1.mp4'));
      final changing = player.transitionTo(Media('file:///synthetic-2.mp4'));
      await started.future;
      await player.dispose();
      pending.complete(response);
      await changing;
      expect(platform.created, 1);
      expect(platform.disposed, [0]);
      expect(player.controller, isNull);
    },
  );
}
