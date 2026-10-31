import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;
import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class _DeferredEpisodeRepository extends RouteRepository {
  final _holds = <int, Completer<void>>{};
  final started = <int>[];

  @override
  PlaybackPlan plan(bool alternate) {
    final session = 'route-${primaryCalls + fallbackCalls}';
    active.add(session);
    return PlaybackPlan(
      url: 'file:///synthetic-$session.mp4',
      session: session,
      routeIndex: alternate ? 1 : 0,
      routeCount: 2,
      mediaType: 'mp4',
    );
  }

  Completer<void> hold(int episode) => _holds[episode] = Completer<void>();

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    started.add(episode.number);
    final hold = _holds.remove(episode.number);
    if (hold != null) await hold.future;
    return super.resolve(drama, episode, quality: quality);
  }
}

class _PlaybackEventPlayer extends ScriptedPlayer {
  void emitPausedEvent() => playingController.add(false);
}

const _drama = Drama(
  id: 'hongguo:tv-overlay',
  source: 'hongguo',
  title: '合成连续播放',
  episodes: 4,
);

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 24; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 350));
  await _settle(tester);
}

Future<LocalStore> _mount(
  WidgetTester tester,
  RouteRepository repository,
  Player player,
) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  final detail = DramaDetail(
    _drama,
    List.generate(4, (index) => Episode({'id': '${index + 1}'}, index + 1)),
  );
  await tester.pumpWidget(
    televisionHost(
      child: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              child: const Text('打开合成视频'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    detail: detail,
                    initialIndex: 0,
                    initialPosition: 7,
                    repository: repository,
                    store: store,
                    playerFactory: () => player,
                    videoBuilder: (controls) =>
                        ColoredBox(color: Colors.blueGrey, child: controls),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开合成视频'));
  await _settle(tester);
  await tester.pump(const Duration(milliseconds: 350));
  await _settle(tester);
  return store;
}

void _expectRecoveryActions(Matcher count) {
  expect(find.byKey(const ValueKey('tv-recovery-settings')), count);
  expect(find.byKey(const ValueKey('tv-recovery-back')), count);
}

Future<void> _dispose(WidgetTester tester, RouteRepository repository) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _settle(tester);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();

  expect(repository.active, isEmpty);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(mockPlayerDevice);

  testWidgets(
    'initial preparation keeps recovery actions and explicit settings',
    (tester) async {
      final repository = _DeferredEpisodeRepository();
      final pending = repository.hold(1);
      final platform = ScriptedPlayer();
      await _mount(tester, repository, Player(platformPlayer: platform));
      _expectRecoveryActions(findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tv-recovery-settings')));
      await _settle(tester);
      expect(find.text('播放设置'), findsWidgets);
      await _press(tester, LogicalKeyboardKey.escape);
      pending.complete();
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
      expect(platform.opened, hasLength(1));
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await _settle(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('播放设置'), findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      await _dispose(tester, repository);
    },
  );

  testWidgets('automatic next stays free of recovery actions while loading', (
    tester,
  ) async {
    final repository = _DeferredEpisodeRepository();
    final platform = _PlaybackEventPlayer();
    final store = await _mount(
      tester,
      repository,
      Player(platformPlayer: platform),
    );
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
    final pending = repository.hold(2);
    platform.finishEpisode();
    await _settle(tester);
    expect(repository.started, contains(2));
    _expectRecoveryActions(findsNothing);
    expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
    for (var index = 0; index < 3; index++) {
      await tester.pump(const Duration(milliseconds: 350));
      platform.emitPausedEvent();
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
    }
    pending.complete();
    await _settle(tester);
    _expectRecoveryActions(findsNothing);
    expect(platform.opened, hasLength(2));
    expect(platform.state.playing, isTrue);
    expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
    expect(store.history.first.episode, 1);
    expect(store.history.first.position, 120);
    await _dispose(tester, repository);
  });

  testWidgets(
    'manual next omits recovery shortcuts and keeps explicit controls',
    (tester) async {
      final repository = _DeferredEpisodeRepository();
      final platform = ScriptedPlayer();
      await _mount(tester, repository, Player(platformPlayer: platform));
      final pending = repository.hold(2);
      focusRemote(tester, find.byKey(const ValueKey('tv-next')));
      await _settle(tester);
      await _press(tester, LogicalKeyboardKey.select);
      _expectRecoveryActions(findsNothing);
      expect(repository.started, contains(2));
      pending.complete();
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
      focusRemote(tester, find.byKey(const ValueKey('tv-settings')));
      await _settle(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('播放设置'), findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      await _dispose(tester, repository);
    },
  );

  testWidgets('episode selection closes its dialog without loading shortcuts', (
    tester,
  ) async {
    final repository = _DeferredEpisodeRepository();
    final platform = ScriptedPlayer();
    await _mount(tester, repository, Player(platformPlayer: platform));
    final pending = repository.hold(2);
    await _press(tester, LogicalKeyboardKey.contextMenu);
    final second = find.byKey(const ValueKey('tv-select-episode-2'));
    focusRemote(tester, second);
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('tv-select-episode-2')), findsNothing);
    _expectRecoveryActions(findsNothing);
    pending.complete();
    await _settle(tester);
    expect(platform.opened, hasLength(2));
    _expectRecoveryActions(findsNothing);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
    await _dispose(tester, repository);
  });

  testWidgets(
    'failed next keeps error recovery and same-episode retry actions',
    (tester) async {
      final repository = _DeferredEpisodeRepository();
      final platform = ScriptedPlayer();
      await _mount(tester, repository, Player(platformPlayer: platform));
      final pending = repository.hold(2);
      await _press(tester, LogicalKeyboardKey.mediaTrackNext);
      _expectRecoveryActions(findsNothing);
      pending.completeError(AppFailure('合成切集失败', code: 'source_blocked'));
      await _settle(tester);
      expect(find.text('暂时无法播放'), findsOneWidget);
      _expectRecoveryActions(findsOneWidget);
      final retry = repository.hold(2);
      await tester.tap(find.text('重试播放'));
      await _settle(tester);
      _expectRecoveryActions(findsOneWidget);
      retry.complete();
      await _settle(tester);
      expect(find.text('暂时无法播放'), findsNothing);
      _expectRecoveryActions(findsNothing);
      expect(platform.state.playing, isTrue);
      await _dispose(tester, repository);
    },
  );

  testWidgets(
    'late next response after returning cannot restore the shortcuts',
    (tester) async {
      final repository = _DeferredEpisodeRepository();
      final platform = ScriptedPlayer();
      await _mount(tester, repository, Player(platformPlayer: platform));
      final pending = repository.hold(2);
      await _press(tester, LogicalKeyboardKey.mediaTrackNext);
      _expectRecoveryActions(findsNothing);
      expect(
        ModalRoute.of(
          tester.element(find.byType(PlayerScreen)),
        )!.popDisposition,
        RoutePopDisposition.pop,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      pending.complete();
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
      expect(find.text('打开合成视频'), findsOneWidget);
      expect(platform.disposed, isTrue);
      await _dispose(tester, repository);
    },
  );

  testWidgets('lifecycle pause during next cannot add the loading shortcuts', (
    tester,
  ) async {
    final repository = _DeferredEpisodeRepository();
    final platform = ScriptedPlayer();
    await _mount(tester, repository, Player(platformPlayer: platform));
    final pending = repository.hold(2);
    await _press(tester, LogicalKeyboardKey.mediaTrackNext);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester);
    _expectRecoveryActions(findsNothing);
    pending.complete();
    await _settle(tester);
    _expectRecoveryActions(findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    _expectRecoveryActions(findsNothing);
    await _dispose(tester, repository);
  });

  for (final automatic in [true, false]) {
    testWidgets('native smooth next, automatic=$automatic omits shortcuts', (
      tester,
    ) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = DiagnosticVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pending = Completer<Map<String, Object>>();
      var transitions = 0;
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method != 'transition') return {};
        transitions++;
        return pending.future;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          LunaExoPlayer.diagnosticChannel,
          null,
        ),
      );
      final repository = _DeferredEpisodeRepository();
      final player = LunaExoPlayer(television: () => true);
      await _mount(tester, repository, player);
      final controller = player.controller!;
      if (automatic) {
        controller.value = controller.value.copyWith(
          position: controller.value.duration,
        );
        platform.streams[0]!.add(
          VideoEvent(eventType: VideoEventType.completed),
        );
        await _settle(tester);
      } else {
        await _press(tester, LogicalKeyboardKey.mediaTrackNext);
      }
      expect(transitions, 1);
      _expectRecoveryActions(findsNothing);
      expect(find.text('正在准备播放'), findsNothing);
      await tester.pump(const Duration(milliseconds: 900));
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
      expect(find.text('正在衔接下一集…'), findsOneWidget);
      pending.complete({
        'durationMs': 120000,
        'width': 1920,
        'height': 1080,
        'elapsedMs': 120,
      });
      await _settle(tester);
      _expectRecoveryActions(findsNothing);
      expect(find.text('正在衔接下一集…'), findsNothing);
      expect(platform.created, 1);
      expect(player.state.playing, isTrue);
      await _dispose(tester, repository);
    });
  }
}
