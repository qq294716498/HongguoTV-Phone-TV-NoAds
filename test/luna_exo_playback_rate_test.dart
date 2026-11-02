import 'dart:async';

import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;

class RateVideoPlatform extends DiagnosticVideoPlatform {
  Completer<void>? rateGate;
  Object? rateError;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    final gate = rateGate;
    final error = rateError;
    await gate?.future;
    if (error != null) throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previous;
  late RateVideoPlatform platform;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = RateVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    messenger.setMockMethodCallHandler(
      LunaExoPlayer.diagnosticChannel,
      (_) async => {},
    );
    DiaryService.clear();
  });

  tearDown(() {
    VideoPlayerPlatform.instance = previous;
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
  });

  test(
    'failed speed commands preserve the previous rate and redact native errors',
    () async {
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-rate.mp4'));
      await player.setRate(1.5);
      final events = <double>[];
      final subscription = player.stream.rate.listen(events.add);
      addTearDown(subscription.cancel);
      platform.rateError = PlatformException(
        code: 'synthetic_rate_failed',
        message: 'https://private.invalid/video?token=secret',
        details: {'authorization': 'private-secret'},
      );
      await player.setRate(2);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.rate, 1.5);
      expect(player.controller!.value.playbackSpeed, 1.5);
      expect(events, isEmpty);
      final log = DiaryService.fullText
          .split('\n')
          .where((line) => line.contains('[PlaybackRate]'))
          .join();
      expect(
        log,
        contains(
          'requested=2.0 result=unconfirmed error=synthetic_rate_failed',
        ),
      );
      expect(log, isNot(contains('secret')));
      expect(log, isNot(contains('https://')));
      platform.rateError = null;
      await player.setRate(1);
      expect(player.state.rate, 1);
      expect(player.controller!.value.playbackSpeed, 1);
    },
  );

  test(
    'pending commands do not report the optimistic controller rate as applied',
    () async {
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-rate.mp4'));
      final gate = platform.rateGate = Completer<void>();
      final pending = player.setRate(1.5);
      await Future<void>.delayed(Duration.zero);
      expect(player.controller!.value.playbackSpeed, 1.5);
      expect(player.state.rate, 1);
      gate.complete();
      await pending;
      expect(player.state.rate, 1.5);
    },
  );

  test('late rate failure cannot roll back a newer rate request', () async {
    final player = LunaExoPlayer();
    addTearDown(player.dispose);
    await player.open(Media('file:///synthetic-rate.mp4'));
    final gate = platform.rateGate = Completer<void>();
    platform.rateError = PlatformException(code: 'synthetic_old_failure');
    final old = player.setRate(2);
    await Future<void>.delayed(Duration.zero);
    platform.rateGate = null;
    platform.rateError = null;
    await player.setRate(1.25);
    gate.complete();
    await old;
    expect(player.state.rate, 1.25);
    expect(player.controller!.value.playbackSpeed, 1.25);
  });

  test(
    'cancelled old-media rate replies cannot alter a replacement controller',
    () async {
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-old-rate.mp4'));
      final gate = platform.rateGate = Completer<void>();
      final old = player.setRate(2);
      await Future<void>.delayed(Duration.zero);
      platform.rateGate = null;
      await player.open(Media('file:///synthetic-new-rate.mp4'));
      await player.setRate(1.25);
      gate.complete();
      await old;
      expect(platform.created, 2);
      expect(player.state.rate, 1.25);
      expect(player.controller!.value.playbackSpeed, 1.25);
      expect(player.state.playing, true);
    },
  );

  test('rate remains configurable before a controller exists', () async {
    final player = LunaExoPlayer();
    addTearDown(player.dispose);
    await player.setRate(1.5);
    expect(player.controller, isNull);
    expect(player.state.rate, 1.5);
  });

  test(
    'native diagnostics distinguish actual speed and lifetime audio underruns',
    () async {
      messenger.setMockMethodCallHandler(
        LunaExoPlayer.diagnosticChannel,
        (_) async => {
          'nativeSpeed': 1.25,
          'nativePitch': 1.0,
          'audioDecoder': 'synthetic.audio',
          'audioUnderrunsTotal': 2,
          'statisticsScope': 'player-lifetime',
          'lastAudioUnderrunCurrentMedia': false,
        },
      );
      final player = LunaExoPlayer();
      addTearDown(player.dispose);
      await player.open(Media('file:///synthetic-rate.mp4'));
      await player.setRate(1.5);
      await player.reportNativeDiagnostics();
      expect(player.state.rate, 1.5);
      expect(DiaryService.fullText, contains('nativeSpeed=1.25'));
      expect(DiaryService.fullText, contains('nativePitch=1.0'));
      expect(DiaryService.fullText, contains('audioUnderrunsTotal=2'));
      expect(
        DiaryService.fullText,
        contains('statisticsScope=player-lifetime'),
      );
      expect(
        DiaryService.fullText,
        contains('lastAudioUnderrunCurrentMedia=false'),
      );
    },
  );
}
