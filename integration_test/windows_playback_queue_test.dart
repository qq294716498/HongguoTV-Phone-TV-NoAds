import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/media_kit_playback_queue.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/playback_queue_contract.dart';
import 'package:duanju_app/video_controller_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows native single-player queue handoff and recovery', (
    tester,
  ) async {
    expect(Platform.isWindows, true);
    expect(const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'), true);
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(960, 640));
    await windowManager.show();
    final directory = await Directory.systemTemp.createTemp('hongguo-queue-');
    final reportFile = File('dist/windows/Windows-playback-queue.json');
    await reportFile.parent.create(recursive: true);
    final cases = <Map<String, Object?>>[];
    final events = <Map<String, Object?>>[];
    final errors = <String>[];
    final nativeEvents = <Map<String, Object?>>[];
    final clock = Stopwatch()..start();
    Player? player;
    MediaKitPlaybackQueueDriver? driver;
    StreamSubscription<PlaybackQueueEvent>? subscription;
    StreamSubscription<MediaKitQueueNativeEvent>? nativeSubscription;
    var initialHandle = 0;
    final report = <String, Object?>{
      'ok': false,
      'nativeExecuted': Platform.isWindows,
      'version': appVersion,
      'build': windowsBuildNumber,
      'sourceCommit': Platform.environment['GITHUB_SHA'] ?? '',
      'workflowRun': Platform.environment['GITHUB_RUN_ID'] ?? '',
      'playerCount': 0,
      'physicalAudioVideoContinuityMeasured': false,
      'firstFrameMeasured': false,
      'eventBoundary': 'activated is native START_FILE; ready is FILE_LOADED',
      'cases': cases,
      'events': events,
      'nativeEvents': nativeEvents,
      'failures': errors,
    };

    Future<void> writeReport() => reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );

    Future<void> until(
      Future<bool> Function() ready,
      String phase, {
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final watch = Stopwatch()..start();
      while (!await ready()) {
        if (watch.elapsed > timeout) fail('Timed out: $phase');
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    try {
      final executor = FFmpegExecutor();
      final sources = <PlaybackPlan>[];
      for (var index = 0; index < 3; index++) {
        final changed = index == 2;
        final file = File('${directory.path}/episode-${index + 1}.mp4');
        await executor.run([
          '-f',
          'lavfi',
          '-i',
          'color=c=${['0x6BCADE', '0xDAB866', '0x8BC985'][index]}:s=${changed ? '480x270' : '640x360'}:r=${changed ? 24 : 30}',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=${440 + index * 110}:sample_rate=${changed ? 44100 : 48000}',
          '-t',
          '4',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-threads',
          '1',
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '-ac',
          changed ? '1' : '2',
          '-movflags',
          '+faststart',
          file.path,
        ]);
        expect(await file.length(), greaterThan(1000));
        sources.add(
          PlaybackPlan(
            url: file.uri.toString(),
            local: true,
            preloadComplete: true,
            mediaType: 'mp4',
            session: 'synthetic-${index + 1}',
          ),
        );
      }
      final broken = File('${directory.path}/not-media.mp4');
      await broken.writeAsString(
        'Synthetic malformed media for queue recovery',
      );
      final invalid = PlaybackPlan(
        url: broken.uri.toString(),
        local: true,
        preloadComplete: true,
        mediaType: 'mp4',
        session: 'synthetic-invalid',
      );
      final activePlayer = Player(
        configuration: const PlayerConfiguration(
          muted: true,
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      player = activePlayer;
      report['playerCount'] = 1;
      final video = VideoController(
        activePlayer,
        configuration: playbackVideoConfiguration(
          operatingSystem: 'windows',
          preferences: const PlaybackPreferences(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Video(controller: video, controls: NoVideoControls),
          ),
        ),
      );
      await video.platform.future;
      final native = activePlayer.platform! as NativePlayer;
      initialHandle = await activePlayer.handle;
      expect(initialHandle, greaterThan(0));
      report['nativeHandle'] = initialHandle;
      expect(await native.getProperty('hwdec'), 'auto');
      final transport = NativeMediaKitQueueTransport(activePlayer);
      expect(await transport.initialize(), true);
      nativeSubscription = transport.events.listen((event) {
        nativeEvents.add({
          'elapsedMs': clock.elapsedMilliseconds,
          'kind': event.kind.name,
          'entryId': event.entryId,
        });
      });
      final activeDriver = MediaKitPlaybackQueueDriver(
        activePlayer,
        transport: transport,
      );
      driver = activeDriver;
      subscription = activeDriver.events.listen((event) {
        events.add({
          'elapsedMs': clock.elapsedMilliseconds,
          'identity': event.identity,
          'generation': event.generation,
          'kind': event.kind.name,
          'firstFrame': event.firstFrame,
          'message': event.message,
          'positionMs': activePlayer.state.position.inMilliseconds,
        });
      });
      final originalPrefetch = await native.getProperty(
        'options/prefetch-playlist',
      );
      final queue = <PlaybackQueueEvent>[];
      final recorded = activeDriver.events.listen(queue.add);

      Future<String> property(String name) => native.getProperty(name);
      Future<bool> pathIs(PlaybackPlan plan) async =>
          Media.normalizeURI(await property('path')) ==
          Media.normalizeURI(plan.url);
      Future<void> singleCurrent(PlaybackPlan plan) async {
        await until(
          () async =>
              await property('playlist-count') == '1' &&
              await property('playlist-playing-pos') == '0' &&
              activePlayer.state.playlist.medias.length == 1 &&
              await pathIs(plan),
          'single current ${plan.session}',
        );
      }

      Future<void> open(PlaybackPlan plan, {bool play = true}) async {
        await activeDriver.clear();
        final loadedBefore = nativeEvents
            .where((event) => event['kind'] == 'loaded')
            .length;
        await activePlayer.open(Media(plan.url), play: play);
        await until(
          () async =>
              nativeEvents.where((event) => event['kind'] == 'loaded').length >
                  loadedBefore &&
              await pathIs(plan) &&
              activePlayer.state.duration.inMilliseconds >= 3500 &&
              (play
                  ? activePlayer.state.position.inMilliseconds >= 200 &&
                        activePlayer.state.position.inMilliseconds < 2000
                  : !activePlayer.state.playing &&
                        await property('pause') == 'yes'),
          'open ${plan.session}',
        );
        await singleCurrent(plan);
      }

      Future<void> loaded(String identity, int generation) async {
        await until(
          () async => queue.any(
            (event) =>
                event.identity == identity &&
                event.generation == generation &&
                event.kind == PlaybackQueueEventKind.ready,
          ),
          'loaded $identity',
        );
        final selected = queue
            .where(
              (event) =>
                  event.identity == identity && event.generation == generation,
            )
            .toList();
        expect(selected.map((event) => event.kind), [
          PlaybackQueueEventKind.activated,
          PlaybackQueueEventKind.ready,
        ]);
      }

      Future<void> stage(
        PlaybackPlan current,
        PlaybackPlan next,
        String identity,
        int generation,
      ) async {
        expect(
          await activeDriver.stage(
            current: current,
            next: next,
            identity: identity,
            generation: generation,
          ),
          true,
        );
        expect(await property('playlist-count'), '2');
      }

      Future<Map<String, String>> decoder() async {
        final values = <String, String>{};
        for (final name in [
          'mpv-version',
          'ffmpeg-version',
          'hwdec',
          'hwdec-current',
          'current-vo',
          'video-codec',
          'video-params/w',
          'video-params/h',
          'frame-drop-count',
          'decoder-frame-drop-count',
        ]) {
          try {
            values[name] = await property(name);
          } catch (_) {
            values[name] = 'unavailable';
          }
        }
        return values;
      }

      Future<void> runCase(String name, Future<void> Function() action) async {
        final before = await activePlayer.handle;
        final began = clock.elapsedMilliseconds;
        final eventOffset = events.length;
        Object? failure;
        try {
          await action();
          expect(await activePlayer.handle, initialHandle);
          expect(await activePlayer.handle, before);
        } catch (error, stack) {
          failure = error;
          errors.add('$name: $error');
          report['lastStack'] = stack.toString();
        }
        final after = await activePlayer.handle;
        cases.add({
          'case': name,
          'ok': failure == null,
          'samePlayer': before == after && after == initialHandle,
          'nativeHandleBefore': before,
          'nativeHandleAfter': after,
          'elapsedMs': clock.elapsedMilliseconds - began,
          'eventCount': events.length - eventOffset,
          'publicPlaying': activePlayer.state.playing,
          'publicPositionMs': activePlayer.state.position.inMilliseconds,
          'nativePause': await property('pause'),
          'decoder': await decoder(),
          if (failure != null) 'error': failure.toString(),
        });
        await writeReport();
      }

      try {
        await runCase('natural', () async {
          await open(sources[0]);
          await stage(sources[0], sources[1], 'natural-second', 1);
          await loaded('natural-second', 1);
          await singleCurrent(sources[1]);
          await stage(sources[1], sources[2], 'natural-third', 2);
          await loaded('natural-third', 2);
          await singleCurrent(sources[2]);
          await until(
            () async =>
                activePlayer.state.position.inMilliseconds > 200 &&
                activePlayer.state.position.inMilliseconds < 2000 &&
                activePlayer.state.width == 480 &&
                activePlayer.state.height == 270,
            'third episode advances with its decoded dimensions',
          );
          expect(await property('video-codec'), isNotEmpty);
          expect(find.byType(Texture), findsWidgets);
          expect(activePlayer.state.width, 480);
          expect(activePlayer.state.height, 270);
        });
        await runCase('manual-paused', () async {
          await open(sources[0], play: false);
          await stage(sources[0], sources[1], 'manual-second', 3);
          expect(
            await activeDriver.advance(identity: 'manual-second', play: false),
            true,
          );
          await loaded('manual-second', 3);
          await singleCurrent(sources[1]);
          expect(await property('pause'), 'yes');
          expect(activePlayer.state.playing, false);
          final position = activePlayer.state.position;
          final eventCount = events.length;
          expect(
            await activeDriver.advance(identity: 'manual-second', play: false),
            true,
          );
          await tester.pump(const Duration(milliseconds: 350));
          expect(await property('pause'), 'yes');
          expect(activePlayer.state.playing, false);
          expect(
            (activePlayer.state.position - position).inMilliseconds.abs(),
            lessThan(100),
          );
          expect(events.length, eventCount);
        });
        await runCase('suspend-resume', () async {
          await open(sources[0], play: false);
          await stage(sources[0], sources[1], 'suspended', 4);
          await activeDriver.suspend(true);
          await singleCurrent(sources[0]);
          expect(await property('options/prefetch-playlist'), originalPrefetch);
          await tester.pump(const Duration(milliseconds: 250));
          expect(
            queue.where((event) => event.identity == 'suspended'),
            isEmpty,
          );
          await activeDriver.suspend(false);
          expect(await property('playlist-count'), '2');
          await activeDriver.suspend(true);
          await activeDriver.clear(identity: 'suspended');
          await activeDriver.suspend(false);
          await singleCurrent(sources[0]);
          expect(await File.fromUri(Uri.parse(sources[1].url)).exists(), true);
          await stage(sources[0], sources[1], 'resumed', 5);
          expect(
            await activeDriver.advance(identity: 'resumed', play: false),
            true,
          );
          await loaded('resumed', 5);
          await singleCurrent(sources[1]);
          expect(
            queue.where((event) => event.identity == 'suspended'),
            isEmpty,
          );
          expect(await property('pause'), 'yes');
          expect(activePlayer.state.playing, false);
        });
        await runCase('failed-fallback', () async {
          await open(sources[0], play: false);
          final staged = await activeDriver.stage(
            current: sources[0],
            next: invalid,
            identity: 'invalid',
            generation: 6,
          );
          if (staged) {
            await activeDriver.advance(identity: 'invalid', play: true);
          }
          await until(
            () async => queue.any(
              (event) =>
                  event.identity == 'invalid' &&
                  event.generation == 6 &&
                  event.kind == PlaybackQueueEventKind.failed,
            ),
            'invalid media emits native failure',
          );
          expect(
            queue.where(
              (event) =>
                  event.identity == 'invalid' &&
                  event.kind == PlaybackQueueEventKind.ready,
            ),
            isEmpty,
          );
          await activeDriver.clear();
          await activePlayer.open(Media(sources[1].url));
          await until(
            () async =>
                await pathIs(sources[1]) &&
                activePlayer.state.playing &&
                activePlayer.state.position.inMilliseconds > 250,
            'ordinary open recovers after native queue failure',
          );
          await singleCurrent(sources[1]);
          expect(await property('video-codec'), isNotEmpty);
        });
      } finally {
        await recorded.cancel();
      }
      report['ok'] = errors.isEmpty && cases.length == 4;
    } catch (error, stack) {
      errors.add(error.toString());
      report['lastStack'] = stack.toString();
    } finally {
      await subscription?.cancel();
      await nativeSubscription?.cancel();
      try {
        await driver?.dispose();
      } catch (error) {
        report['ok'] = false;
        errors.add('queue cleanup: $error');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await player?.dispose();
      await directory.delete(recursive: true);
      await writeReport();
    }
    expect(report['ok'], true, reason: errors.join('\n'));
  });
}
