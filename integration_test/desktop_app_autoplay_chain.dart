import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/media_kit_playback_queue.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_queue_contract.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixtures.dart' show FixtureRepository, testStore;

enum DesktopAppAutoplayPlatform { windows, macos }

const _drama = Drama(
  id: 'hongguo:synthetic-app-chain',
  source: 'hongguo',
  title: 'Synthetic PlayerScreen autoplay chain',
  episodes: 4,
  releaseStatus: 'ongoing',
);

class _ChainPlayer extends Player {
  _ChainPlayer()
    : super(
        configuration: const PlayerConfiguration(
          bufferSize: 32 * 1024 * 1024,
          muted: true,
          logLevel: MPVLogLevel.error,
        ),
      );

  int openCalls = 0;
  int stopCalls = 0;
  bool disposalFinished = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
    await (platform! as NativePlayer).setProperty('ao', 'null');
    await super.open(playable, play: play);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    try {
      await super.dispose();
    } finally {
      disposalFinished = true;
    }
  }
}

class _TraceQueueDriver implements PlaybackQueueDriver {
  _TraceQueueDriver(this.delegate, this.record);

  final PlaybackQueueDriver delegate;
  final void Function(String, Map<String, Object?>) record;

  @override
  Stream<PlaybackQueueEvent> get events => delegate.events;

  Future<T> _observe<T>(
    String operation,
    Map<String, Object?> fields,
    Future<T> Function() action,
  ) async {
    record(operation, {...fields, 'phase': 'before'});
    try {
      final result = await action();
      record(operation, {
        ...fields,
        'phase': 'after',
        if (result is bool) 'result': result,
      });
      return result;
    } catch (error) {
      record(operation, {...fields, 'phase': 'error', 'error': '$error'});
      rethrow;
    }
  }

  @override
  Future<bool> stage({
    required PlaybackPlan current,
    required PlaybackPlan next,
    required String identity,
    required int generation,
  }) => _observe(
    'stage',
    {'identity': identity, 'generation': generation},
    () => delegate.stage(
      current: current,
      next: next,
      identity: identity,
      generation: generation,
    ),
  );

  @override
  Future<bool> advance({required String identity, required bool play}) =>
      _observe('advance', {
        'identity': identity,
        'play': play,
      }, () => delegate.advance(identity: identity, play: play));

  @override
  Future<void> suspend(bool paused) =>
      _observe('suspend', {'paused': paused}, () => delegate.suspend(paused));

  @override
  Future<void> clear({String? identity}) => _observe('clear', {
    'identity': identity,
  }, () => delegate.clear(identity: identity));

  @override
  Future<void> dispose() => _observe('dispose', {}, delegate.dispose);
}

class _ChainRepository extends FixtureRepository {
  _ChainRepository(this.origin);
  final Uri origin;
  final resolvedEpisodes = <int>[];
  final preloadedEpisodes = <int>[];
  final released = <String>[];
  final sessionEpisodes = <String, int>{};
  int _sequence = 0;

