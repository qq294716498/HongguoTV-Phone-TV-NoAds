import 'dart:async';

import 'package:duanju_app/luna_exo_player.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;

class CancellableVideoPlatform extends DiagnosticVideoPlatform {
  final played = <int>[];
  Completer<void>? creationReply;
  Completer<void>? playReply;
  Completer<void>? pauseReply;
  Completer<void>? seekReply;
  Completer<void>? rateReply;
  Completer<void>? volumeReply;
  Completer<void>? disposeReply;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = await super.createWithOptions(options);
    await creationReply?.future;
    return id;
  }

  @override
  Future<void> pause(int playerId) async {
    await pauseReply?.future;
  }

  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
    await playReply?.future;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    await seekReply?.future;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    await rateReply?.future;
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    await volumeReply?.future;
  }

  @override
  Future<void> dispose(int playerId) async {
    await super.dispose(playerId);
    await disposeReply?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previous;
  late CancellableVideoPlatform platform;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const transitionResult = {
    'durationMs': 90000,
    'width': 1280,
    'height': 720,
    'elapsedMs': 120,
  };

  Future<void> flush() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  LunaExoPlayer createPlayer() => LunaExoPlayer(
    initializationTimeout: const Duration(seconds: 20),
    operationTimeout: const Duration(milliseconds: 25),
    disposeTimeout: const Duration(milliseconds: 25),
  );

  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = CancellableVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    messenger.setMockMethodCallHandler(
      LunaExoPlayer.diagnosticChannel,
      (_) async => {},
    );
  });

  tearDown(() {
    VideoPlayerPlatform.instance = previous;
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
  });

  test('cancelPending preserves a stable initialized controller', () async {
    final player = createPlayer();
    addTearDown(player.dispose);
    await player.open(Media('file:///synthetic-stable.mp4'));
    final controller = player.controller;
    await player.cancelPending();
    expect(player.controller, same(controller));
    expect(player.canTransition, true);
    expect(platform.disposed, isEmpty);
  });

  test(
    'pause while initialization is pending prevents delayed autoplay',
    () async {
      platform.initialize = false;
      final player = createPlayer();
      addTearDown(player.dispose);
      final opening = player.open(
        Media('file:///synthetic-background-init.mp4'),
      );
      await flush();
      await player.pause();
      platform.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1920, 1080),
          duration: const Duration(minutes: 3),
        ),
      );
      await opening;
      expect(platform.played, isEmpty);
      expect(player.state.playing, false);
      expect(player.controller!.value.isPlaying, false);
    },
  );

  for (final action in ['cancel', 'stop', 'dispose']) {
    test(
      '$action releases initialization and settles open immediately',
      () async {
        platform.initialize = false;
        final player = createPlayer();
        final opening = player.open(Media('file:///synthetic-pending.mp4'));
        await flush();
        expect(platform.created, 1);
        expect(player.controller, isNull);
        final cancelled = switch (action) {
          'stop' => player.stop(),
          'dispose' => player.dispose(),
          _ => player.cancelPending(),
        };
        await Future.wait([
          opening,
          cancelled,
        ]).timeout(const Duration(milliseconds: 500));
        expect(platform.disposed, [0]);
        expect(player.controller, isNull);
        await player.dispose();
      },
    );
  }

  test(
    'late native creation is released without resurrecting cancelled open',
    () async {
      final gate = Completer<void>();
      platform.creationReply = gate;
      final player = createPlayer();
      addTearDown(player.dispose);
      final opening = player.open(Media('file:///synthetic-creation.mp4'));
      await flush();
      await player.cancelPending().timeout(const Duration(milliseconds: 500));
      await opening.timeout(const Duration(milliseconds: 500));
      expect(player.controller, isNull);
      gate.complete();
      await flush();
      expect(platform.disposed, [0]);
      expect(player.controller, isNull);
    },
  );

  test(
    'a new open disposes an older initializing controller before replacement',
    () async {
      platform.initialize = false;
      final player = createPlayer();
      addTearDown(player.dispose);
      final first = player.open(Media('file:///synthetic-old.mp4'));
      await flush();
      platform.initialize = true;
      await player.open(Media('file:///synthetic-new.mp4'));
      await first.timeout(const Duration(milliseconds: 500));
      expect(platform.disposed, [0]);
      expect(platform.peakLive, 1);
      expect(player.controller, isNotNull);
      expect(player.state.playing, true);
    },
  );

  for (final command in ['play', 'pause', 'seek', 'rate', 'volume']) {
    test(
      'a $command that never replies has a deadline and cannot block replacement',
      () async {
        final player = createPlayer();
        addTearDown(player.dispose);
        await player.open(Media('file:///synthetic-command-old.mp4'));
        final gate = Completer<void>();
        switch (command) {
          case 'play':
            platform.playReply = gate;
          case 'pause':
            platform.pauseReply = gate;
          case 'seek':
            platform.seekReply = gate;
          case 'rate':
            platform.rateReply = gate;
          case 'volume':
            platform.volumeReply = gate;
        }
        final pending = switch (command) {
          'play' => player.play(),
          'pause' => player.pause(),
          'seek' => player.seek(const Duration(seconds: 40)),
          'rate' => player.setRate(1.5),
          _ => player.setVolume(30),
        };
        await pending.timeout(const Duration(milliseconds: 500));
        expect(platform.disposed, [0]);
        expect(player.controller, isNull);
        platform.pauseReply = platform.seekReply = null;
        platform.playReply = null;
        platform.rateReply = platform.volumeReply = null;
        await player.open(Media('file:///synthetic-command-new.mp4'));
        final current = player.controller;
        gate.complete();
        await flush();
        expect(player.controller, same(current));
        expect(player.state.position, Duration.zero);
        expect(player.state.playing, true);
      },
    );
  }

  test(
    'cancelPending interrupts a hanging pause without waiting for its deadline',
    () async {
      final player = LunaExoPlayer(
        operationTimeout: const Duration(seconds: 20),
      );
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-pause.mp4'));
      final gate = Completer<void>();
      platform.pauseReply = gate;
      final pause = player.pause();
      await flush();
      await player.cancelPending();
      await pause.timeout(const Duration(milliseconds: 500));
      expect(platform.disposed, [0]);
      gate.complete();
      await flush();
    },
  );

  test(
    'cancelled transition settles before native reply and cannot restart playback',
    () async {
      final reply = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) {
        return call.method == 'transition' ? reply.future : Future.value({});
      });
      final player = createPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-transition-old.mp4'));
      final changing = player.transitionTo(
        Media('file:///synthetic-transition-next.mp4'),
      );
      await flush();
      await player.cancelPending();
      await changing.timeout(const Duration(milliseconds: 500));
      expect(platform.disposed, [0]);
      await player.open(Media('file:///synthetic-transition-new.mp4'));
      final current = player.controller;
      reply.complete(transitionResult);
      await flush();
      expect(player.controller, same(current));
      expect(player.state.position, Duration.zero);
      expect(player.state.playing, true);
    },
  );

  test(
    'a hanging startup seek fails before autoplay and cannot seek a replacement',
    () async {
      final player = createPlayer();
      addTearDown(player.dispose);
      final gate = Completer<void>();
      platform.seekReply = gate;
      await expectLater(
        player.open(
          Media(
            'file:///synthetic-startup-seek-old.mp4',
            start: const Duration(seconds: 40),
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(platform.played, isEmpty);
      expect(platform.disposed, [0]);
      expect(player.controller, isNull);
      expect(player.state.playing, false);
      platform.seekReply = null;
      await player.open(Media('file:///synthetic-startup-seek-new.mp4'));
      final current = player.controller;
      gate.complete();
      await flush();
      expect(player.controller, same(current));
      expect(player.state.position, Duration.zero);
      expect(platform.played, [1]);
    },
  );

  test(
    'late play completion after cancellation and disposal cannot leave a periodic timer',
    () async {
      final player = createPlayer();
      final gate = Completer<void>();
      final playTimers = <Timer>[];
      try {
        await player.open(Media('file:///synthetic-late-play.mp4'));
        platform.playReply = gate;
        final playing = runZoned(
          player.play,
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              final timer = parent.createPeriodicTimer(
                zone,
                duration,
                callback,
              );
              if (duration == const Duration(milliseconds: 100)) {
                playTimers.add(timer);
              }
              return timer;
            },
          ),
        );
        await flush();
        await player.cancelPending();
        await playing.timeout(const Duration(milliseconds: 500));
        await player.dispose();
        expect(platform.disposed, [0]);
        gate.complete();
        await flush();
        expect(
          playTimers.where((timer) => timer.isActive),
          isEmpty,
          reason:
              'A disposed controller must not create an unbounded 100ms position timer after a late play reply',
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await player.dispose();
        await flush();
        for (final timer in playTimers) {
          timer.cancel();
        }
      }
    },
  );

  test(
    'a late native seek reply cannot update a disposed controller',
    () async {
      final player = createPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-native-late-seek.mp4'));
      final old = player.controller!;
      final gate = Completer<void>();
      platform.seekReply = gate;
      final seeking = old.seekTo(const Duration(seconds: 40));
      await player.stop();
      gate.complete();
      await expectLater(seeking, completes);
      expect(player.state.position, Duration.zero);
    },
  );

  test(
    'a play reply arriving after pause cannot restart the position timer',
    () async {
      final player = createPlayer();
      addTearDown(player.dispose);
      final gate = Completer<void>();
      final playTimers = <Timer>[];
      try {
        await player.open(Media('file:///synthetic-late-play-paused.mp4'));
        platform.playReply = gate;
        final playing = runZoned(
          player.play,
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              final timer = parent.createPeriodicTimer(
                zone,
                duration,
                callback,
              );
              if (duration == const Duration(milliseconds: 100)) {
                playTimers.add(timer);
              }
              return timer;
            },
          ),
        );
        await flush();
        await player.pause();
        gate.complete();
        await playing;
        await flush();
        expect(playTimers.where((timer) => timer.isActive), isEmpty);
        expect(player.state.playing, false);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await player.dispose();
        await flush();
        for (final timer in playTimers) {
          timer.cancel();
        }
      }
    },
  );

  test('dispose remains bounded when native release never replies', () async {
    final player = createPlayer();
    await player.open(Media('file:///synthetic-release.mp4'));
    platform.disposeReply = Completer<void>();
    await player.dispose().timeout(const Duration(milliseconds: 500));
    expect(platform.disposed, [0]);
    expect(player.controller, isNull);
    platform.disposeReply!.complete();
    await flush();
  });
}
