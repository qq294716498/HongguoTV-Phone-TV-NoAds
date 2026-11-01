import 'dart:async';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_queue_contract.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart' show testPinHasher, testStore;
import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class _QueuePlayer extends ScriptedPlayer {
  _QueuePlayer({bool rawCompletionNotifications = false}) {
    if (rawCompletionNotifications) {
      final original = stream;
      stream = PlayerStream(
        original.playlist,
        original.playing,
        completedController.stream,
        original.position,
        original.duration,
        original.volume,
        original.rate,
        original.pitch,
        original.buffering,
        original.bufferingPercentage,
        original.buffer,
        original.playlistMode,
        original.shuffle,
        original.audioParams,
        original.videoParams,
        original.audioBitrate,
        original.audioDevice,
        original.audioDevices,
        original.track,
        original.tracks,
        original.width,
        original.height,
        original.subtitle,
        original.log,
        original.error,
      );
    }
  }

  int stops = 0;
  Completer<void>? heldSeek;
  Duration? requestedSeek;
  bool completeAtSeekEnd = false;

  @override
  Future<void> seek(Duration position) async {
    requestedSeek = position;
    final pending = heldSeek;
    final wasPlaying = state.playing;
    if (pending != null) await pending.future;
    await super.seek(position);
    if (pending != null) {
      state = state.copyWith(completed: false, playing: wasPlaying);
      completedController.add(false);
      playingController.add(wasPlaying);
    }
    if (completeAtSeekEnd &&
        state.duration > Duration.zero &&
        position >= state.duration) {
      finishEpisode();
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  void progress(Duration position, {Duration? buffer, bool buffering = false}) {
    state = state.copyWith(
      position: position,
      buffer: buffer ?? state.buffer,
      buffering: buffering,
    );
    positionController.add(position);
    bufferController.add(state.buffer);
    bufferingController.add(buffering);
  }

  void notifyCompleted(bool completed) => completedController.add(completed);

  void notifyPosition(Duration position) => positionController.add(position);

  void finishEarly() {
    state = state.copyWith(completed: true, playing: false);
    completedController.add(true);
    playingController.add(false);
  }

  void nativeNext({bool play = true, bool durationFirst = false}) {
    state = state.copyWith(
      position: Duration.zero,
      duration: const Duration(seconds: 90),
      buffer: const Duration(seconds: 20),
      completed: false,
      playing: play,
      buffering: false,
    );
    if (durationFirst) durationController.add(state.duration);
    positionController.add(Duration.zero);
    if (!durationFirst) durationController.add(state.duration);
    bufferController.add(state.buffer);
    completedController.add(false);
    playingController.add(play);
  }
}

class _QueueStage {
  const _QueueStage(this.current, this.next, this.identity, this.generation);

  final PlaybackPlan current;
  final PlaybackPlan next;
  final String identity;
  final int generation;
}

class _QueueDriver implements PlaybackQueueDriver {
  _QueueDriver(this.player);

  final _QueuePlayer player;
  final controller = StreamController<PlaybackQueueEvent>.broadcast(sync: true);
  final stages = <_QueueStage>[];
  final advances = <(String, bool)>[];
  final suspensions = <bool>[];
  final cleared = <String?>[];
  final heldClears = <String?, Completer<void>>{};
  bool acceptStage = true;
  bool activateOnAdvance = false;
  bool readyOnAdvance = false;
  bool disposed = false;
  Completer<bool>? heldAdvance;
  Completer<bool>? heldStage;
  Completer<void>? heldSuspend;
  void Function(bool)? onSuspend;

  Completer<void> holdClear(String identity) =>
      heldClears[identity] = Completer<void>();

  @override
  Stream<PlaybackQueueEvent> get events => controller.stream;

  @override
  Future<bool> stage({
    required PlaybackPlan current,
    required PlaybackPlan next,
    required String identity,
    required int generation,
  }) async {
    stages.add(_QueueStage(current, next, identity, generation));
    return heldStage?.future ?? acceptStage;
  }

  @override
  Future<bool> advance({required String identity, required bool play}) async {
    advances.add((identity, play));
    if (activateOnAdvance) {
      activate(stages.last, play: play);
      if (readyOnAdvance) event(stages.last, PlaybackQueueEventKind.ready);
    }
    return heldAdvance?.future ?? true;
  }

  void event(
    _QueueStage stage,
    PlaybackQueueEventKind kind, {
    String message = '',
  }) {
    if (disposed) return;
    controller.add(
      PlaybackQueueEvent(
        identity: stage.identity,
        generation: stage.generation,
        kind: kind,
        firstFrame: kind == PlaybackQueueEventKind.ready,
        message: message.isNotEmpty
            ? message
            : kind == PlaybackQueueEventKind.failed
            ? 'synthetic queue failure'
            : '',
      ),
    );
  }

  void activate(_QueueStage stage, {bool play = true}) {
    player.nativeNext(play: play);
    event(stage, PlaybackQueueEventKind.activated);
  }

  @override
  Future<void> suspend(bool paused) async {
    suspensions.add(paused);
    onSuspend?.call(paused);
    if (paused) await heldSuspend?.future;
  }

  @override
  Future<void> clear({String? identity}) async {
    cleared.add(identity);
    await heldClears.remove(identity)?.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

class _QueueRepository extends RouteRepository {
  final preloadedEpisodes = <int>[];
  final released = <String>[];
  final paused = <(String, bool)>[];
  final danmakuSessions = <String>[];
  final episodesBySession = <String, int>{};
  final heldReleases = <String, Completer<void>>{};
  bool completePreload = true;
  int failedResumes = 0;
  int serial = 0;

  Completer<void> holdRelease(String session) =>
      heldReleases[session] = Completer<void>();

  PlaybackPlan _plan(int episode, {bool preload = false, int quality = 0}) {
    final session = 'queue-${++serial}-episode-$episode';
    active.add(session);
    episodesBySession[session] = episode;
    return PlaybackPlan(
      url: 'http://127.0.0.1:8765/$session/media.mp4',
      session: session,
      danmakuId: '${1000 + episode}',
      quality: quality == 0 ? 1080 : quality,
      qualities: const [1080, 720],
      routeCount: 2,
      mediaType: 'mp4',
      preloadComplete: preload && completePreload,
      startupReady: preload,
      preloadState: preload ? (completePreload ? 'complete' : 'caching') : '',
      prefetchedBytes: preload ? 65536 : 0,
    );
  }

  @override
  PlaybackPlan plan(bool alternate) => _plan(requestedEpisodes.last);

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    preloadedEpisodes.add(episode.number);
    return _plan(episode.number, preload: true, quality: quality);
  }

  @override
  Future<void> setPreloadPaused(
    Drama drama,
    PlaybackPlan plan,
    bool pause,
  ) async {
    paused.add((plan.session, pause));
    if (!pause && failedResumes > 0) {
      failedResumes--;
      throw StateError('synthetic resume failure');
    }
  }

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    danmakuSessions.add(plan.session);
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: durationMs,
      items: const [],
    );
  }

  @override
  Future<void> release(String session) async {
    released.add(session);
    await heldReleases.remove(session)?.future;
    await super.release(session);
  }
}

class _HeldWatchStore extends LocalStore {
  _HeldWatchStore(super.preferences) : super(pinHasher: testPinHasher);

  bool holdTailWrite = false;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> saveWatch(WatchEntry entry) async {
    if (holdTailWrite && entry.episode == 1 && entry.position == 119) {
      holdTailWrite = false;
      writeStarted.complete();
      await releaseWrite.future;
    }
    await super.saveWatch(entry);
  }
}

class _Harness {
  _Harness(this.repository, this.platform, this.driver, this.store);

  final _QueueRepository repository;
  final _QueuePlayer platform;
  final _QueueDriver driver;
  final LocalStore store;

  TelevisionControls controls(WidgetTester tester) =>
      tester.widget<TelevisionControls>(find.byType(TelevisionControls));

  PlayerControls mobileControls(WidgetTester tester) =>
      tester.widget<PlayerControls>(find.byType(PlayerControls));

  void togglePlayback(WidgetTester tester) =>
      find.byType(TelevisionControls).evaluate().isNotEmpty
      ? controls(tester).onTogglePlayback()
      : mobileControls(tester).onTogglePlayback();

  void next(WidgetTester tester) =>
      find.byType(TelevisionControls).evaluate().isNotEmpty
      ? controls(tester).onNext!()
      : mobileControls(tester).onNext!();

  Future<void> seek(WidgetTester tester, Duration position) =>
      find.byType(TelevisionControls).evaluate().isNotEmpty
      ? controls(tester).onSeekTo!(position)
      : mobileControls(tester).onSeek!(position);

  String title(WidgetTester tester) {
    if (find.byType(TelevisionControls).evaluate().isNotEmpty) {
      return controls(tester).title;
    }
    final mobileControls = tester.widget<PlayerControls>(
      find.byType(PlayerControls),
    );
    return '${mobileControls.title} · ${mobileControls.episodeLabel}';
  }
}

Widget _queueHost({required Widget child, required bool television}) =>
    television
    ? televisionHost(child: child)
    : MaterialApp(home: AppLayout(television: false, child: child));

Future<void> _pump(WidgetTester tester, [int frames = 24]) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _pump(tester);
}