  PlaybackPlan _plan(int episode) {
    final session = 'app-chain-${++_sequence}-episode-$episode';
    sessionEpisodes[session] = episode;
    return PlaybackPlan(
      url: origin.resolve('episode-$episode.mp4').toString(),
      session: session,
      mediaType: 'mp4',
      preloadComplete: true,
      startupReady: true,
      preloadState: 'complete',
    );
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolvedEpisodes.add(episode.number);
    return _plan(episode.number);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    preloadedEpisodes.add(episode.number);
    return _plan(episode.number);
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

void runDesktopAppAutoplayChain(DesktopAppAutoplayPlatform target) {
  final macOS = target == DesktopAppAutoplayPlatform.macos;
  final platformLabel = macOS ? 'macOS' : 'Windows';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '$platformLabel real PlayerScreen keeps every autoplay item past one second',
    (tester) async {
      expect(macOS ? Platform.isMacOS : Platform.isWindows, true);
      expect(const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'), true);
      if (macOS) {
        expect(defaultTargetPlatform, TargetPlatform.macOS);
        await AppDevice.prepareMacVideoOutput();
      }
      final macHardwareVideoOutput = AppDevice.macHardwareVideoOutput;
      final expectedHwdec = macOS && !macHardwareVideoOutput
          ? 'videotoolbox-copy'
          : 'auto';
      MediaKit.ensureInitialized();
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(960, 640));
      await windowManager.show();
      final directory = await Directory.systemTemp.createTemp(
        'hongguo-app-chain-',
      );
      final output = File(
        macOS
            ? 'dist/macos/macOS-app-autoplay-chain.json'
            : 'dist/windows/Windows-app-autoplay-chain.json',
      );
      await output.parent.create(recursive: true);
      final watch = Stopwatch()..start();
      final episodes = <Map<String, Object?>>[];
      final handoffs = <Map<String, Object?>>[];
      final queueEvents = <Map<String, Object?>>[];
      final nativeEvents = <Map<String, Object?>>[];
      final stateEvents = <Map<String, Object?>>[];
      final driverOperations = <Map<String, Object?>>[];
      final history = <Map<String, Object?>>[];
      final playbackErrors = <String>[];
      final requests = <Map<String, Object?>>[];
      final pendingRequests = <Future<void>>{};
      final failures = <String>[];
      final report = <String, Object?>{
        'ok': false,
        'nativeExecuted': macOS ? Platform.isMacOS : Platform.isWindows,
        if (macOS) ...{
          'platform': Platform.operatingSystem,
          'defaultTargetPlatform': defaultTargetPlatform.name,
          'allSources': const bool.fromEnvironment('ALL_SOURCES'),
          'dartAbi': Abi.current().toString(),
          'hostArchitecture': switch (Abi.current()) {
            Abi.macosArm64 => 'arm64',
            Abi.macosX64 => 'x86_64',
            final abi => abi.toString(),
          },
          'hardwareVideoOutput': macHardwareVideoOutput,
          'expectedHwdec': expectedHwdec,
        },
        'version': appVersion,
        'build': windowsBuildNumber,
        'sourceCommit': Platform.environment['GITHUB_SHA'] ?? '',
        'workflowRun': Platform.environment['GITHUB_RUN_ID'] ?? '',
        'playerCount': 0,
        'playerOpenCount': 0,
        'samePlayer': false,
        'nativeQueueVerified': false,
        'firstFrameMeasured': false,
        'physicalAudioVideoContinuityMeasured': false,
        'episodes': episodes,
        'handoffs': handoffs,
        'queueEvents': queueEvents,
        'nativeEvents': nativeEvents,
        'stateEvents': stateEvents,
        'stateEventsDropped': 0,
        'driverOperations': driverOperations,
        'driverOperationsDropped': 0,
        'fixtureAudioOutput': 'null',
        'history': history,
        'playbackErrors': playbackErrors,
        'requests': requests,
        'failures': failures,
      };
      _ChainPlayer? player;
      HttpServer? server;
      final subscriptions = <StreamSubscription<dynamic>>[];
      final files = <String, File>{};
      SharedPreferences.setMockInitialValues({});
      final store = testStore(await SharedPreferences.getInstance());
      _ChainRepository? repository;
      var mounted = false;
      var expectedHandle = 0;
      var initialStops = 0;
      Object? failure;

      Map<String, Object?> stateSnapshot() {
        final active = player;
        final state = active?.state;
        return {
          'elapsedMs': watch.elapsedMilliseconds,
          'positionMs': state?.position.inMilliseconds,
          'durationMs': state?.duration.inMilliseconds,
          'bufferMs': state?.buffer.inMilliseconds,
          'playing': state?.playing,
          'buffering': state?.buffering,
          'completed': state?.completed,
          'openCalls': active?.openCalls ?? 0,
          'nativeHandle': expectedHandle,
        };
      }

      void boundedRecord(
        List<Map<String, Object?>> destination,
        String droppedKey,
        Map<String, Object?> row,
      ) {
        if (destination.length == 512) {
          destination.removeAt(0);
          report[droppedKey] = (report[droppedKey] as int) + 1;
        }
        destination.add(row);
      }

      void recordState(String kind, [Object? payload]) => boundedRecord(
        stateEvents,
        'stateEventsDropped',
        {...stateSnapshot(), 'eventKind': kind, 'payload': payload},
      );

      void recordDriver(String operation, Map<String, Object?> fields) =>
          boundedRecord(driverOperations, 'driverOperationsDropped', {
            ...stateSnapshot(),
            'operation': operation,
            ...fields,
          });

      void require(bool value, String message) {
        if (!value) fail(message);
      }

      Future<void> until(
        Future<bool> Function() predicate,
        String phase, {
        Duration timeout = const Duration(seconds: 20),
      }) async {
        final deadline = watch.elapsed + timeout;
        while (!await predicate()) {
          if (watch.elapsed > deadline) fail('Timed out: $phase');
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      PlayerControls? controls() {
        final finder = find.byType(PlayerControls);
        return finder.evaluate().isEmpty
            ? null
            : tester.widget<PlayerControls>(finder.first);
      }

      int selectedEpisode() {
        final label = controls()?.episodeLabel ?? '';
        final match = RegExp(r'^第\s*(\d+)\s*集').firstMatch(label);
        return match == null ? 0 : int.parse(match[1]!);
      }

      Future<void> serve(HttpRequest request) async {
        final file = files[request.uri.path];
        if (file == null || !const {'GET', 'HEAD'}.contains(request.method)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final length = await file.length();
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = length - 1;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
          if (match == null || match[1]!.isEmpty && match[2]!.isEmpty) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$length',
            );
            await request.response.close();
            return;
          }
          if (match[1]!.isEmpty) {
            start = (length - int.parse(match[2]!)).clamp(0, length);
          } else {
            start = int.parse(match[1]!);
            if (match[2]!.isNotEmpty) {
              end = int.parse(match[2]!).clamp(0, length - 1);
            }
          }
          if (start > end || start >= length) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$length',
            );
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
        }
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = end - start + 1;
        requests.add({
          'elapsedMs': watch.elapsedMilliseconds,
          'path': request.uri.path,
          'range': range,
          'status': request.response.statusCode,
          'bytes': end - start + 1,
        });
        if (request.method == 'GET') {
          await request.response.addStream(file.openRead(start, end + 1));
        }
        await request.response.close();
      }

      store.addListener(() {
        final entry = store.watched(_drama.id);
        if (entry != null) {
          history.add({
            'elapsedMs': watch.elapsedMilliseconds,
            'episode': entry.episode,
            'positionMs': (entry.position * 1000).round(),
            'durationMs': (entry.duration * 1000).round(),
          });
        }
      });

      try {
        final ffmpeg = FFmpegExecutor();
        for (var index = 1; index <= 4; index++) {
          final file = File('${directory.path}/episode-$index.mp4');
          await ffmpeg.run([
            '-f',
            'lavfi',
            '-i',
            'color=c=${['0x6BCADE', '0xDAB866', '0x8BC985', '0x9B8AD9'][index - 1]}:s=640x360:r=30',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=${440 + index * 110}:sample_rate=48000',
            '-t',
            '5',
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
            '2',
            '-movflags',
            '+faststart',
            file.path,
          ]);
          require(await file.length() > 1000, 'Synthetic media is empty');
          files['/episode-$index.mp4'] = file;
        }
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          late final Future<void> pending;
          pending = serve(request)
              .catchError((Object error) {
                failures.add('Fixture HTTP: $error');
              })
              .whenComplete(() => pendingRequests.remove(pending));
          pendingRequests.add(pending);
        });
        repository = _ChainRepository(
          Uri.parse('http://127.0.0.1:${server.port}/'),
        );
        await store.setPlaybackPreferences(
          store.playbackPreferences.copyWith(
            preload: true,
            autoAdvance: true,
            danmaku: false,
          ),
        );
        final detail = DramaDetail(_drama, [
          for (var index = 1; index <= 4; index++)
            Episode({'id': 'synthetic-$index', 'title': '第$index集'}, index),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: AppLayout(
              television: false,
              child: PlayerScreen(
                detail: detail,
                initialIndex: 0,
                repository: repository,
                store: store,
                playerFactory: () {
                  report['playerCount'] = (report['playerCount'] as int) + 1;
                  final created = _ChainPlayer();
                  player = created;
                  subscriptions.add(
                    created.stream.error.listen((error) {
                      playbackErrors.add(error);
                      recordState('error', error);
                    }),
                  );
                  subscriptions.addAll([
                    created.stream.position.listen(
                      (value) => recordState('position', value.inMilliseconds),
                    ),
                    created.stream.duration.listen(
                      (value) => recordState('duration', value.inMilliseconds),
                    ),
                    created.stream.buffer.listen(
                      (value) => recordState('buffer', value.inMilliseconds),
                    ),
                    created.stream.playing.listen(
                      (value) => recordState('playing', value),
                    ),
                    created.stream.buffering.listen(
                      (value) => recordState('buffering', value),
                    ),
                    created.stream.completed.listen(
                      (value) => recordState('completed', value),
                    ),
                  ]);
                  return created;
                },
                queueDriverFactory: (owner) {
                  final transport = NativeMediaKitQueueTransport(owner);
                  subscriptions.add(
                    transport.events.listen((event) {
                      recordState('native.${event.kind.name}', event.entryId);
                      nativeEvents.add({
                        'elapsedMs': watch.elapsedMilliseconds,
                        'kind': event.kind.name,
                        'entryId': event.entryId,
                      });
                    }),
                  );
                  final driver = MediaKitPlaybackQueueDriver(
                    owner,
                    transport: transport,
                  );
                  subscriptions.add(
                    driver.events.listen((event) {
                      recordState('queue.${event.kind.name}', event.identity);
                      queueEvents.add({
                        'elapsedMs': watch.elapsedMilliseconds,
                        'identity': event.identity,
                        'episode': repository!.sessionEpisodes[event.identity],
                        'generation': event.generation,
                        'kind': event.kind.name,
                        'message': event.message,
                      });
                    }),
                  );
                  return _TraceQueueDriver(driver, recordDriver);
                },
              ),
            ),
          ),
        );
        mounted = true;
        final active = player!;
        final native = active.platform! as NativePlayer;
        expectedHandle = await active.handle;
        report['nativeHandle'] = expectedHandle;
        recordState('nativeHandleReady', expectedHandle);
        require(expectedHandle > 0, 'Native handle is missing');

        Future<double> nativePosition() async =>
            (double.tryParse(await native.getProperty('time-pos')) ?? 0) * 1000;
        Future<bool> pathIs(int episode) async =>
            Media.normalizeURI(await native.getProperty('path')) ==
            Media.normalizeURI(
              repository!.origin.resolve('episode-$episode.mp4').toString(),
            );

        for (var episode = 1; episode <= 4; episode++) {
          await until(() async {
            require(
              selectedEpisode() <= episode,
              'Episode $episode skipped before its one-second checkpoint',
            );
            return selectedEpisode() == episode &&
                controls()?.enabled == true &&
                await pathIs(episode) &&
                active.state.position.inMilliseconds >= 900 &&
                await nativePosition() >= 900;
          }, 'episode $episode one-second checkpoint');
          final publicPosition = active.state.position.inMilliseconds;
          final rawPosition = (await nativePosition()).round();
          require(
            publicPosition <= 2500 && rawPosition <= 2500,
            'Episode $episode missed its one-second observation',
          );
          require(
            await active.handle == expectedHandle && report['playerCount'] == 1,
            'Player changed at episode $episode',
          );
          require(
            controls()!.title == _drama.title,
            'Drama title changed at episode $episode',
          );
          require(
            find.byType(Video).evaluate().isNotEmpty,
            'Visible native video is missing',
          );
          final videoRect = tester.getRect(find.byType(Video).first);
          require(
            videoRect.width >= 100 && videoRect.height >= 100,
            'Native video layout is not visible',
          );
          if (episode == 1) initialStops = active.stopCalls;
          require(
            active.openCalls == 1 && active.stopCalls == initialStops,
            'Autoplay reopened or stopped Player at episode $episode',
          );
          final durationMs = active.state.duration.inMilliseconds;
          require(
            durationMs >= 4500,
            'Synthetic episode duration is truncated',
          );
          final row = <String, Object?>{
            'episode': episode,
            'ok': false,
            'observedAtOneSecond': true,
            'noEarlyAdvance': false,
            'title': controls()!.title,
            'episodeLabel': controls()!.episodeLabel,
            'positionAtOneSecondMs': publicPosition,
            'nativePositionAtOneSecondMs': rawPosition,
            'durationMs': durationMs,
            'nativeHandle': expectedHandle,
          };
          episodes.add(row);
          await until(
            () async {
              require(
                selectedEpisode() == episode,
                'Episode $episode advanced before its tail checkpoint',
              );
              return active.state.position.inMilliseconds >=
                      durationMs - 1000 &&
                  await nativePosition() >= durationMs - 1000;
            },
            'episode $episode tail checkpoint',
            timeout: const Duration(seconds: 10),
          );
          row['nearEndPositionMs'] = active.state.position.inMilliseconds;
          row['nativeNearEndPositionMs'] = (await nativePosition()).round();
          row['noEarlyAdvance'] = true;
          row['ok'] = true;
          if (episode < 4) {
            await until(
              () async =>
                  selectedEpisode() == episode + 1 &&
                  controls()?.enabled == true,
              'episode ${episode + 1} automatic adoption',
            );
            final activated = queueEvents
                .where(
                  (event) =>
                      event['episode'] == episode + 1 &&
                      event['kind'] == 'activated',
                )
                .toList();
            final ready = queueEvents
                .where(
                  (event) =>
                      event['episode'] == episode + 1 &&
                      event['kind'] == 'ready',
                )
                .toList();
            require(
              activated.length == 1 && ready.length == 1,
              'Episode ${episode + 1} did not use exactly one real native handoff',
            );
            await until(
              () async => history.any(
                (entry) =>
                    entry['episode'] == episode &&
                    (entry['positionMs'] as int) >= 3000,
              ),
              'previous episode $episode history',
            );
            final previous = history.lastWhere(
              (entry) => entry['episode'] == episode,
            );
            handoffs.add({
              'from': episode,
              'to': episode + 1,
              'identity': activated.single['identity'],
              'generation': activated.single['generation'],
              'activated': true,
              'ready': true,
              'nativeHandle': await active.handle,
              'previousHistoryPositionMs': previous['positionMs'],
            });
          }
        }
        await until(
          () async => active.state.completed && selectedEpisode() == 4,
          'final episode EOF',
        );
        await until(
          () async => history.any(
            (entry) =>
                entry['episode'] == 4 && (entry['positionMs'] as int) >= 4000,
          ),
          'final episode history',
        );
        require(
          active.openCalls == 1 && report['playerCount'] == 1,
          'Completed chain rebuilt the Player',
        );
        require(
          handoffs.length == 3 && episodes.every((row) => row['ok'] == true),
          'Incomplete autoplay chain',
        );
        require(
          repository.resolvedEpisodes.length == 1 &&
              repository.resolvedEpisodes.single == 1,
          'Autoplay bypassed cached queue plans',
        );
        var generation = 0;
        for (final handoff in handoffs) {
          require(
            (handoff['generation'] as int) > generation,
            'Queue generation did not advance',
          );
          generation = handoff['generation'] as int;
        }
        report['decoder'] = <String, String>{
          for (final key in [
            'mpv-version',
            'hwdec',
            'hwdec-current',
            'current-vo',
            'video-codec',
            'video-params/w',
            'video-params/h',
            'frame-drop-count',
            'decoder-frame-drop-count',
            'ao',
            'current-ao',
          ])
            key: await native.getProperty(key),
        };
        require(
          await native.getProperty('hwdec') == expectedHwdec,
          'Production $expectedHwdec decoder configuration was changed',
        );
        require(failures.isEmpty, 'Synthetic HTTP fixture failed');
        report['playerOpenCount'] = active.openCalls;
        report['samePlayer'] = await active.handle == expectedHandle;
        report['nativeQueueVerified'] = true;
        report['resolvedEpisodes'] = repository.resolvedEpisodes;
        report['preloadedEpisodes'] = repository.preloadedEpisodes;
        report['ok'] = true;
      } catch (error) {
        failure = error;
        failures.add(error.toString());
      } finally {
        report['playerOpenCount'] = player?.openCalls ?? 0;
        report['wallMs'] = watch.elapsedMilliseconds;
        try {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          if (mounted || player != null) {
            await tester.pumpWidget(const SizedBox.shrink());
            await until(
              () async => player?.disposalFinished ?? true,
              'Player disposal',
            );
          }
        } catch (error) {
          failure ??= error;
          failures.add('Player cleanup: $error');
        }
        try {
          await server?.close(force: true);
          await Future.wait(
            pendingRequests.toList(),
          ).timeout(const Duration(seconds: 5));
        } catch (error) {
          failure ??= error;
          failures.add('HTTP fixture cleanup: $error');
        }
        store.dispose();
        try {
          await directory.delete(recursive: true);
        } catch (error) {
          failure ??= error;
          failures.add('Synthetic fixture cleanup: $error');
        }
        if (failures.isNotEmpty) report['ok'] = false;
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }
      final problem = failure;
      if (problem != null) throw problem;
    },
    timeout: const Timeout(Duration(minutes: 5)),
    variant: macOS
        ? TargetPlatformVariant.only(TargetPlatform.macOS)
        : const DefaultTestVariant(),
  );
}
