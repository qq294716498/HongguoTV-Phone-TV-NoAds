import 'dart:async';

import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:duanju_app/tv_decoder_settings.dart';
import 'package:video_player_android/video_player_android.dart';
import 'package:video_player_android/src/messages.g.dart' as messages;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class DiagnosticVideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final disposed = <int>[];
  int created = 0;
  int peakLive = 0;
  bool initialize = true;
  final views = <VideoViewType>[];
  final decoders = <String?>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    views.add(options.viewType);
    final decoder = options.videoPlayerOptions;
    decoders.add(decoder is AndroidDecoderOptions ? decoder.decoderMode : null);
    final id = created++;
    final events = StreamController<VideoEvent>();
    streams[id] = events;
    if (streams.length > peakLive) peakLive = streams.length;
    if (initialize) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1920, 1080),
          duration: const Duration(minutes: 3),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    final events = streams.remove(playerId);
    if (events != null) unawaited(events.close());
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'per-player decoder options reach creation and codec serialization',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      TvDecoderMode? mode = TvDecoderMode.software;
      final player = LunaExoPlayer(
        decoderMode: () => mode,
        television: () => true,
      );
      await player.open(Media('file:///synthetic-soft-hevc.mp4'));
      mode = TvDecoderMode.hardware;
      await player.open(Media('file:///synthetic-hardware.mp4'));
      mode = null;
      await player.open(Media('file:///synthetic-system.mp4'));
      expect(platform.decoders, ['software', 'hardware', null]);
      expect(platform.peakLive, 1);
      final options = messages.CreationOptions(
        uri: 'file:///synthetic.mp4',
        httpHeaders: {},
        decoderMode: 'software',
      );
      expect(messages.CreationOptions.decode(options.encode()), options);
      expect(
        messages.CreationOptions.decode(options.encode()).decoderMode,
        'software',
      );
      await player.dispose();
    },
  );

  testWidgets(
    'TV compatibility output can be selected and persists while other playback preferences survive',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.25, quality: 720, danmaku: false),
      );
      expect(store.playbackPreferences.tvTextureOutput, false);
      TelevisionPlaybackSetting? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selection = await showDialog<TelevisionPlaybackSetting>(
                    context: context,
                    builder: (_) => TelevisionSettingsDialog(
                      speed: 1.25,
                      quality: 720,
                      qualities: const [720, 1080],
                      favorite: false,
                      onFavorite: () {},
                      tvTextureOutput: false,
                    ),
                  );
                },
                child: const Text('settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('tv-output-true')));
      await tester.tap(find.byKey(const ValueKey('tv-output-true')));
      await tester.pumpAndSettle();
      expect(selection?.tvTextureOutput, true);
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(
          tvTextureOutput: selection!.tvTextureOutput,
        ),
      );
      final restored = LocalStore(await SharedPreferences.getInstance());
      expect(restored.playbackPreferences.tvTextureOutput, true);
      expect(restored.playbackPreferences.speed, 1.25);
      expect(restored.playbackPreferences.quality, 720);
      expect(restored.playbackPreferences.danmaku, false);
      restored.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'playback diagnostics retain buffering metadata across native controller replacement and disposal',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      DiaryService.clear();
      final player = LunaExoPlayer();
      await player.open(Media('file:///synthetic-diagnostic.mp4'));
      expect(platform.created, 1);
      platform.streams[0]!.add(
        VideoEvent(
          eventType: VideoEventType.bufferingUpdate,
          buffered: [DurationRange(Duration.zero, const Duration(seconds: 60))],
        ),
      );
      platform.streams[0]!.add(
        VideoEvent(eventType: VideoEventType.bufferingStart),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(player.state.buffering, isTrue);
      await player.open(Media('file:///synthetic-diagnostic-next.mp4'));
      expect(DiaryService.fullText, contains('buffering=true'));
      expect(DiaryService.fullText, contains('bufferedAheadMs=60000'));
      expect(DiaryService.fullText, contains('bufferingCount=1'));
      expect(DiaryService.fullText, contains('uiBudgetMs='));
      expect(platform.created, 2);
      expect(platform.disposed, [0]);
      await player.dispose();
      expect(platform.disposed, [0, 1]);
      final entries = DiaryService.entries.length;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(DiaryService.entries.length, entries);
    },
  );
  test(
    'TV uses native output, compatibility and phone keep texture output; native diagnostics use the active player',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final requests = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
            call,
          ) async {
            expect(call.method, 'snapshot');
            requests.add((call.arguments as Map)['playerId'] as int);
            return {
              'decoder': 'synthetic.hardware.avc',
              'hardware': 'true',
              'output': 'surface-hybrid',
              'renderedTotal': 900,
              'droppedTotal': 7,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null),
      );
      var television = true;
      var texture = false;
      final player = LunaExoPlayer(
        television: () => television,
        textureOutput: () => texture,
      );
      DiaryService.clear();
      await player.open(Media('file:///synthetic-tv.mp4'));
      expect(platform.views, [VideoViewType.platformView]);
      await player.reportNativeDiagnostics();
      expect(requests, [0]);
      expect(DiaryService.fullText, contains('decoder=synthetic.hardware.avc'));
      expect(DiaryService.fullText, contains('droppedTotal=7'));
      texture = true;
      await player.open(
        Media(
          'file:///synthetic-compatibility.mp4',
          start: const Duration(seconds: 12),
        ),
        play: false,
      );
      expect(platform.views.last, VideoViewType.textureView);
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.state.playing, false);
      television = false;
      texture = false;
      await player.open(Media('file:///synthetic-phone.mp4'));
      expect(platform.views.last, VideoViewType.textureView);
      await player.reportNativeDiagnostics();
      expect(requests.last, 2);
      await player.dispose();
    },
  );
  test(
    'twenty episode changes release each decoder before allocating the next',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final player = LunaExoPlayer(television: () => true);
      for (var index = 0; index < 20; index++) {
        await player.open(Media('file:///synthetic-episode-$index.mp4'));
        expect(platform.streams.length, 1);
        expect(player.state.buffer, Duration.zero);
      }
      expect(platform.peakLive, 1);
      expect(platform.disposed.length, 19);
      await player.stop();
      expect(platform.streams, isEmpty);
      await player.open(Media('file:///synthetic-after-stop.mp4'));
      await player.dispose();
      expect(platform.disposed.length, 21);
    },
  );

  test(
    'an asynchronous source error reaches recovery once and the next episode can open',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final player = LunaExoPlayer();
      final errors = <String>[];
      final subscription = player.stream.error.listen(errors.add);
      await player.open(Media('file:///synthetic-runtime-error.mp4'));
      platform.streams[0]!.addError(
        PlatformException(
          code: 'VideoError',
          message: 'synthetic source expired',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.state.playing, false);
      expect(errors, ['synthetic source expired']);
      await player.open(Media('file:///synthetic-refreshed.mp4'));
      expect(player.state.playing, true);
      expect(platform.peakLive, 1);
      await player.dispose();
      await subscription.cancel();
    },
  );

  test(
    'initialization timeout releases the failed native player and allows retry',
    () async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform()..initialize = false;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final player = LunaExoPlayer(
        initializationTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        player.open(Media('file:///synthetic-timeout.mp4')),
        throwsA(isA<TimeoutException>()),
      );
      expect(platform.streams, isEmpty);
      platform.initialize = true;
      await player.open(Media('file:///synthetic-retry.mp4'));
      expect(player.state.playing, true);
      await player.dispose();
    },
  );
}
