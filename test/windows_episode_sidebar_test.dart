import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/episode_browser.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<ThemeData> sidebarTheme(WidgetTester tester) async {
  var theme = AppTheme.dark;
  final font = Platform.environment['HG_UI_FONT'];
  if (font != null) {
    await tester.runAsync(() async {
      for (final entry in {
        'SidebarCJK': font,
        if (theme.textTheme.labelSmall?.fontFamily case final String family)
          family: font,
        if (theme.textTheme.labelLarge?.fontFamily case final String family)
          family: font,
        'MaterialIcons': Platform.environment['HG_UI_ICON_FONT'],
      }.entries) {
        if (entry.value == null) continue;
        final bytes = await File(entry.value!).readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'SidebarCJK'),
    );
  }
  return theme;
}

Future<void> captureSidebar(WidgetTester tester, String state) async {
  final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('sidebar-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(
      '$directory/windows-sidebar-$state.png',
    ).writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(mockPlayerDevice);
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);
  final sidebar = find.byKey(const ValueKey('windows-episode-sidebar'));
  final picker = find.byKey(const ValueKey('player-episodes'));
  final detail = DramaDetail(
    const Drama(
      id: 'hongguo:sidebar',
      source: 'hongguo',
      title: '合成选集',
      episodes: 120,
    ),
    List.generate(
      120,
      (index) => Episode({
        'id': 'episode-${index + 1}',
        'title': '第 ${index + 1} 集',
        'currentEpisode': index + 1,
      }, index + 1),
    ),
  );

  testWidgets(
    'desktop episode cards fit more columns while preserving targets and current marker',
    (tester) async {
      final desktop = defaultTargetPlatform == TargetPlatform.windows;
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 312,
                height: 600,
                child: PlayerEpisodeGrid(
                  episodes: detail.episodes,
                  currentIndex: 58,
                  onSelected: (index) => selected = index,
                ),
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      final grid = tester.widget<RemoteGrid>(find.byType(RemoteGrid));
      expect(grid.columns, desktop ? 5 : 3);
      expect(grid.itemExtent, desktop ? 44 : 56);
      expect(grid.spacing, desktop ? 4 : 8);
      final current = find.byKey(const ValueKey('play-episode-59'));
      expect(tester.widget<RemoteEpisodeButton>(current).current, isTrue);
      final bounds = tester.getRect(current);
      expect(bounds.height, greaterThanOrEqualTo(44));
      expect(bounds.width, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('play-episode-60')));
      await tester.pump();
      expect(selected, 59);
      expect(find.text('定位当前'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'sidebar collapse resize fullscreen preserves player, episode page and scroll',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      final platform = ScriptedPlayer();
      var creations = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('sidebar-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: await sidebarTheme(tester),
            home: PlayerScreen(
              detail: detail,
              initialIndex: 58,
              initialPosition: 27,
              initiallyPlaying: false,
              repository: RouteRepository(),
              store: store,
              playerFactory: () {
                creations++;
                return Player(platformPlayer: platform);
              },
              videoBuilder: (controls) =>
                  ColoredBox(color: const Color(0xFF6BCADE), child: controls),
            ),
          ),
        ),
      );
      await frames(tester);
      final playerState = tester.state(find.byType(PlayerControls));
      final browserState = tester.state(find.byType(EpisodeBrowser));
      await captureSidebar(tester, 'expanded');
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: sidebar, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      position.jumpTo(10);
      await tester.pump();
      final width = tester.getSize(find.byType(PlayerControls)).width;
      expect(find.text('第 51–100 集'), findsOneWidget);
      expect(
        tester
            .widget<RemoteEpisodeButton>(
              find.byKey(const ValueKey('play-episode-59')),
            )
            .current,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('windows-collapse-episodes')));
      await frames(tester);
      expect(sidebar, findsNothing);
      expect(
        tester.getSize(find.byType(PlayerControls)).width,
        greaterThan(width + 300),
      );
      expect(preferences.getBool('windows_episode_sidebar_expanded'), isFalse);
      expect(find.byTooltip('展开选集栏'), findsOneWidget);
      await captureSidebar(tester, 'collapsed');
      await tester.tap(picker);
      await frames(tester);
      expect(sidebar, findsOneWidget);
      expect(preferences.getBool('windows_episode_sidebar_expanded'), isTrue);
      expect(position.pixels, 10);
      tester.widget<PlayerControls>(find.byType(PlayerControls)).onFullscreen();
      await frames(tester);
      expect(sidebar, findsNothing);
      tester.widget<PlayerControls>(find.byType(PlayerControls)).onFullscreen();
      await frames(tester);
      expect(sidebar, findsOneWidget);
      expect(position.pixels, 10);
      tester.view.physicalSize = const Size(720, 600);
      await frames(tester);
      expect(sidebar, findsNothing);
      expect(preferences.getBool('windows_episode_sidebar_expanded'), isTrue);
      await tester.tap(picker);
      await frames(tester);
      expect(find.byType(PlayerMenu), findsOneWidget);
      Navigator.of(tester.element(find.byType(PlayerMenu))).pop();
      await frames(tester);
      tester.view.physicalSize = const Size(1280, 600);
      await frames(tester);
      expect(sidebar, findsOneWidget);
      expect(tester.state(find.byType(PlayerControls)), same(playerState));
      expect(tester.state(find.byType(EpisodeBrowser)), same(browserState));
      expect(position.pixels, 10);
      expect(platform.state.position.inSeconds, 27);
      expect(platform.opened, hasLength(1));
      expect(creations, 1);
      expect(find.text('定位当前'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-all-seasons')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester);
      await store.flushPendingWrites();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: windows,
  );

  testWidgets('collapsed desktop preference survives reopening the player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'windows_episode_sidebar_expanded': false,
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          detail: detail,
          initialIndex: 58,
          initiallyPlaying: false,
          repository: RouteRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) =>
              ColoredBox(color: Colors.blue, child: controls),
        ),
      ),
    );
    await frames(tester);
    expect(sidebar, findsNothing);
    expect(find.byTooltip('展开选集栏'), findsOneWidget);
    await tester.tap(picker);
    await frames(tester);
    expect(sidebar, findsOneWidget);
    expect(
      tester
          .widget<RemoteEpisodeButton>(
            find.byKey(const ValueKey('play-episode-59')),
          )
          .current,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await frames(tester);
    await store.flushPendingWrites();
    store.dispose();
    expect(tester.takeException(), isNull);
  }, variant: windows);
}
