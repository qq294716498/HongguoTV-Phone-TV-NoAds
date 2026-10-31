import 'dart:async';

import 'package:duanju_app/android_playback_queue.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_queue_contract.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:media_kit/media_kit.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const current = PlaybackPlan(
    url: 'file:///synthetic-current.mp4',
    local: true,
  );
  const next = PlaybackPlan(
    url: 'http://127.0.0.1/cache/next.mp4',
    session: 'next-session',
    mediaType: 'mp4',
    preloadComplete: true,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const eventsChannel = MethodChannel('hongguo/video_queue/0');
  late VideoPlayerPlatform previous;
  late DiagnosticVideoPlatform platform;
  late LunaExoPlayer player;
  late AndroidPlaybackQueueDriver driver;
  late List<MethodCall> calls;
  late Map<String, dynamic> snapshot;
  late List<PlaybackQueueEvent> events;
  Completer<Map<String, dynamic>>? pendingPrepare;
  Object? stageError;
  Object? clearError;
  var failSnapshotAfterClear = false;
  var failSnapshotAfterStage = false;
  var snapshotFailures = 0;
  var snapshotAfterStage = <String, dynamic>{};

  Map<String, dynamic> packet(
    String kind, {
    String identity = 'candidate-2',
    int generation = 2,
  }) => {
    'kind': kind,
    'identity': identity,
    'generation': generation,
    'url': next.url,
    'durationMs': 20000,
    'positionMs': 100,
    'bufferedMs': 12000,
    'width': 640.0,
    'height': 360.0,
    'playing': true,
    'buffering': false,
    'firstFrame': kind == 'ready',
  };

  Future<void> send(Map<String, dynamic> value) async {
    ServicesBinding.instance.channelBuffers.push(
      eventsChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<bool> stage() => driver.stage(
    current: current,
    next: next,
    identity: 'candidate-2',
    generation: 2,
  );

  setUp(() async {
    previous = VideoPlayerPlatform.instance;
    platform = DiagnosticVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    calls = [];
    snapshot = {};
    events = [];
    pendingPrepare = null;
    stageError = null;
    clearError = null;
    failSnapshotAfterClear = false;
    failSnapshotAfterStage = false;
    snapshotFailures = 0;
    snapshotAfterStage = {};
    messenger.setMockMethodCallHandler(eventsChannel, (_) async => null);
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'queueSnapshot':
          if (snapshotFailures > 0) {
            snapshotFailures--;
            throw PlatformException(code: 'snapshot_unavailable');
          }
          return snapshot;
        case 'prepareNext':
          return pendingPrepare == null
              ? {'prepared': true, 'elapsedMs': 1}
              : await pendingPrepare!.future;
        case 'queueStage':
          if (stageError != null) throw stageError!;
          snapshot = snapshotAfterStage;
          if (failSnapshotAfterStage) snapshotFailures++;
          return true;
        case 'queueAdvance':
          return true;
        case 'queueClear':
          if (clearError != null) throw clearError!;
          if (failSnapshotAfterClear) snapshotFailures++;
          return snapshot['kind'] != 'activated' && snapshot['kind'] != 'ready';
        default:
          return null;
      }
    });
    player = LunaExoPlayer();
    driver = AndroidPlaybackQueueDriver(player);
    driver.events.listen(events.add);
    await player.open(Media(current.url));
    player.controller!.value = player.controller!.value.copyWith(
      position: const Duration(seconds: 7),
    );
  });

  tearDown(() async {
    await driver.dispose();
    await player.dispose();
    messenger.setMockMethodCallHandler(eventsChannel, null);
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
    VideoPlayerPlatform.instance = previous;
  });

  test(
    'only verified local or loopback bytes without per-item decryption can queue',
    () async {
      expect(AndroidPlaybackQueueDriver.supports(next), isTrue);
      expect(AndroidPlaybackQueueDriver.supports(current), isTrue);
      expect(
        AndroidPlaybackQueueDriver.supports(
          const PlaybackPlan(
            url: 'https://media.test/remote.mp4',
            preloadComplete: true,
          ),
        ),
        isFalse,
      );
      expect(
        AndroidPlaybackQueueDriver.supports(
          const PlaybackPlan(
            url: 'http://127.0.0.1/cache/partial.mp4',
            startupReady: true,
          ),
        ),
        isFalse,
      );
      expect(
        AndroidPlaybackQueueDriver.supports(
          const PlaybackPlan(
            url: 'file:///encrypted.mp4',
            local: true,
            decryptionKey: 'synthetic',
          ),
        ),
        isFalse,
      );
      expect(
        await driver.stage(
          current: current,
          next: const PlaybackPlan(url: 'https://media.test/remote.mp4'),
          identity: 'remote',
          generation: 1,
        ),
        isFalse,
      );
      expect(calls.where((call) => call.method == 'queueStage'), isEmpty);
    },
  );

  test(
    'current URL, headers and format must match the active source',
    () async {
      for (final mismatched in [
        const PlaybackPlan(url: 'file:///different.mp4', local: true),
        const PlaybackPlan(
          url: 'file:///synthetic-current.mp4',
          local: true,
          headers: {'X-Synthetic': 'changed'},
        ),
        const PlaybackPlan(
          url: 'file:///synthetic-current.mp4',
          local: true,
          mediaType: 'hls',
        ),
      ]) {
        expect(
          await driver.stage(
            current: mismatched,
            next: next,
            identity: 'candidate-2',
            generation: 2,
          ),
          isFalse,
        );
      }
      expect(calls.where((call) => call.method == 'queueStage'), isEmpty);
      expect(await stage(), isTrue);
    },
  );

  test(
    'stage and actual native activation retain one controller and publish old position first',
    () async {
      final controller = player.controller;
      Duration? oldPosition;
      driver.events.listen((event) {
        if (event.kind == PlaybackQueueEventKind.activated) {
          oldPosition = player.state.position;
        }
      });
      expect(await stage(), isTrue);
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
      await send(packet('activated'));
      expect(oldPosition, const Duration(seconds: 7));
      expect(events.single.kind, PlaybackQueueEventKind.activated);
      expect(player.state.position, Duration.zero);
      await send(packet('ready'));
      expect(events.last.kind, PlaybackQueueEventKind.ready);
      expect(events.last.firstFrame, isTrue);
      expect(player.state.duration, const Duration(seconds: 20));
      expect(player.state.position, const Duration(milliseconds: 100));
      expect(player.state.width, 640);
      expect(player.state.height, 360);
      expect(player.controller, same(controller));
      expect(platform.created, 1);
      expect(platform.peakLive, 1);
      expect(platform.disposed, isEmpty);
      await send(packet('activated'));
      expect(
        events.where((event) => event.kind == PlaybackQueueEventKind.activated),
        hasLength(1),
      );
      expect(player.state.position, const Duration(milliseconds: 100));
    },
  );

  test(
    'native snapshot recovers an activation delivered before stream subscription',
    () async {
      snapshotAfterStage = packet('ready');
      expect(await stage(), isTrue);
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
      ]);
      expect(player.state.duration, const Duration(seconds: 20));
      expect(platform.created, 1);
    },
  );

  test(
    'clear drops future callbacks but never discards an already active item',
    () async {
      expect(await stage(), isTrue);
      await driver.clear(identity: 'candidate-2');
      await send(packet('activated'));
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
      expect(await stage(), isTrue);
      snapshot = packet('ready');
      await send(packet('activated'));
      await driver.clear(identity: 'candidate-2');
      expect(
        events.where((event) => event.kind == PlaybackQueueEventKind.activated),
        hasLength(1),
      );
      expect(player.state.duration, const Duration(seconds: 20));
      expect(player.controller, isNotNull);
      expect(platform.disposed, isEmpty);
    },
  );

  test(
    'replacement removes the queued source before preparing another candidate',
    () async {
      expect(await stage(), isTrue);
      final start = calls.length;
      expect(
        await driver.stage(
          current: current,
          next: const PlaybackPlan(
            url: 'http://127.0.0.1/cache/replacement.mp4',
            preloadComplete: true,
            mediaType: 'mp4',
          ),
          identity: 'replacement',
          generation: 3,
        ),
        isTrue,
      );
      final methods = calls.skip(start).map((call) => call.method).toList();
      expect(
        methods.indexOf('queueClear'),
        lessThan(methods.indexOf('prepareNext')),
      );
      await send(packet('activated'));
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
    },
  );

  test(
    'suspend invalidates late preparation without deleting the active player',
    () async {
      pendingPrepare = Completer<Map<String, dynamic>>();
      final pending = stage();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await driver.suspend(true);
      pendingPrepare!.complete({'prepared': true});
      expect(await pending, isFalse);
      expect(calls.where((call) => call.method == 'queueStage'), isEmpty);
      expect(platform.created, 1);
      expect(platform.disposed, isEmpty);
      pendingPrepare = null;
      await driver.suspend(false);
      expect(calls.where((call) => call.method == 'queueStage'), isEmpty);
      expect(await stage(), isTrue);
      expect(calls.where((call) => call.method == 'queueStage'), hasLength(1));
    },
  );

  test(
    'manual advance forwards paused intent and mismatched identity is rejected',
    () async {
      expect(await stage(), isTrue);
      expect(
        await driver.advance(identity: 'candidate-2', play: false),
        isTrue,
      );
      final call = calls.lastWhere((call) => call.method == 'queueAdvance');
      expect((call.arguments as Map)['play'], isFalse);
      expect(await driver.advance(identity: 'stale', play: true), isFalse);
      expect(platform.created, 1);
    },
  );

  test(
    'stale errors cannot affect another generation and candidate failure retains current',
    () async {
      expect(await stage(), isTrue);
      await send(packet('failed', generation: 1)..['message'] = 'stale');
      expect(events, isEmpty);
      await send(packet('failed')..['message'] = 'synthetic decoder error');
      expect(events.single.kind, PlaybackQueueEventKind.failed);
      expect(events.single.identity, 'candidate-2');
      expect(player.state.position, const Duration(seconds: 7));
      expect(platform.disposed, isEmpty);
    },
  );

  test(
    'missing post-stage acknowledgment clears the actual native candidate',
    () async {
      failSnapshotAfterStage = true;
      expect(await stage(), isFalse);
      expect(calls.where((call) => call.method == 'queueStage'), hasLength(1));
      expect(calls.where((call) => call.method == 'queueClear'), hasLength(1));
      await send(packet('activated'));
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
    },
  );

  test(
    'unknown stage and cleanup stops the sole controller before one recovery event',
    () async {
      stageError = PlatformException(code: 'stage_ack_unknown');
      clearError = PlatformException(code: 'clear_ack_unknown');
      final oldController = player.controller;
      expect(await stage(), isFalse);
      expect(player.controller, isNull);
      expect(platform.disposed, hasLength(1));
      expect(platform.created, 1);
      expect(player.state.position, const Duration(seconds: 7));
      expect(events, hasLength(1));
      expect(events.single.kind, PlaybackQueueEventKind.failed);
      expect(events.single.message, 'queue_state_unknown');
      expect(events.single.identity, 'candidate-2');
      expect(events.single.generation, 2);
      await send(packet('activated'));
      expect(events, hasLength(1));
      expect(player.controller, isNot(same(oldController)));
    },
  );

  test(
    'confirmed removal preserves playback even when its diagnostic snapshot fails',
    () async {
      failSnapshotAfterStage = true;
      failSnapshotAfterClear = true;
      final oldController = player.controller;
      expect(await stage(), isFalse);
      expect(player.controller, same(oldController));
      expect(platform.disposed, isEmpty);
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
    },
  );

  test(
    'failed queue stage clears native candidate before falling back',
    () async {
      stageError = PlatformException(code: 'queue_failed');
      expect(await stage(), isFalse);
      expect(calls.where((call) => call.method == 'queueClear'), hasLength(1));
      await send(packet('activated'));
      expect(events, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
    },
  );
}