Future<void> _selectEpisode(
  WidgetTester tester,
  _Harness harness,
  int episode,
) async {
  unawaited(harness.controls(tester).onEpisodes());
  await _pump(tester);
  focusRemote(tester, find.byKey(ValueKey('tv-select-episode-$episode')));
  await _pump(tester);
  await _press(tester, LogicalKeyboardKey.select);
}

Future<_Harness> _mount(
  WidgetTester tester, {
  _QueueRepository? repository,
  bool protected = false,
  bool television = true,
  bool preload = true,
  bool autoAdvance = true,
  double initialPosition = 0,
  bool rawCompletionNotifications = false,
  LocalStore Function(SharedPreferences)? storeFactory,
}) async {
  tester.view.physicalSize = television
      ? const Size(960, 540)
      : const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final store = (storeFactory ?? testStore)(
    await SharedPreferences.getInstance(),
  );
  addTearDown(store.dispose);
  if (protected) {
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: [],
      download: true,
      pin: '123456',
    );
  }
  if (!preload || !autoAdvance) {
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(
        preload: preload,
        autoAdvance: autoAdvance,
      ),
    );
  }
  final repo = repository ?? _QueueRepository();
  final platform = _QueuePlayer(
    rawCompletionNotifications: rawCompletionNotifications,
  );
  final player = Player(platformPlayer: platform);
  final driver = _QueueDriver(platform);
  final harness = _Harness(repo, platform, driver, store);
  const drama = Drama(
    id: 'hongguo:queue-handoff',
    source: 'hongguo',
    title: '合成队列交接',
    episodes: 4,
  );
  final detail = DramaDetail(
    drama,
    List.generate(4, (index) => Episode({'id': '${index + 1}'}, index + 1)),
  );
  await tester.pumpWidget(
    _queueHost(
      television: television,
      child: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(
                  detail: detail,
                  initialIndex: 0,
                  initialPosition: initialPosition,
                  repository: repo,
                  store: store,
                  playerFactory: () => player,
                  queueDriverFactory: (_) => driver,
                  videoBuilder: (controls) =>
                      ColoredBox(color: Colors.blueGrey, child: controls),
                ),
              ),
            ),
            child: const Text('打开队列视频'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开队列视频'));
  await _pump(tester);
  await tester.pump(const Duration(milliseconds: 350));
  await _pump(tester);
  expect(platform.opened, hasLength(1));
  return harness;
}

Future<void> _changePreferences(
  WidgetTester tester,
  _Harness harness, {
  bool? preload,
  bool? autoAdvance,
}) async {
  final television = find.byType(TelevisionControls).evaluate().isNotEmpty;
  final opening = television
      ? harness.controls(tester).onSettings()
      : harness.mobileControls(tester).onSettings!();
  unawaited(opening);
  await _pump(tester);
  if (television) {
    final dialog = tester.widget<TelevisionSettingsDialog>(
      find.byType(TelevisionSettingsDialog),
    );
    if (preload != null) expect(preload, !dialog.preload);
    if (autoAdvance != null) expect(autoAdvance, !dialog.autoAdvance);
    final choice = find.byKey(
      ValueKey(preload != null ? 'tv-preload-enabled' : 'tv-auto-advance'),
    );
    await tester.ensureVisible(choice);
    focusRemote(tester, choice);
    await _pump(tester);
    await _press(tester, LogicalKeyboardKey.select);
    await opening;
    await tester.pump(const Duration(milliseconds: 350));
    await _pump(tester);
    return;
  }
  final menuFinder = find.byType(PlayerMenu);
  expect(menuFinder, findsOneWidget);
  final menu = tester.widget<PlayerMenu>(menuFinder);
  await menu.onPreferences(
    menu.preferences.copyWith(preload: preload, autoAdvance: autoAdvance),
  );
  Navigator.of(tester.element(menuFinder)).pop();
  await _pump(tester);
  await opening;
  await tester.pump(const Duration(milliseconds: 350));
  await _pump(tester);
}

