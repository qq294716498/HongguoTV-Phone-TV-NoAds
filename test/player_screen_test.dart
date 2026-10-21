import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

class PreloadingRouteRepository extends RouteRepository {
  final preloadedEpisodes = <int>[];

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    preloadedEpisodes.add(episode.number);
    final session = 'preloaded-${episode.number}';
    active.add(session);
    return PlaybackPlan(
      url: 'https://media.test/$session.mp4',
      session: session,
      prefetchedBytes: 4 << 20,
    );
  }
}

class DeferredSeekPlayer extends ScriptedPlayer {
  bool deferSeek = false;
  final pendingSeeks = <Completer<void>>[];
  final commands = <String>[];
  int resumeCalls = 0;

  @override
  Future<void> seek(Duration duration) async {
    commands.add('seek:${duration.inSeconds}');
    await super.seek(duration);
    if (deferSeek) {
      final pending = Completer<void>();
      pendingSeeks.add(pending);
      await pending.future;
    }
  }

  @override
  Future<void> play() async {
    commands.add('play');
    resumeCalls++;
    if (!state.playing) await super.playOrPause();
  }
}

class DeferredOpenPlayer extends ScriptedPlayer {
  final opening = Completer<void>();
  bool deferNext = true;
  int playCalls = 0;

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    await super.open(playable, play: play);
    if (deferNext) {
      deferNext = false;
      await opening.future;
    }
  }
}

class DeferredStopPlayer extends ScriptedPlayer {
  final stopping = Completer<void>();
  bool deferNextStop = false;

  @override
  Future<void> stop() async {
    await super.stop();
    if (deferNextStop) {
      deferNextStop = false;
      await stopping.future;
    }
  }
}

class BlockedRouteRepository extends RouteRepository {
  bool blocked = true;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    if (blocked) {
      primaryCalls++;
      throw AppFailure(
        '站源暂时限制访问',
        code: 'source_blocked',
        retryAt: DateTime.now().add(const Duration(seconds: 60)),
      );
    }
    return super.resolve(drama, episode, quality: quality);
  }
}

class DeferredResolveRouteRepository extends RouteRepository {
  final pendingResolve = Completer<PlaybackPlan>();
  bool deferFirst = true;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) {
    if (!deferFirst) return super.resolve(drama, episode, quality: quality);
    deferFirst = false;
    primaryCalls++;
    requestedQualities.add(quality);
    requestedEpisodes.add(episode.number);
    return pendingResolve.future;
  }
}

