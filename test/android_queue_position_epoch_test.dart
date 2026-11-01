import 'dart:async';

import 'package:duanju_app/android_playback_queue.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;

class _DelayedPositionPlatform extends DiagnosticVideoPlatform {
  bool hold = false;
  Duration currentPosition = const Duration(milliseconds: 200);
  final pending = <Completer<Duration>>[];
  Completer<void>? seekReply;
  int seekCalls = 0;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCalls++;
    await seekReply?.future;
  }

  @override
  Future<Duration> getPosition(int playerId) {
    if (!hold) return Future.value(currentPosition);
    final reply = Completer<Duration>();
    pending.add(reply);
    return reply.future;
  }

  void completePending(Duration position) {
    final replies = pending.toList();
    pending.clear();
    for (final reply in replies) {
      reply.complete(position);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('hongguo/video_queue/0');
  late VideoPlayerPlatform previous;
  late _DelayedPositionPlatform platform;
  late LunaExoPlayer player;
  late AndroidPlaybackQueueDriver driver;
  late List<bool> completions;
  Completer<Map<String, dynamic>>? diagnostic;

  PlaybackPlan plan(int number) => PlaybackPlan(
    url: number == 1
        ? 'file:///synthetic-current.mp4'
        : 'http://127.0.0.1/cache/item-$number.mp4',
    local: number == 1,
    session: 'item-$number',
    mediaType: 'mp4',
    preloadComplete: true,
  );

  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('position poll timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> send(
    int number,
    String kind, {
    int durationMs = 20000,
    int positionMs = 200,
  }) async {
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'identity': 'item-$number',
        'generation': number,
        'url': plan(number).url,
        'kind': kind,
        'durationMs': durationMs,
        'positionMs': positionMs,
        'bufferedMs': durationMs,
        'width': 640.0,
        'height': 360.0,
        'playing': true,
        'buffering': false,
        'firstFrame': kind == 'ready',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> stage(int number) async {
    expect(
      await driver.stage(
        current: plan(number - 1),
        next: plan(number),
        identity: 'item-$number',
        generation: number,
      ),
      isTrue,
    );
  }

  setUp(() async {
    previous = VideoPlayerPlatform.instance;
    platform = _DelayedPositionPlatform();
    VideoPlayerPlatform.instance = platform;
    completions = [];
    diagnostic = null;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
      call,
    ) async {
      switch (call.method) {
        case 'prepareNext':
          return {'prepared': true};
        case 'queueStage':
          return true;
        case 'queueSnapshot':
          return <String, dynamic>{};
        case 'snapshot':
          return diagnostic?.future ?? Future.value(<String, dynamic>{});
        default:
          return null;
      }
    });
    player = LunaExoPlayer();
    driver = AndroidPlaybackQueueDriver(player);
    player.stream.completed.listen(completions.add);
    await player.open(Media(plan(1).url), mediaType: 'mp4');
  });

  tearDown(() async {
    await player.pause();
    platform.hold = false;
    platform.completePending(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await driver.dispose();
    await player.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
    VideoPlayerPlatform.instance = previous;
  });

  test('four handoffs reject previous media position replies', () async {
    final controller = player.controller;
    final contaminated = <int>[];
    var oldDuration = const Duration(minutes: 3);
    for (var number = 2; number <= 5; number++) {
      final oldPosition = oldDuration - const Duration(milliseconds: 100);
      player.controller!.value = player.controller!.value.copyWith(
        position: oldPosition,
        isCompleted: false,
      );
      platform.hold = true;
      await until(() => platform.pending.isNotEmpty);
      await stage(number);
      platform.hold = false;
      platform.currentPosition = const Duration(milliseconds: 200);
      await send(number, 'activated');
      final durationMs = 120000 ~/ (number - 1);
      await send(number, 'ready', durationMs: durationMs);
      platform.completePending(oldPosition);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      if (player.state.completed ||
          player.state.position > const Duration(seconds: 1)) {
        contaminated.add(number);
      }
      await until(() => !player.state.completed);
      oldDuration = Duration(milliseconds: durationMs);
    }
    expect(contaminated, isEmpty);
    expect(completions.where((value) => value), isEmpty);
    expect(player.controller, same(controller));
    expect(platform.created, 1);
    expect(platform.peakLive, 1);
  });

  test(
    'unknown duration between activation and ready is not completion',
    () async {
      await stage(2);
      await send(2, 'activated');
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(player.state.completed, false);
      expect(completions.where((value) => value), isEmpty);
      await send(2, 'ready');
      expect(player.state.duration, const Duration(seconds: 20));
    },
  );

  test(
    'old diagnostic duration cannot populate a newly activated media',
    () async {
      diagnostic = Completer<Map<String, dynamic>>();
      final request = player.reportNativeDiagnostics(log: false);
      await Future<void>.delayed(Duration.zero);
      await stage(2);
      await send(2, 'activated');
      diagnostic!.complete({'durationMs': 180000});
      await request;
      diagnostic = null;
      expect(player.controller!.value.duration, Duration.zero);
      expect(player.state.duration, Duration.zero);
      await send(2, 'ready');
      expect(player.state.duration, const Duration(seconds: 20));
    },
  );

  test('repeated ready packets never rewind the current media clock', () async {
    await stage(2);
    await send(2, 'activated');
    await send(2, 'ready');
    platform.currentPosition = const Duration(seconds: 3);
    await until(() => player.state.position >= const Duration(seconds: 3));
    await send(2, 'ready', positionMs: 100);
    expect(
      player.state.position,
      greaterThanOrEqualTo(const Duration(seconds: 3)),
    );
    expect(player.state.completed, false);
  });

  test('current media completion and replay remain observable', () async {
    final controller = player.controller;
    await stage(2);
    await send(2, 'activated');
    await send(2, 'ready');
    platform.currentPosition = const Duration(seconds: 20);
    await until(() => player.state.completed);
    expect(completions.where((value) => value), isNotEmpty);
    platform.currentPosition = const Duration(seconds: 3);
    await player.seek(platform.currentPosition);
    await until(() => !player.state.completed);
    expect(player.state.position, const Duration(seconds: 3));
    platform.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
    await until(() => player.state.completed);
    expect(player.controller, same(controller));
    expect(platform.created, 1);
  });

  test('late ready keeps pause and genuine completion state', () async {
    await stage(2);
    await send(2, 'activated');
    await send(2, 'ready');
    await player.pause();
    await send(2, 'ready');
    expect(player.state.playing, false);
    platform.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
    await until(() => player.state.completed);
    await send(2, 'ready');
    expect(player.state.completed, true);
    expect(player.state.playing, false);
  });

  test('ready from a retired item cannot overwrite the next handoff', () async {
    await stage(2);
    await send(2, 'activated');
    await send(2, 'ready');
    await stage(3);
    await send(3, 'activated');
    await send(3, 'ready', durationMs: 30000, positionMs: 400);
    await send(2, 'ready', durationMs: 180000, positionMs: 170000);
    expect(player.state.position, const Duration(milliseconds: 400));
    expect(player.state.duration, const Duration(seconds: 30));
    expect(player.state.completed, false);
    expect(platform.created, 1);
  });

  for (final seconds in [0, 5]) {
    test(
      'same-media seek to $seconds rejects the pre-seek end reply',
      () async {
        await stage(2);
        await send(2, 'activated');
        await send(2, 'ready');
        platform.hold = true;
        await until(() => platform.pending.isNotEmpty);
        final target = Duration(seconds: seconds);
        await player.seek(target);
        platform.hold = false;
        platform.currentPosition = target;
        platform.completePending(const Duration(seconds: 20));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(player.state.completed, false);
        expect(player.state.position, target);
        expect(completions.where((value) => value), isEmpty);
        platform.currentPosition = target + const Duration(milliseconds: 200);
        await until(() => player.state.position == platform.currentPosition);
        expect(platform.created, 1);
      },
    );
  }

  test(
    'position polling stays suspended until an in-flight seek settles',
    () async {
      await stage(2);
      await send(2, 'activated');
      await send(2, 'ready');
      final callsBefore = platform.seekCalls;
      platform.seekReply = Completer<void>();
      final request = player.seek(const Duration(seconds: 5));
      await until(() => platform.seekCalls > callsBefore);
      platform.currentPosition = const Duration(seconds: 20);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final completedDuringSeek = player.state.completed;
      platform.currentPosition = const Duration(milliseconds: 5200);
      platform.seekReply!.complete();
      await request;
      expect(completedDuringSeek, false);
      expect(player.state.completed, false);
      await until(() => player.state.position == platform.currentPosition);
      expect(platform.created, 1);
    },
  );
}