Future<_QueueStage> _arm(WidgetTester tester, _Harness harness) async {
  harness.platform.progress(
    const Duration(seconds: 10),
    buffer: const Duration(seconds: 30),
  );
  for (
    var attempt = 0;
    attempt < 30 && harness.driver.stages.isEmpty;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await _pump(tester);
  expect(harness.driver.stages, isNotEmpty);
  expect(harness.repository.preloadedEpisodes, [2]);
  return harness.driver.stages.last;
}

void _quiet() {
  expect(find.byKey(const ValueKey('tv-recovery-settings')), findsNothing);
  expect(find.byKey(const ValueKey('tv-recovery-back')), findsNothing);
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _pump(tester);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  expect(harness.driver.disposed, isTrue);
  expect(harness.platform.disposed, isTrue);
  expect(harness.repository.active, isEmpty);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(mockPlayerDevice);

  testWidgets(
    'native activation adopts one player and keeps old cache until ready',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      final initialStops = harness.platform.stops;
      await tester.pump(const Duration(seconds: 6));
      harness.platform.finishEpisode();
      await _pump(tester);
      _quiet();
      expect(harness.platform.opened, hasLength(1));
      harness.platform.nativeNext(durationFirst: true);
      await _pump(tester);
      harness.driver.event(stage, PlaybackQueueEventKind.activated);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(1));
      expect(harness.platform.stops, initialStops);
      expect(harness.store.history.single.episode, 1);
      expect(harness.store.history.single.position, 120);
      expect(harness.store.history.single.duration, 120);
      expect(
        harness.repository.active,
        containsAll([stage.current.session, stage.next.session]),
      );
      expect(
        harness.repository.released,
        isNot(contains(stage.current.session)),
      );
      _quiet();
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(
        harness.repository.released.where((s) => s == stage.current.session),
        hasLength(1),
      );
      expect(harness.repository.active, contains(stage.next.session));
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      harness.platform.progress(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 5));
      await _pump(tester);
      expect(harness.repository.danmakuSessions, contains(stage.next.session));
      expect(harness.store.history.single.episode, 2);
      expect(harness.store.history.single.position, 3);
      expect(harness.store.history.single.duration, 90);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'native activation before completed uses the previous progress snapshot',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.platform.progress(
        const Duration(seconds: 119),
        buffer: const Duration(seconds: 120),
      );
      await _pump(tester);
      harness.platform.nativeNext();
      await _pump(tester);
      harness.driver.event(stage, PlaybackQueueEventKind.activated);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.store.history, hasLength(1));
      expect(harness.store.history.single.episode, 1);
      expect(harness.store.history.single.position, 119);
      expect(harness.store.history.single.duration, 120);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      await tester.pump(const Duration(seconds: 3));
      await _pump(tester);
      expect(harness.platform.opened, hasLength(1));
      expect(harness.repository.released, contains(stage.current.session));
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'manual next waits for activation and deduplicates repeated intent',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.driver.heldAdvance = Completer<bool>();
      await _press(tester, LogicalKeyboardKey.mediaTrackNext);
      await _press(tester, LogicalKeyboardKey.mediaTrackNext);
      expect(harness.driver.advances, hasLength(1));
      expect(harness.platform.opened, hasLength(1));
      _quiet();
      harness.driver.activate(stage);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      harness.driver.heldAdvance!.complete(true);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(1));
      expect(harness.repository.requestedEpisodes, [1]);
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'activation before stage acknowledgement keeps the selected cache',
    (tester) async {
      final harness = await _mount(tester);
      harness.driver.heldStage = Completer<bool>();
      final stage = await _arm(tester, harness);
      final initialStops = harness.platform.stops;
      harness.driver.activate(stage);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      harness.driver.heldStage!.complete(true);
      await tester.pump(const Duration(seconds: 3));
      await _pump(tester);
      expect(harness.platform.opened, hasLength(1));
      expect(harness.platform.stops, initialStops);
      expect(harness.repository.active, contains(stage.next.session));
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      expect(harness.repository.released, contains(stage.current.session));
      await _dispose(tester, harness);
    },
  );

  testWidgets('automatic and manual next share one failed advance fallback', (
    tester,
  ) async {
    final harness = await _mount(tester);
    final stage = await _arm(tester, harness);
    harness.driver.heldAdvance = Completer<bool>();
    await _press(tester, LogicalKeyboardKey.mediaTrackNext);
    harness.platform.finishEpisode();
    await _pump(tester);
    expect(harness.driver.advances, hasLength(1));
    harness.driver.heldAdvance!.complete(false);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 1));
    await _pump(tester);
    expect(harness.controls(tester).title, contains('第 2 集'));
    expect(harness.platform.opened, hasLength(2));
    expect(harness.platform.opened.last.uri, stage.next.url);
    expect(harness.repository.requestedEpisodes, [1]);
    expect(harness.store.history.single.episode, 1);
    expect(harness.store.history.single.position, 120);
    expect(harness.repository.active, contains(stage.next.session));
    _quiet();
    await _dispose(tester, harness);
  });

  testWidgets(
    'unknown native state rebuilds the current episode at its saved position',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.platform.progress(
        const Duration(seconds: 18),
        buffer: const Duration(seconds: 38),
      );
      await _pump(tester);
      harness.platform.nativeNext();
      harness.driver.event(
        stage,
        PlaybackQueueEventKind.failed,
        message: 'queue_state_unknown',
      );
      await _pump(tester);
      await tester.pump(const Duration(seconds: 1));
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 1 集'));
      expect(harness.platform.opened, hasLength(2));
      expect(harness.platform.opened.last.uri, contains('episode-1/'));
      expect(harness.platform.opened.last.start, const Duration(seconds: 18));
      expect(harness.repository.requestedEpisodes, [1, 1]);
      expect(harness.repository.released, contains(stage.next.session));
      expect(
        harness.platform.opened.map((media) => media.uri),
        isNot(contains(stage.next.url)),
      );
      expect(harness.platform.state.playing, isTrue);
      expect(harness.store.history.single.episode, 1);
      expect(harness.store.history.single.position, 18);
      expect(harness.store.history.single.duration, 120);
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'ready waits for the public position reset before releasing the old cache',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.platform.finishEpisode();
      await _pump(tester);
      harness.driver.event(stage, PlaybackQueueEventKind.activated);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(
        harness.repository.released,
        isNot(contains(stage.current.session)),
      );
      expect(harness.store.history.single.position, 120);
      harness.platform.nativeNext();
      await _pump(tester);
      expect(harness.repository.released, contains(stage.current.session));
      expect(harness.platform.opened, hasLength(1));
      expect(harness.repository.active, contains(stage.next.session));
      await _dispose(tester, harness);
    },
  );

  testWidgets('one player can adopt two consecutive native queued episodes', (
    tester,
  ) async {
    final harness = await _mount(tester);
    final second = await _arm(tester, harness);
    final initialStops = harness.platform.stops;
    harness.platform.finishEpisode();
    await _pump(tester);
    harness.driver.activate(second);
    harness.driver.event(second, PlaybackQueueEventKind.ready);
    await _pump(tester);
    harness.platform.progress(
      const Duration(seconds: 3),
      buffer: const Duration(seconds: 30),
    );
    await _pump(tester);
    expect(harness.driver.stages, hasLength(2));
    final third = harness.driver.stages.last;
    expect(third.current.session, second.next.session);
    expect(harness.repository.preloadedEpisodes, [2, 3]);
    harness.platform.finishEpisode();
    await _pump(tester);
    harness.driver.activate(third);
    harness.driver.event(third, PlaybackQueueEventKind.ready);
    await _pump(tester);
    expect(harness.controls(tester).title, contains('第 3 集'));
    expect(harness.platform.opened, hasLength(1));
    expect(harness.platform.stops, initialStops);
    expect(harness.repository.requestedEpisodes, [1]);
    expect(harness.store.history.single.episode, 2);
    expect(harness.store.history.single.position, 90);
    expect(harness.repository.active, {third.next.session});
    expect(
      harness.repository.released.where((s) => s == second.current.session),
      hasLength(1),
    );
    expect(
      harness.repository.released.where((s) => s == third.current.session),
      hasLength(1),
    );
    await _dispose(tester, harness);
  });

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    for (final notification in ['completed', 'position']) {
      testWidgets(
        '$device late $notification from A cannot skip B C D at one second',
        (tester) async {
          final harness = await _mount(tester, television: television);
          try {
            harness.driver
              ..activateOnAdvance = true
              ..readyOnAdvance = true;
            final initialStops = harness.platform.stops;
            var stage = await _arm(tester, harness);
            harness.platform.finishEpisode();
            await _pump(tester);
            harness.driver.activate(stage);
            harness.driver.event(stage, PlaybackQueueEventKind.ready);
            await _pump(tester);

            for (var episode = 2; episode <= 3; episode++) {
              harness.platform.progress(
                const Duration(seconds: 1),
                buffer: const Duration(seconds: 30),
              );
              await _pump(tester);
              for (
                var attempt = 0;
                attempt < 30 &&
                    harness.repository.episodesBySession[harness
                            .driver
                            .stages
                            .last
                            .next
                            .session] !=
                        episode + 1;
                attempt++
              ) {
                await tester.pump(const Duration(milliseconds: 100));
              }
              stage = harness.driver.stages.last;
              expect(
                harness.repository.episodesBySession[stage.next.session],
                episode + 1,
              );
              expect(harness.title(tester), contains('第 $episode 集'));
              if (notification == 'completed') {
                harness.platform.notifyCompleted(true);
              } else {
                harness.platform.notifyPosition(const Duration(seconds: 120));
              }
              await _pump(tester);
              await tester.pump(const Duration(seconds: 1));
              await _pump(tester);
              expect(
                harness.title(tester),
                contains('第 $episode 集'),
                reason:
                    'a stale $notification does not identify the next media',
              );
              expect(harness.driver.advances, isEmpty);
              expect(
                harness.platform.state.duration,
                const Duration(seconds: 90),
              );
              expect(
                harness.platform.state.position,
                const Duration(seconds: 1),
              );
              expect(harness.platform.opened, hasLength(1));
              expect(harness.platform.stops, initialStops);
              expect(
                harness.store.history.single.episode,
                lessThanOrEqualTo(episode),
              );

              harness.platform.finishEpisode();
              await _pump(tester);
              harness.driver.activate(stage);
              harness.driver.event(stage, PlaybackQueueEventKind.ready);
              await _pump(tester);
              expect(harness.title(tester), contains('第 ${episode + 1} 集'));
              expect(harness.store.history.single.episode, episode);
              expect(harness.store.history.single.position, 90);
            }
            harness.platform.progress(
              const Duration(seconds: 1),
              buffer: const Duration(seconds: 30),
            );
            await _pump(tester);
            expect(harness.title(tester), contains('第 4 集'));
            expect(harness.platform.opened, hasLength(1));
            expect(harness.repository.requestedEpisodes, [1]);
            expect(harness.repository.preloadedEpisodes, [2, 3, 4]);
          } finally {
            await _dispose(tester, harness);
          }
        },
      );
    }

    testWidgets(
      '$device same-media position recovery at B does not select its queued successor',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          final second = await _arm(tester, harness);
          harness.platform.finishEpisode();
          await _pump(tester);
          harness.driver.activate(second);
          harness.driver.event(second, PlaybackQueueEventKind.ready);
          await _pump(tester);
          harness.platform.progress(
            const Duration(seconds: 3),
            buffer: const Duration(seconds: 30),
          );
          await _pump(tester);
          expect(harness.driver.stages, hasLength(2));
          harness.driver
            ..activateOnAdvance = true
            ..readyOnAdvance = true;
          harness.platform.progress(
            const Duration(seconds: 1),
            buffer: const Duration(seconds: 30),
          );
          await _pump(tester);
          await tester.pump(const Duration(seconds: 1));
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(harness.driver.advances, isEmpty);
          expect(harness.platform.state.position, const Duration(seconds: 1));
          expect(harness.platform.state.duration, const Duration(seconds: 90));
          expect(harness.platform.opened, hasLength(1));
          expect(harness.store.history.single.episode, lessThanOrEqualTo(2));
        } finally {
          await _dispose(tester, harness);
        }
      },
    );

    testWidgets(
      '$device premature completion at B recovers B instead of automatically selecting C',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          final second = await _arm(tester, harness);
          harness.platform.finishEpisode();
          await _pump(tester);
          harness.driver.activate(second);
          harness.driver.event(second, PlaybackQueueEventKind.ready);
          await _pump(tester);
          harness.platform.progress(
            const Duration(seconds: 1),
            buffer: const Duration(seconds: 30),
          );
          await _pump(tester);
          expect(harness.driver.stages, hasLength(2));
          harness.driver
            ..activateOnAdvance = true
            ..readyOnAdvance = true;
          harness.platform.finishEarly();
          await _pump(tester);
          await tester.pump(const Duration(seconds: 2));
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(harness.driver.advances, isEmpty);
          expect(
            harness.platform.opened.map((media) => media.uri),
            everyElement(isNot(contains('episode-3'))),
          );
          expect(harness.store.history.single.episode, lessThanOrEqualTo(2));
        } finally {
          await _dispose(tester, harness);
        }
      },
    );
  }

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    testWidgets('$device preload off preserves resumed four-episode playback', (
      tester,
    ) async {
      final harness = await _mount(
        tester,
        television: television,
        preload: false,
        initialPosition: 30,
        rawCompletionNotifications: true,
      );
      try {
        expect(
          harness.platform.opened.single.start,
          const Duration(seconds: 30),
        );
        for (var episode = 1; episode <= 4; episode++) {
          harness.platform.progress(
            Duration(seconds: episode == 1 ? 31 : 1),
            buffer: const Duration(seconds: 60),
          );
          await _pump(tester);
          final opened = harness.platform.opened.length;
          harness.platform.notifyCompleted(true);
          await tester.pump(const Duration(seconds: 2));
          await _pump(tester);
          expect(harness.title(tester), contains('第 $episode 集'));
          expect(harness.platform.opened, hasLength(opened));
          expect(harness.driver.stages, isEmpty);
          expect(harness.driver.advances, isEmpty);
          expect(harness.repository.preloadedEpisodes, isEmpty);
          if (episode < 4) {
            harness.platform.finishEpisode();
            await _pump(tester);
            await tester.pump(const Duration(milliseconds: 350));
            await _pump(tester);
            expect(harness.title(tester), contains('第 ${episode + 1} 集'));
          }
        }
        expect(harness.platform.opened, hasLength(4));
        expect(harness.repository.requestedEpisodes, [1, 2, 3, 4]);
      } finally {
        await _dispose(tester, harness);
      }
    });

    testWidgets('$device auto-advance off caches without arming native next', (
      tester,
    ) async {
      final harness = await _mount(
        tester,
        television: television,
        autoAdvance: false,
      );
      try {
        harness.platform.progress(
          const Duration(seconds: 3),
          buffer: const Duration(seconds: 30),
        );
        await tester.pump(const Duration(seconds: 3));
        await _pump(tester);
        expect(harness.repository.preloadedEpisodes, [2]);
        expect(harness.driver.stages, isEmpty);
        harness.platform.finishEpisode();
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.platform.opened, hasLength(1));
        expect(harness.driver.advances, isEmpty);
        harness.next(tester);
        await _pump(tester);
        expect(harness.title(tester), contains('第 2 集'));
        expect(harness.platform.opened, hasLength(2));
        expect(harness.driver.stages, isEmpty);
        expect(harness.repository.requestedEpisodes, [1]);
      } finally {
        await _dispose(tester, harness);
      }
    });

    testWidgets('$device changing preload and auto-advance takes effect live', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      try {
        final old = await _arm(tester, harness);
        await _changePreferences(tester, harness, preload: false);
        expect(harness.store.playbackPreferences.preload, false);
        expect(harness.driver.cleared, contains(old.identity));
        final disabledCount = harness.driver.stages.length;
        harness.platform.progress(
          const Duration(seconds: 12),
          buffer: const Duration(seconds: 40),
        );
        await tester.pump(const Duration(seconds: 3));
        await _pump(tester);
        expect(harness.driver.stages, hasLength(disabledCount));
        harness.driver.event(old, PlaybackQueueEventKind.activated);
        harness.driver.event(old, PlaybackQueueEventKind.ready);
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        await _changePreferences(tester, harness, preload: true);
        harness.platform.progress(
          const Duration(seconds: 12),
          buffer: const Duration(seconds: 40),
        );
        await tester.pump(const Duration(seconds: 3));
        await _pump(tester);
        expect(harness.store.playbackPreferences.preload, true);
        expect(harness.driver.stages.length, greaterThan(disabledCount));
        expect(harness.driver.stages.last.generation, isNot(old.generation));
        await _changePreferences(tester, harness, autoAdvance: false);
        expect(harness.store.playbackPreferences.autoAdvance, false);
        final noAutoCount = harness.driver.stages.length;
        harness.platform.progress(
          const Duration(seconds: 13),
          buffer: const Duration(seconds: 40),
        );
        await tester.pump(const Duration(seconds: 3));
        await _pump(tester);
        expect(harness.driver.stages, hasLength(noAutoCount));
        harness.platform.finishEpisode();
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.driver.advances, isEmpty);
        harness.next(tester);
        await _pump(tester);
        expect(harness.title(tester), contains('第 2 集'));
        await _changePreferences(tester, harness, autoAdvance: true);
        harness.platform.progress(
          const Duration(seconds: 3),
          buffer: const Duration(seconds: 30),
        );
        await tester.pump(const Duration(seconds: 3));
        await _pump(tester);
        expect(harness.store.playbackPreferences.autoAdvance, true);
        final third = harness.driver.stages.last;
        expect(harness.repository.episodesBySession[third.next.session], 3);
        harness.platform.finishEpisode();
        await _pump(tester);
        harness.driver.activate(third);
        harness.driver.event(third, PlaybackQueueEventKind.ready);
        await _pump(tester);
        expect(harness.title(tester), contains('第 3 集'));
      } finally {
        await _dispose(tester, harness);
      }
    });

    testWidgets('$device paused B ignores late completion and stays paused', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      try {
        final second = await _arm(tester, harness);
        harness.platform.finishEpisode();
        await _pump(tester);
        harness.driver.activate(second);
        harness.driver.event(second, PlaybackQueueEventKind.ready);
        await _pump(tester);
        harness.platform.progress(
          const Duration(seconds: 1),
          buffer: const Duration(seconds: 30),
        );
        await _pump(tester);
        expect(harness.driver.stages, hasLength(2));
        harness.togglePlayback(tester);
        await _pump(tester);
        expect(harness.platform.state.playing, false);
        harness.platform.notifyCompleted(true);
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 2 集'));
        expect(harness.platform.state.playing, false);
        expect(harness.driver.advances, isEmpty);
        expect(harness.platform.opened, hasLength(1));
      } finally {
        await _dispose(tester, harness);
      }
    });

    testWidgets(
      '$device seeking B retires pending C and ignores its late events',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          final second = await _arm(tester, harness);
          harness.platform.finishEpisode();
          await _pump(tester);
          harness.driver.activate(second);
          harness.driver.event(second, PlaybackQueueEventKind.ready);
          await _pump(tester);
          harness.platform.progress(
            const Duration(seconds: 3),
            buffer: const Duration(seconds: 30),
          );
          await _pump(tester);
          final oldThird = harness.driver.stages.last;
          await harness.seek(tester, const Duration(milliseconds: 500));
          await _pump(tester);
          harness.driver.event(oldThird, PlaybackQueueEventKind.activated);
          harness.driver.event(oldThird, PlaybackQueueEventKind.ready);
          await tester.pump(const Duration(seconds: 1));
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(
            harness.platform.state.position,
            const Duration(milliseconds: 500),
          );
          expect(harness.driver.advances, isEmpty);
          expect(harness.driver.cleared, contains(oldThird.identity));
          expect(harness.platform.opened, hasLength(1));
          harness.platform.progress(
            const Duration(seconds: 2),
            buffer: const Duration(seconds: 30),
          );
          await tester.pump(const Duration(seconds: 3));
          await _pump(tester);
          final resumed = harness.driver.stages.last;
          expect(resumed.generation, isNot(oldThird.generation));
          harness.platform.finishEpisode();
          await _pump(tester);
          harness.driver.activate(resumed);
          harness.driver.event(resumed, PlaybackQueueEventKind.ready);
          await _pump(tester);
          expect(harness.title(tester), contains('第 3 集'));
        } finally {
          await _dispose(tester, harness);
        }
      },
    );

    testWidgets('$device tail reset waits for delayed native identity', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      try {
        final second = await _arm(tester, harness);
        harness.platform.progress(
          const Duration(seconds: 119),
          buffer: const Duration(seconds: 120),
        );
        await _pump(tester);
        harness.platform.nativeNext();
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.driver.advances, isEmpty);
        harness.driver.event(second, PlaybackQueueEventKind.activated);
        harness.driver.event(second, PlaybackQueueEventKind.ready);
        await _pump(tester);
        expect(harness.title(tester), contains('第 2 集'));
        expect(harness.store.history.single.position, 119);
        expect(harness.platform.opened, hasLength(1));
      } finally {
        await _dispose(tester, harness);
      }
    });

    testWidgets('$device tail reset without native identity restores current', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      try {
        final second = await _arm(tester, harness);
        harness.platform.progress(
          const Duration(seconds: 119),
          buffer: const Duration(seconds: 120),
        );
        await _pump(tester);
        harness.platform.nativeNext();
        await tester.pump(const Duration(milliseconds: 3300));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.driver.advances, isEmpty);
        expect(harness.platform.opened, hasLength(2));
        expect(harness.platform.opened.last.uri, contains('episode-1'));
        expect(
          harness.platform.opened.last.start,
          const Duration(seconds: 119),
        );
        expect(harness.repository.requestedEpisodes, [1, 1]);
        harness.driver.event(second, PlaybackQueueEventKind.activated);
        harness.driver.event(second, PlaybackQueueEventKind.ready);
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(
          harness.platform.opened.map((media) => media.uri),
          everyElement(isNot(contains('episode-2'))),
        );
      } finally {
        await _dispose(tester, harness);
      }
    });
  }

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    for (final interruption in ['pause', 'background', 'menu']) {
      testWidgets('$device tail reset wait respects $interruption', (
        tester,
      ) async {
        final harness = await _mount(tester, television: television);
        Future<void>? menuOpening;
        try {
          final second = await _arm(tester, harness);
          harness.platform.progress(
            const Duration(seconds: 119),
            buffer: const Duration(seconds: 120),
          );
          await _pump(tester);
          harness.platform.nativeNext();
          await _pump(tester);
          expect(harness.title(tester), contains('第 1 集'));
          if (interruption == 'pause') {
            harness.togglePlayback(tester);
          } else if (interruption == 'background') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          } else {
            menuOpening = television
                ? harness.controls(tester).onSettings()
                : harness.mobileControls(tester).onSettings!();
            unawaited(menuOpening);
          }
          await _pump(tester);
          expect(harness.driver.cleared, contains(second.identity));
          final stopped = harness.platform.stops;
          await tester.pump(const Duration(seconds: 4));
          await _pump(tester);
          expect(harness.title(tester), contains('第 1 集'));
          expect(harness.platform.opened, hasLength(1));
          expect(harness.platform.stops, stopped);
          expect(harness.driver.advances, isEmpty);
          harness.driver.event(second, PlaybackQueueEventKind.activated);
          harness.driver.event(second, PlaybackQueueEventKind.ready);
          await _pump(tester);
          expect(harness.title(tester), contains('第 1 集'));
          expect(harness.platform.opened, hasLength(1));
          if (interruption == 'menu') {
            final menu = television
                ? find.byType(TelevisionSettingsDialog)
                : find.byType(PlayerMenu);
            expect(menu, findsOneWidget);
            Navigator.of(tester.element(menu)).pop();
            await _pump(tester);
            await menuOpening;
          } else {
            expect(harness.platform.state.playing, false);
          }
        } finally {
          if (interruption == 'background') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await _pump(tester);
          }
          await _dispose(tester, harness);
        }
      });
    }
  }

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    testWidgets('$device pending seek ignores old completion at the old tail', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      final seekGate = Completer<void>();
      Future<void>? seeking;
      try {
        await _arm(tester, harness);
        harness.platform.progress(
          const Duration(seconds: 119),
          buffer: const Duration(seconds: 120),
        );
        await _pump(tester);
        harness.platform.heldSeek = seekGate;
        seeking = harness.seek(tester, const Duration(seconds: 1));
        unawaited(seeking);
        for (
          var attempt = 0;
          attempt < 30 && harness.platform.requestedSeek == null;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(harness.platform.requestedSeek, const Duration(seconds: 1));
        expect(harness.platform.state.position, const Duration(seconds: 119));
        harness.platform.finishEpisode();
        await _pump(tester);
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.platform.opened, hasLength(1));
        expect(harness.repository.requestedEpisodes, [1]);
        expect(harness.driver.advances, isEmpty);
        seekGate.complete();
        await seeking;
        harness.platform.heldSeek = null;
        await _pump(tester);
        expect(harness.platform.state.position, const Duration(seconds: 1));
        expect(harness.platform.state.completed, false);
        final previousStages = harness.driver.stages.length;
        harness.platform.progress(
          const Duration(seconds: 119),
          buffer: const Duration(seconds: 120),
        );
        for (
          var attempt = 0;
          attempt < 30 && harness.driver.stages.length == previousStages;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await _pump(tester);
        final second = harness.driver.stages.last;
        harness.platform.finishEpisode();
        await _pump(tester);
        harness.driver.activate(second);
        harness.driver.event(second, PlaybackQueueEventKind.ready);
        await _pump(tester);
        expect(harness.title(tester), contains('第 2 集'));
        expect(harness.platform.opened, hasLength(1));
      } finally {
        if (!seekGate.isCompleted) seekGate.complete();
        await seeking;
        await _dispose(tester, harness);
      }
    });
  }

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    testWidgets('$device seek intent blocks completion before native seek', (
      tester,
    ) async {
      final harness = await _mount(tester, television: television);
      final suspendGate = Completer<void>();
      final seekGate = Completer<void>();
      Future<void>? seeking;
      try {
        await _arm(tester, harness);
        harness.platform.progress(
          const Duration(seconds: 119),
          buffer: const Duration(seconds: 120),
        );
        await _pump(tester);
        harness.driver.heldSuspend = suspendGate;
        harness.platform.heldSeek = seekGate;
        final suspended = harness.driver.suspensions.length;
        seeking = harness.seek(tester, const Duration(seconds: 1));
        unawaited(seeking);
        await _pump(tester);
        expect(harness.driver.suspensions.length, greaterThan(suspended));
        expect(harness.platform.requestedSeek, isNull);
        harness.platform.finishEpisode();
        await tester.pump(const Duration(seconds: 1));
        await _pump(tester);
        expect(harness.title(tester), contains('第 1 集'));
        expect(harness.driver.advances, isEmpty);
        expect(harness.platform.opened, hasLength(1));
        suspendGate.complete();
        seekGate.complete();
        await seeking;
        await _pump(tester);
        expect(harness.platform.state.position, const Duration(seconds: 1));
      } finally {
        if (!suspendGate.isCompleted) suspendGate.complete();
        if (!seekGate.isCompleted) seekGate.complete();
        harness.driver.heldSuspend = null;
        await seeking;
        await _dispose(tester, harness);
      }
    });

    testWidgets(
      '$device held progress recovery cannot overwrite a newer seek',
      (tester) async {
        late _HeldWatchStore store;
        final harness = await _mount(
          tester,
          television: television,
          storeFactory: (preferences) => store = _HeldWatchStore(preferences),
        );
        try {
          await _arm(tester, harness);
          harness.platform.progress(
            const Duration(seconds: 119),
            buffer: const Duration(seconds: 120),
          );
          await _pump(tester);
          store.holdTailWrite = true;
          harness.platform.nativeNext();
          await tester.pump(const Duration(milliseconds: 3300));
          await _pump(tester);
          expect(store.writeStarted.isCompleted, isTrue);
          expect(harness.platform.opened, hasLength(1));
          await harness.seek(tester, const Duration(seconds: 1));
          await _pump(tester);
          expect(harness.platform.state.position, const Duration(seconds: 1));
          store.releaseWrite.complete();
          await _pump(tester);
          expect(harness.title(tester), contains('第 1 集'));
          expect(harness.platform.opened, hasLength(1));
          expect(harness.platform.state.position, const Duration(seconds: 1));
          expect(harness.driver.advances, isEmpty);
        } finally {
          if (!store.releaseWrite.isCompleted) store.releaseWrite.complete();
          await _pump(tester);
          await _dispose(tester, harness);
        }
      },
    );

    testWidgets(
      '$device explicit seek to end preserves normal automatic next',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          await _arm(tester, harness);
          harness.platform.completeAtSeekEnd = true;
          await harness.seek(tester, const Duration(seconds: 120));
          await _pump(tester);
          await tester.pump(const Duration(milliseconds: 500));
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(harness.platform.opened, hasLength(2));
          expect(harness.platform.opened.last.uri, contains('episode-2'));
          expect(harness.store.history.single.episode, 1);
          expect(harness.store.history.single.position, 120);
          expect(harness.store.history.single.duration, 120);
        } finally {
          await _dispose(tester, harness);
        }
      },
    );
  }

  for (final television in [false, true]) {
    final device = television ? 'TV' : 'phone';
    testWidgets(
      '$device rounded buffered tail keeps the prepared native next',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          final second = await _arm(tester, harness);
          for (final position in [118, 119]) {
            harness.platform.progress(
              Duration(seconds: position),
              buffer: const Duration(milliseconds: 119987),
            );
            await _pump(tester);
            expect(
              harness.driver.cleared,
              isNot(contains(second.identity)),
              reason: '13ms buffer timestamp rounding does not mean starvation',
            );
            expect(
              harness.repository.released,
              isNot(contains(second.next.session)),
            );
            expect(harness.title(tester), contains('第 1 集'));
          }
          harness.driver.activate(second);
          harness.driver.event(second, PlaybackQueueEventKind.ready);
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(harness.platform.opened, hasLength(1));
          expect(harness.repository.requestedEpisodes, [1]);
          expect(harness.store.history.single.position, 119);
        } finally {
          await _dispose(tester, harness);
        }
      },
    );

    testWidgets(
      '$device a real buffer gap still suspends the cached native next',
      (tester) async {
        final harness = await _mount(tester, television: television);
        try {
          final second = await _arm(tester, harness);
          harness.platform.progress(
            const Duration(seconds: 11),
            buffer: const Duration(seconds: 12),
          );
          await _pump(tester);
          expect(harness.driver.suspensions.last, true);
          expect(harness.driver.cleared, contains(second.identity));
          expect(
            harness.repository.released,
            isNot(contains(second.next.session)),
          );
          expect(harness.title(tester), contains('第 1 集'));
          expect(harness.driver.advances, isEmpty);
          harness.platform.progress(
            const Duration(seconds: 11),
            buffer: const Duration(seconds: 31),
          );
          await tester.pump(const Duration(seconds: 3));
          await _pump(tester);
          final resumed = harness.driver.stages.last;
          expect(resumed.generation, isNot(second.generation));
          expect(resumed.next.session, second.next.session);
          harness.platform.finishEpisode();
          await _pump(tester);
          harness.driver.activate(resumed);
          harness.driver.event(resumed, PlaybackQueueEventKind.ready);
          await _pump(tester);
          expect(harness.title(tester), contains('第 2 集'));
          expect(harness.platform.opened, hasLength(1));
        } finally {
          await _dispose(tester, harness);
        }
      },
    );
  }

  testWidgets(
    'late old cache release cannot erase a newer selection or its queue',
    (tester) async {
      final harness = await _mount(tester);
      final second = await _arm(tester, harness);
      final releaseOld = harness.repository.holdRelease(second.current.session);
      harness.platform.finishEpisode();
      await _pump(tester);
      harness.driver.activate(second);
      harness.driver.event(second, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.repository.released, contains(second.current.session));
      expect(harness.repository.active, contains(second.current.session));
      expect(harness.controls(tester).enabled, isTrue);
      await _selectEpisode(tester, harness, 3);
      expect(harness.controls(tester).title, contains('第 3 集'));
      expect(harness.platform.opened, hasLength(2));
      harness.platform.progress(
        const Duration(seconds: 3),
        buffer: const Duration(seconds: 30),
      );
      await _pump(tester);
      final fourth = harness.driver.stages.last;
      expect(harness.repository.episodesBySession[fourth.next.session], 4);
      releaseOld.complete();
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 3 集'));
      expect(harness.driver.stages.last.identity, fourth.identity);
      expect(
        harness.repository.active,
        containsAll([fourth.current.session, fourth.next.session]),
      );
      expect(harness.repository.released, isNot(contains(fourth.next.session)));
      harness.platform.finishEpisode();
      await _pump(tester);
      harness.driver.activate(fourth);
      harness.driver.event(fourth, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 4 集'));
      expect(harness.platform.opened, hasLength(2));
      expect(harness.repository.requestedEpisodes, [1, 3]);
      expect(harness.repository.active, {fourth.next.session});
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'late release after a failed queue cannot replay its superseded episode',
    (tester) async {
      final harness = await _mount(tester);
      final second = await _arm(tester, harness);
      final releaseOld = harness.repository.holdRelease(second.current.session);
      harness.platform.finishEpisode();
      await _pump(tester);
      harness.driver.activate(second);
      harness.driver.event(second, PlaybackQueueEventKind.failed);
      await _pump(tester);
      expect(harness.repository.released, contains(second.current.session));
      expect(harness.repository.active, contains(second.current.session));
      expect(harness.platform.opened, hasLength(1));
      await _selectEpisode(tester, harness, 3);
      expect(harness.controls(tester).title, contains('第 3 集'));
      final selectedMedia = harness.platform.opened.last;
      releaseOld.complete();
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 3 集'));
      expect(harness.platform.opened, hasLength(2));
      expect(harness.platform.opened.last, same(selectedMedia));
      expect(harness.repository.requestedEpisodes, [1, 3]);
      expect(harness.repository.released, contains(second.next.session));
      expect(
        harness.platform.opened.map((media) => media.uri),
        isNot(contains(second.next.url)),
      );
      expect(harness.platform.state.playing, isTrue);
      await _dispose(tester, harness);
    },
  );

  testWidgets('exit during a frozen boundary saves the old episode snapshot', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await _arm(tester, harness);
    harness.platform.finishEpisode();
    await _pump(tester);
    harness.platform.nativeNext(durationFirst: true);
    harness.platform.progress(const Duration(milliseconds: 150));
    await _pump(tester);
    await _dispose(tester, harness);
    expect(harness.store.history, hasLength(1));
    expect(harness.store.history.single.episode, 1);
    expect(harness.store.history.single.position, 120);
    expect(harness.store.history.single.duration, 120);
  });

  testWidgets('rejected queue preparation falls back to the cached next plan', (
    tester,
  ) async {
    final harness = await _mount(tester);
    harness.driver.acceptStage = false;
    final stage = await _arm(tester, harness);
    harness.platform.finishEpisode();
    await _pump(tester);
    expect(harness.controls(tester).title, contains('第 2 集'));
    expect(harness.platform.opened, hasLength(2));
    expect(harness.platform.opened.last.uri, stage.next.url);
    expect(harness.repository.requestedEpisodes, [1]);
    expect(harness.driver.advances, isEmpty);
    expect(harness.store.history.single.episode, 1);
    expect(harness.store.history.single.position, 120);
    _quiet();
    await _dispose(tester, harness);
  });

  testWidgets(
    'native failure before activation keeps the cached fallback usable',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.driver.event(stage, PlaybackQueueEventKind.failed);
      await _pump(tester);
      expect(harness.platform.opened, hasLength(1));
      expect(harness.platform.state.playing, isTrue);
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      harness.platform.finishEpisode();
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(2));
      expect(harness.platform.opened.last.uri, stage.next.url);
      expect(harness.repository.requestedEpisodes, [1]);
      _quiet();
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'native load failure retries the selected episode with its cache',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      harness.platform.finishEpisode();
      await _pump(tester);
      harness.driver.activate(stage);
      harness.driver.event(stage, PlaybackQueueEventKind.failed);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(2));
      expect(harness.platform.opened.last.uri, stage.next.url);
      expect(harness.repository.requestedEpisodes, [1]);
      expect(harness.repository.active, contains(stage.next.session));
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      expect(harness.store.history.single.episode, 1);
      expect(harness.store.history.single.position, 120);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      harness.driver.event(stage, PlaybackQueueEventKind.failed);
      await _pump(tester);
      expect(harness.platform.opened, hasLength(2));
      _quiet();
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'activation during a suspension acknowledgement retains the active cache',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      final initialStops = harness.platform.stops;
      var activated = false;
      harness.driver.onSuspend = (paused) {
        if (!paused || activated) return;
        activated = true;
        harness.driver.activate(stage);
        harness.driver.event(stage, PlaybackQueueEventKind.ready);
      };
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 12),
        buffering: true,
      );
      await _pump(tester);
      await tester.pump(const Duration(seconds: 3));
      await _pump(tester);
      expect(activated, isTrue);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(1));
      expect(harness.platform.stops, initialStops);
      expect(harness.repository.released, contains(stage.current.session));
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      expect(harness.repository.active, contains(stage.next.session));
      expect(harness.platform.state.playing, isTrue);
      await _dispose(tester, harness);
    },
  );

  testWidgets('manual episode selection invalidates stale native events', (
    tester,
  ) async {
    final harness = await _mount(tester);
    final stage = await _arm(tester, harness);
    await _press(tester, LogicalKeyboardKey.contextMenu);
    focusRemote(tester, find.byKey(const ValueKey('tv-select-episode-3')));
    await _pump(tester);
    await _press(tester, LogicalKeyboardKey.select);
    expect(harness.controls(tester).title, contains('第 3 集'));
    expect(harness.repository.requestedEpisodes, [1, 3]);
    expect(harness.repository.released, contains(stage.next.session));
    harness.driver.event(stage, PlaybackQueueEventKind.activated);
    harness.driver.event(stage, PlaybackQueueEventKind.ready);
    harness.driver.event(stage, PlaybackQueueEventKind.failed);
    await _pump(tester);
    expect(harness.controls(tester).title, contains('第 3 集'));
    expect(harness.platform.opened, hasLength(2));
    expect(harness.repository.requestedEpisodes, [1, 3]);
    _quiet();
    await _dispose(tester, harness);
  });

  testWidgets(
    'quality change cancels the staged identity and keeps the current episode',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      unawaited(harness.controls(tester).onSettings());
      await _pump(tester);
      focusRemote(tester, find.byKey(const ValueKey('tv-quality-720')));
      await _pump(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(harness.repository.requestedEpisodes, [1, 1]);
      expect(harness.repository.requestedQualities.last, 720);
      expect(harness.repository.released, contains(stage.next.session));
      harness.driver.event(stage, PlaybackQueueEventKind.activated);
      harness.driver.event(stage, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 1 集'));
      expect(harness.platform.opened, hasLength(2));
      await _dispose(tester, harness);
    },
  );

  testWidgets('profile lock rejects a queued episode and its late activation', (
    tester,
  ) async {
    final harness = await _mount(tester, protected: true);
    final stage = await _arm(tester, harness);
    harness.store.lock();
    await _pump(tester);
    harness.driver.event(stage, PlaybackQueueEventKind.activated);
    harness.driver.event(stage, PlaybackQueueEventKind.ready);
    await _pump(tester);
    expect(harness.platform.opened, hasLength(1));
    expect(harness.platform.state.playing, isFalse);
    expect(harness.repository.released, contains(stage.next.session));
    expect(harness.store.history.where((entry) => entry.episode == 2), isEmpty);
    await _dispose(tester, harness);
  });

  testWidgets(
    'low current buffer pauses and resumes the existing next cache with hysteresis',
    (tester) async {
      final repository = _QueueRepository()..completePreload = false;
      final harness = await _mount(tester, repository: repository);
      harness.platform.progress(
        const Duration(seconds: 10),
        buffer: const Duration(seconds: 30),
      );
      await tester.pump(const Duration(seconds: 3));
      await _pump(tester);
      expect(repository.preloadedEpisodes, [2]);
      final nextSession = repository.episodesBySession.entries
          .singleWhere((e) => e.value == 2)
          .key;
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 12),
        buffering: true,
      );
      await _pump(tester);
      expect(repository.paused, [(nextSession, true)]);
      expect(repository.released, isNot(contains(nextSession)));
      for (var index = 0; index < 4; index++) {
        harness.platform.progress(
          const Duration(seconds: 11),
          buffer: const Duration(seconds: 14),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(repository.paused, [(nextSession, true)]);
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 31),
      );
      await tester.pump(const Duration(seconds: 3));
      await _pump(tester);
      expect(repository.paused, [(nextSession, true), (nextSession, false)]);
      expect(repository.preloadedEpisodes, [2]);
      expect(repository.active, contains(nextSession));
      expect(repository.released, isNot(contains(nextSession)));
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'backgrounding keeps the next cache and prevents automatic advance',
    (tester) async {
      final harness = await _mount(tester);
      final stage = await _arm(tester, harness);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _pump(tester);
      expect(harness.platform.state.playing, isFalse);
      expect(harness.driver.suspensions.last, isTrue);
      expect(harness.repository.released, isNot(contains(stage.next.session)));
      harness.platform.finishEpisode();
      await _pump(tester);
      expect(harness.driver.advances, isEmpty);
      expect(harness.platform.opened, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pump(tester);
      expect(harness.platform.state.playing, isFalse);
      expect(harness.repository.preloadedEpisodes, [2]);
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'suspension retires the old native candidate before restaging its cache',
    (tester) async {
      final harness = await _mount(tester);
      final previous = await _arm(tester, harness);
      final initialStops = harness.platform.stops;
      final cleared = harness.driver.holdClear(previous.identity);
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 12),
        buffering: true,
      );
      await _pump(tester);
      expect(harness.driver.suspensions.last, isTrue);
      expect(harness.driver.cleared, [previous.identity]);
      expect(
        harness.repository.released,
        isNot(contains(previous.next.session)),
      );
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 31),
      );
      await _pump(tester);
      expect(harness.driver.stages, hasLength(1));
      expect(harness.repository.preloadedEpisodes, [2]);
      cleared.complete();
      await _pump(tester);
      expect(harness.driver.stages, hasLength(2));
      final resumed = harness.driver.stages.last;
      expect(resumed.identity, previous.identity);
      expect(resumed.generation, isNot(previous.generation));
      expect(resumed.next.session, previous.next.session);
      harness.driver.event(previous, PlaybackQueueEventKind.activated);
      harness.driver.event(previous, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 1 集'));
      expect(harness.platform.opened, hasLength(1));
      expect(
        harness.repository.released,
        isNot(contains(previous.next.session)),
      );
      harness.driver.activate(resumed);
      harness.driver.event(resumed, PlaybackQueueEventKind.ready);
      await _pump(tester);
      expect(harness.controls(tester).title, contains('第 2 集'));
      expect(harness.platform.opened, hasLength(1));
      expect(harness.platform.stops, initialStops);
      expect(harness.repository.preloadedEpisodes, [2]);
      expect(harness.repository.active, {resumed.next.session});
      await _dispose(tester, harness);
    },
  );

  testWidgets(
    'a transient prefetch resume failure retries without losing its cache',
    (tester) async {
      final repository = _QueueRepository()..completePreload = false;
      final harness = await _mount(tester, repository: repository);
      harness.platform.progress(
        const Duration(seconds: 10),
        buffer: const Duration(seconds: 30),
      );
      await _pump(tester);
      final nextSession = repository.episodesBySession.entries
          .singleWhere((e) => e.value == 2)
          .key;
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 12),
        buffering: true,
      );
      await _pump(tester);
      repository.failedResumes = 1;
      harness.platform.progress(
        const Duration(seconds: 11),
        buffer: const Duration(seconds: 31),
      );
      await _pump(tester);
      expect(repository.paused, [(nextSession, true), (nextSession, false)]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3100)),
      );
      await tester.pump(const Duration(seconds: 4));
      harness.platform.progress(
        const Duration(seconds: 12),
        buffer: const Duration(seconds: 32),
      );
      await tester.pump(const Duration(seconds: 4));
      await _pump(tester);
      expect(repository.paused, [
        (nextSession, true),
        (nextSession, false),
        (nextSession, false),
      ]);
      expect(repository.preloadedEpisodes, [2]);
      expect(repository.active, contains(nextSession));
      expect(repository.released, isNot(contains(nextSession)));
      await _dispose(tester, harness);
    },
  );

  testWidgets('return disposes the queue and releases all owned sessions', (
    tester,
  ) async {
    final harness = await _mount(tester);
    final stage = await _arm(tester, harness);
    await tester.pump(const Duration(seconds: 6));
    await _pump(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _pump(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(harness.driver.disposed, isTrue);
    harness.driver.event(stage, PlaybackQueueEventKind.activated);
    harness.driver.event(stage, PlaybackQueueEventKind.ready);
    await _pump(tester);
    expect(find.text('打开队列视频'), findsOneWidget);
    expect(harness.platform.opened, hasLength(1));
    await _dispose(tester, harness);
  });
}