void main() {
  setUp(mockPlayerDevice);
  var previewFontsLoaded = false;
  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('portrait-capture')),
          )
          .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    RouteRepository repository,
    ScriptedPlayer platform, {
    Size? size,
    FakeViewPadding? padding,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final font = Platform.environment['HG_UI_FONT'];
    if (font != null && !previewFontsLoaded) {
      await tester.runAsync(() async {
        for (final entry in {
          'UiPreviewCJK': font,
          'Roboto': font,
          'MaterialIcons': Platform.environment['HG_UI_ICON_FONT'],
        }.entries) {
          if (entry.value == null) continue;
          final data = await File(entry.value!).readAsBytes();
          await (FontLoader(
            entry.key,
          )..addFont(Future.value(ByteData.sublistView(data)))).load();
        }
      });
      previewFontsLoaded = true;
    }
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
    }
    if (padding != null) {
      tester.view.padding = padding;
    }
    final store = LocalStore(await SharedPreferences.getInstance());
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('portrait-capture'),
        child: MaterialApp(
          theme: font == null
              ? AppTheme.dark
              : AppTheme.dark.copyWith(
                  textTheme: AppTheme.dark.textTheme.apply(
                    fontFamily: 'UiPreviewCJK',
                  ),
                ),
          home: PlayerScreen(
            detail: detail,
            initialIndex: 0,
            initialPosition: 7,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: platform),
            videoBuilder: (controls) =>
                ColoredBox(color: const Color(0xFF17212A), child: controls),
          ),
        ),
      ),
    );
    await settleOperations(tester);
    if (platform is DeferredSeekPlayer) {
      platform.resumeCalls = 0;
      platform.commands.clear();
    }
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    await settleOperations(tester);
    for (var i = 0; i < 95 && !player.disposalComplete; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(player.disposed, isTrue);
    expect(player.disposalComplete, isTrue);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'fully buffered current episode immediately preloads and reuses the next session',
    (tester) async {
      final repository = PreloadingRouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(960, 540));
      expect(repository.preloadedEpisodes, isEmpty);
      expect(player.state.position, const Duration(seconds: 7));
      player.buffered(player.state.duration);
      await settleOperations(tester);
      expect(repository.preloadedEpisodes, [2]);
      expect(repository.primaryCalls, 1);
      player.buffered(player.state.duration);
      await settleOperations(tester);
      expect(repository.preloadedEpisodes, [2]);
      player.finishEpisode();
      await settleOperations(tester);
      expect(repository.primaryCalls, 1);
      expect(player.opened.last.uri, 'https://media.test/preloaded-2.mp4');
      expect(repository.active, {'preloaded-2'});
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'duplicate errors switch once while keeping progress, rate and pause state',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await tester.tap(find.byKey(const ValueKey('player-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭菜单'));
      await tester.pumpAndSettle();
      await player.seek(const Duration(seconds: 28));
      await tester.pump();
      await tester.tap(find.byTooltip('暂停播放'));
      await settleOperations(tester);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      expect(repository.fallbackCalls, 1);
      expect(repository.primaryCalls, 1);
      expect(player.opened.last.start, const Duration(seconds: 28));
      expect(player.state.rate, 1.5);
      expect(player.played.last, isFalse);
      expect(repository.active.length, 1);
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'recovery exhaustion releases sessions and manual retry keeps the saved position',
    (tester) async {
      final repository = RouteRepository()..broken = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settleOperations(tester);
      }
      expect(repository.primaryCalls, 2);
      expect(repository.fallbackCalls, 2);
      expect(find.text('暂时无法播放'), findsOneWidget);
      expect(repository.active, isEmpty);
      await tester.pump(const Duration(seconds: 25));
      expect(repository.primaryCalls + repository.fallbackCalls, 4);
      repository.broken = false;
      await tester.tap(find.text('重试播放'));
      await settleOperations(tester);
      expect(player.opened.last.start, const Duration(seconds: 7));
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'switching episodes ignores a delayed fallback and frees both old plans',
    (tester) async {
      final repository = RouteRepository()..deferFallback = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      expect(repository.pending, isNotNull);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settleOperations(tester);
      final currentURL = player.opened.last.uri;
      final late = PlaybackPlan(
        url: 'https://media.test/late.mp4',
        session: 'late',
      );
      repository.active.add(late.session);
      repository.pending!.complete(late);
      await settleOperations(tester);
      expect(player.opened.last.uri, currentURL);
      expect(repository.active.length, 1);
      expect(repository.active, isNot(contains('late')));
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  for (final lateResult in ['success', 'failure']) {
    testWidgets(
      'switching episodes bypasses pending source retries and ignores late $lateResult',
      (tester) async {
        final repository = DeferredResolveRouteRepository();
        final player = ScriptedPlayer();
        await mount(tester, repository, player);
        expect(repository.requestedEpisodes, [1]);
        expect(repository.pendingResolve.isCompleted, false);
        expect(player.opened, isEmpty);
        await tester.tap(find.byKey(const ValueKey('play-episode-2')));
        await settleOperations(tester);
        expect(repository.requestedEpisodes, [1, 2]);
        expect(repository.pendingResolve.isCompleted, false);
        expect(player.opened, hasLength(1));
        expect(player.state.playing, true);
        expect(repository.active, hasLength(1));
        final current = player.opened.single.uri;
        final active = Set<String>.of(repository.active);
        if (lateResult == 'success') {
          const late = PlaybackPlan(
            url: 'https://media.test/late-source-retry.mp4',
            session: 'late-source-retry',
          );
          repository.active.add(late.session);
          repository.pendingResolve.complete(late);
        } else {
          repository.pendingResolve.completeError(
            AppFailure('Obsolete source retries exhausted'),
          );
        }
        await settleOperations(tester);
        expect(player.opened, hasLength(1));
        expect(player.opened.single.uri, current);
        expect(player.state.playing, true);
        expect(repository.active, active);
        expect(find.text('暂时无法播放'), findsNothing);
        expect(tester.takeException(), isNull);
        await unmount(tester, player);
        expect(repository.active, isEmpty);
      },
    );
  }

  testWidgets(
    'new episode bypasses an obsolete open and ignores its late completion',
    (tester) async {
      final repository = RouteRepository();
      final player = DeferredOpenPlayer();
      await mount(tester, repository, player);
      expect(repository.primaryCalls, 1);
      expect(player.opening.isCompleted, false);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settleOperations(tester);
      expect(repository.requestedEpisodes, [1, 2]);
      expect(player.opened, hasLength(2));
      expect(player.played, [false, false]);
      expect(player.playCalls, 1);
      final current = player.opened.last.uri;
      player.opening.complete();
      await settleOperations(tester);
      expect(player.opened.last.uri, current);
      expect(player.playCalls, 1);
      expect(repository.active, hasLength(1));
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'new episode bypasses a hung recovery stop without a fresh source request waiting',
    (tester) async {
      final repository = RouteRepository();
      final player = DeferredStopPlayer();
      await mount(tester, repository, player);
      for (var i = 0; i < 3; i++) {
        player.fail();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await settleOperations(tester);
      }
      player.deferNextStop = true;
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      expect(player.stopping.isCompleted, false);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settleOperations(tester);
      expect(repository.requestedEpisodes.last, 2);
      final current = player.opened.last.uri;
      player.stopping.complete();
      await settleOperations(tester);
      expect(player.opened.last.uri, current);
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets('leaving playback does not await or resume an obsolete open', (
    tester,
  ) async {
    final repository = RouteRepository();
    final player = DeferredOpenPlayer();
    await mount(tester, repository, player);
    await unmount(tester, player);
    expect(player.disposed, true);
    expect(repository.active, isEmpty);
    player.opening.complete();
    await settleOperations(tester);
    expect(player.playCalls, 0);
    expect(repository.active, isEmpty);
  });

  testWidgets('a pending open completed in background remains paused', (
    tester,
  ) async {
    final repository = RouteRepository();
    final player = DeferredOpenPlayer();
    await mount(tester, repository, player);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settleOperations(tester);
    player.opening.complete();
    await settleOperations(tester);
    expect(player.playCalls, 0);
    expect(player.state.playing, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await unmount(tester, player);
  });

  testWidgets(
    'a background pending open keeps its deadline and cannot resume late',
    (tester) async {
      final repository = RouteRepository();
      final player = DeferredOpenPlayer();
      await mount(tester, repository, player);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 46));
      await settleOperations(tester);
      expect(find.text('暂时无法播放'), findsOneWidget);
      player.opening.complete();
      await settleOperations(tester);
      expect(player.playCalls, 0);
      expect(repository.active, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await unmount(tester, player);
    },
  );

  for (final pause in ['user', 'background']) {
    testWidgets('$pause pause after readiness clears the startup deadline', (
      tester,
    ) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      if (pause == 'user') {
        tester
            .widget<PlayerControls>(find.byType(PlayerControls))
            .onTogglePlayback();
      } else {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
      await settleOperations(tester);
      expect(player.state.playing, false);
      await tester.pump(const Duration(seconds: 60));
      await settleOperations(tester);
      expect(find.text('暂时无法播放'), findsNothing);
      expect(repository.primaryCalls, 1);
      if (pause == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await unmount(tester, player);
    });
  }

  testWidgets(
    'hung startup exits with an actionable error within the shared budget',
    (tester) async {
      final repository = RouteRepository();
      final player = DeferredOpenPlayer();
      await mount(tester, repository, player);
      await tester.pump(const Duration(seconds: 46));
      await settleOperations(tester);
      expect(find.text('暂时无法播放'), findsOneWidget);
      expect(find.text('重试播放'), findsOneWidget);
      expect(repository.active, isEmpty);
      await tester.tap(find.text('重试播放'));
      await settleOperations(tester);
      expect(repository.primaryCalls, 2);
      expect(find.text('暂时无法播放'), findsNothing);
      player.opening.complete();
      await settleOperations(tester);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'blocked source stops automatic retries and preserves manual recovery',
    (tester) async {
      final repository = BlockedRouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      expect(find.textContaining('秒后手动重试'), findsOneWidget);
      await tester.pump(const Duration(seconds: 65));
      await settleOperations(tester);
      expect(repository.primaryCalls, 1);
      expect(repository.fallbackCalls, 0);
      repository.blocked = false;
      await tester.tap(find.text('重试播放'));
      await settleOperations(tester);
      expect(repository.primaryCalls, 2);
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
    },
  );

  testWidgets('picture-in-picture hides app overlay controls', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      switch (call.method) {
        case 'pictureInPictureStatus':
          return {'supported': true, 'active': false};
        case 'enterPictureInPicture':
          return {'supported': true, 'active': true, 'requested': true};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-portrait-episodes')),
        findsOneWidget,
      );
      expect(find.text('简介'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-picture-in-picture')));
      await tester.pump();
      await tester.pump();
      await settleOperations(tester);
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-speed')), findsNothing);
      expect(find.byKey(const ValueKey('player-quality')), findsNothing);
      expect(find.byKey(const ValueKey('player-progress')), findsNothing);
      expect(
        find.byKey(const ValueKey('player-portrait-episodes')),
        findsNothing,
      );
      expect(find.text('简介'), findsNothing);
      expect(find.text('下载'), findsNothing);
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'fullscreen transport seeks and advances through existing playback logic',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final repository = RouteRepository();
        final player = ScriptedPlayer();
        await mount(tester, repository, player, size: const Size(960, 540));
        player.videoSize(1920, 1080);
        await settleOperations(tester);
        await tester.tap(find.byKey(const ValueKey('player-mobile-forward')));
        await settleOperations(tester);
        expect(player.state.position, const Duration(seconds: 22));
        expect(player.opened.length, 1);
        await tester.tap(find.byKey(const ValueKey('player-mobile-next')));
        await settleOperations(tester);
        expect(player.opened.length, 2);
        expect(
          tester
              .widget<PlayerControls>(find.byType(PlayerControls))
              .episodeLabel,
          '第 2 集 / 共 2 集',
        );
        expect(player.state.position, Duration.zero);
        expect(player.state.playing, isTrue);
        await unmount(tester, player);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'portrait forward seeks first and resumes a paused screen exactly once',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final repository = RouteRepository();
        final player = DeferredSeekPlayer();
        await mount(tester, repository, player, size: const Size(390, 844));
        player.videoSize(1920, 1080);
        await settleOperations(tester);
        await tester.tap(find.byKey(const ValueKey('player-mobile-play')));
        await settleOperations(tester);
        expect(player.state.playing, isFalse);
        final forward = find.byKey(const ValueKey('player-mobile-forward'));
        await tester.tap(forward);
        await settleOperations(tester);
        expect(player.state.position, const Duration(seconds: 22));
        await tester.tap(forward);
        await settleOperations(tester);
        expect(player.state.position, const Duration(seconds: 37));
        expect(player.state.playing, isTrue);
        expect(player.resumeCalls, 1);
        expect(
          player.commands,
          containsAllInOrder(['seek:22', 'play', 'seek:37']),
        );
        expect(player.opened.length, 1);
        expect(find.byKey(const ValueKey('player-mobile-next')), findsNothing);
        await capture(tester, 'portrait-forward-fifteen');
        await unmount(tester, player);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('fullscreen forward resumes after the seek completes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final player = DeferredSeekPlayer();
      await mount(
        tester,
        RouteRepository(),
        player,
        size: const Size(960, 540),
      );
      player.videoSize(1920, 1080);
      await settleOperations(tester);
      await tester.tap(find.byKey(const ValueKey('player-mobile-play')));
      await settleOperations(tester);
      player.deferSeek = true;
      await tester.tap(find.byKey(const ValueKey('player-mobile-forward')));
      await settleOperations(tester);
      expect(player.pendingSeeks, hasLength(1));
      expect(player.state.playing, isFalse);
      expect(player.resumeCalls, 0);
      player.pendingSeeks.single.complete();
      await settleOperations(tester);
      expect(player.state.position, const Duration(seconds: 22));
      expect(player.state.playing, isTrue);
      expect(player.resumeCalls, 1);
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final interruption in [
    'newer seek',
    'manual pause',
    'background and return',
    'episode switch',
    'close',
    'seek failure',
  ]) {
    testWidgets('forward resume ignores $interruption during pending seek', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final player = DeferredSeekPlayer();
        await mount(
          tester,
          RouteRepository(),
          player,
          size: const Size(390, 844),
        );
        final play = find.byKey(const ValueKey('player-mobile-play'));
        final forward = find.byKey(const ValueKey('player-mobile-forward'));
        await tester.tap(play);
        await settleOperations(tester);
        expect(player.state.playing, isFalse);
        player.deferSeek = true;
        await tester.tap(forward);
        await settleOperations(tester);
        expect(player.pendingSeeks, hasLength(1));
        expect(player.resumeCalls, 0);
        switch (interruption) {
          case 'newer seek':
            await tester.tap(forward);
            await settleOperations(tester);
            expect(player.pendingSeeks, hasLength(2));
            break;
          case 'manual pause':
            await tester.tap(play);
            await settleOperations(tester);
            await tester.tap(play);
            await settleOperations(tester);
            expect(player.state.playing, isFalse);
            break;
          case 'background and return':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await settleOperations(tester);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await settleOperations(tester);
            break;
          case 'episode switch':
            player.deferSeek = false;
            tester
                .widget<PlayerControls>(find.byType(PlayerControls))
                .onNext!();
            await settleOperations(tester);
            expect(player.opened, hasLength(2));
            break;
          case 'close':
            await unmount(tester, player);
            break;
          case 'seek failure':
            player.pendingSeeks.first.completeError(
              StateError('synthetic seek failure'),
            );
            await settleOperations(tester);
            expect(player.resumeCalls, 0);
            expect(player.state.playing, isFalse);
            expect(find.text('跳转失败，请重试'), findsOneWidget);
            await unmount(tester, player);
            return;
        }
        final playCallsBeforeLateSeek = player.resumeCalls;
        expect(
          playCallsBeforeLateSeek,
          interruption == 'episode switch' ? 1 : 0,
        );
        player.pendingSeeks.first.complete();
        await settleOperations(tester);
        expect(player.resumeCalls, playCallsBeforeLateSeek);
        if (interruption == 'newer seek') {
          expect(player.state.playing, isFalse);
          player.pendingSeeks.last.complete();
          await settleOperations(tester);
          expect(player.state.playing, isTrue);
          expect(player.resumeCalls, 1);
          expect(player.state.position, const Duration(seconds: 37));
        } else if (interruption == 'episode switch') {
          expect(player.state.position, Duration.zero);
          expect(player.state.playing, isTrue);
        } else if (interruption != 'close') {
          expect(player.state.playing, isFalse);
        }
        if (interruption != 'close') await unmount(tester, player);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'paused forward clamps at the end without replaying the episode',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final player = DeferredSeekPlayer();
        await mount(
          tester,
          RouteRepository(),
          player,
          size: const Size(390, 844),
        );
        await tester.tap(find.byKey(const ValueKey('player-mobile-play')));
        await settleOperations(tester);
        await player.seek(const Duration(seconds: 115));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('player-mobile-forward')));
        await settleOperations(tester);
        expect(player.state.position, const Duration(seconds: 120));
        expect(player.state.playing, isFalse);
        expect(player.resumeCalls, 0);
        expect(player.opened, hasLength(1));
        await unmount(tester, player);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('mobile player pane starts below the system status area', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        size: const Size(390, 844),
        padding: const FakeViewPadding(top: 32),
      );
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      expect(surface.top, greaterThanOrEqualTo(32));
      expect(surface.height, greaterThan(780));
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });

  testWidgets('compact player tools stay clustered instead of evenly spread', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'pictureInPictureStatus') {
        return {'supported': true, 'active': false};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      final speed = tester.getRect(find.byKey(const ValueKey('player-speed')));
      final quality = tester.getRect(
        find.byKey(const ValueKey('player-quality')),
      );
      final pip = tester.getRect(
        find.byKey(const ValueKey('player-picture-in-picture')),
      );
      expect(quality.left - speed.right, lessThan(8));
      expect(pip.left - quality.right, lessThan(8));
      expect(pip.right, greaterThan(330));
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets(
    'portrait panels preserve video bounds and playback, switch tabs and close after selection',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final repository = RouteRepository();
        final player = ScriptedPlayer();
        await mount(tester, repository, player, size: const Size(390, 844));
        player.videoSize(720, 1280);
        await settleOperations(tester);
        final before = tester.getRect(
          find.byKey(const ValueKey('player-gesture-surface')),
        );
        expect(before.height, greaterThan(800));
        expect(find.byKey(const ValueKey('play-episode-2')), findsNothing);
        await capture(tester, 'portrait-watching');
        final opened = player.opened.length;
        await tester.tap(
          find.byKey(const ValueKey('player-portrait-episodes')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('play-episode-2')), findsOneWidget);
        expect(player.state.playing, isTrue);
        expect(player.opened.length, opened);
        await capture(tester, 'portrait-episodes');
        expect(
          tester.getRect(find.byKey(const ValueKey('player-gesture-surface'))),
          before,
        );
        await tester.tap(find.text('简介').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-follow-status')),
          findsOneWidget,
        );
        await tester.tap(find.text('下载').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-follow-status')),
          findsNothing,
        );
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('play-episode-2')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('收起面板'), findsNothing);
        expect(repository.requestedEpisodes.last, 2);
        expect(player.state.playing, isTrue);
        expect(
          tester.getRect(find.byKey(const ValueKey('player-gesture-surface'))),
          before,
        );
        await tester.tap(
          find.byKey(const ValueKey('player-portrait-details-1')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-follow-status')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('收起面板'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('player-follow-status')),
          findsNothing,
        );
        await unmount(tester, player);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
