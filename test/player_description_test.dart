import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:duanju_app/windows_drama_description.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';
import 'windows_episode_sidebar_test.dart' show frames, sidebarTheme;

final description = List.generate(
  50,
  (i) => '第${i + 1}段合成剧情：角色相遇，沿途寻找答案。Synthetic synopsis.',
).join('\n');
DramaDetail story() => DramaDetail(
  Drama(
    id: 'hongguo:synopsis',
    source: 'hongguo',
    title: '合成剧情',
    description: description,
    episodes: 24,
  ),
  List.generate(
    24,
    (i) => Episode({
      'id': '$i',
      'title': '第${i + 1}集',
      'currentEpisode': i + 1,
    }, i + 1),
  ),
);

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('description-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$directory/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() {
    mockPlayerDevice();
    SharedPreferences.setMockInitialValues({});
  });
  for (final dark in [false, true]) {
    testWidgets(
      'desktop synopsis expands scrolls resets and uses explicit color (dark=$dark)',
      (tester) async {
        final theme = dark ? AppTheme.dark : AppTheme.light;
        Widget page(Drama drama) => MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              width: 312,
              height: 400,
              child: WindowsDramaDescription(drama: drama),
            ),
          ),
        );
        await tester.pumpWidget(page(story().drama));
        final text = find.byKey(const ValueKey('windows-description-text'));
        expect(
          tester.widget<Text>(text).style!.color,
          theme.colorScheme.onSurface,
        );
        expect(tester.widget<Text>(text).maxLines, 8);
        await tester.tap(
          find.byKey(const ValueKey('windows-description-expand')),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(text).maxLines, isNull);
        await tester.drag(
          find.byKey(const ValueKey('windows-description-scroll')),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(scroll.pixels, greaterThan(0));
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(text).maxLines, 8);
        await tester.pumpWidget(
          page(
            const Drama(
              id: 'empty',
              source: 'hongguo',
              title: '无简介',
              description: '  ',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('暂无剧情介绍'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('windows-description-expand')),
          findsNothing,
        );
        expect(scroll.pixels, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Windows sidebar synopsis preserves the video and episode selection',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = LocalStore(await SharedPreferences.getInstance());
      final player = ScriptedPlayer();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('description-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: await sidebarTheme(tester),
            home: PlayerScreen(
              detail: story(),
              initialIndex: 2,
              repository: RouteRepository(),
              store: store,
              playerFactory: () => Player(platformPlayer: player),
              videoBuilder: (controls) =>
                  ColoredBox(color: const Color(0xFF6BCADE), child: controls),
            ),
          ),
        ),
      );
      await frames(tester);
      final bounds = tester.getRect(find.byType(PlayerControls));
      final state = tester.state(find.byType(PlayerControls));
      expect(find.text('第 3 集 / 共 24 集'), findsOneWidget);
      await capture(tester, 'windows-episode-total');
      await tester.tap(
        find.byKey(const ValueKey('windows-sidebar-description')),
      );
      await frames(tester);
      expect(find.text('剧情介绍'), findsOneWidget);
      expect(tester.getRect(find.byType(PlayerControls)), bounds);
      await capture(tester, 'windows-synopsis-collapsed');
      await tester.tap(
        find.byKey(const ValueKey('windows-description-expand')),
      );
      await frames(tester);
      await capture(tester, 'windows-synopsis-expanded');
      await tester.tap(find.byKey(const ValueKey('windows-sidebar-episodes')));
      await frames(tester);
      expect(find.byKey(const ValueKey('play-episode-3')), findsOneWidget);
      expect(tester.state(find.byType(PlayerControls)), same(state));
      expect(player.opened, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester);
      await store.flushPendingWrites();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final dark in [false, true]) {
    testWidgets(
      'portrait synopsis stays readable under parent theme (dark=$dark)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = LocalStore(await SharedPreferences.getInstance());
        final player = ScriptedPlayer();
        final loaded = await sidebarTheme(tester);
        final theme = dark
            ? loaded
            : AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(
                  fontFamily: loaded.textTheme.bodyMedium!.fontFamily,
                ),
              );
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('description-capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: PlayerScreen(
                detail: story(),
                initialIndex: 2,
                repository: RouteRepository(),
                store: store,
                playerFactory: () => Player(platformPlayer: player),
                videoBuilder: (controls) =>
                    ColoredBox(color: const Color(0xFF6BCADE), child: controls),
              ),
            ),
          ),
        );
        await frames(tester);
        player.videoSize(720, 1280);
        await frames(tester);
        expect(find.text('选集 · 第 3 集 / 共 24 集'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('player-portrait-details-1')),
        );
        await frames(tester);
        final text = find.byKey(const ValueKey('player-description-text'));
        final color = tester.widget<Text>(text).style!.color!;
        expect(color, Theme.of(tester.element(text)).colorScheme.onSurface);
        expect(color.computeLuminance(), greaterThan(.5));
        await capture(
          tester,
          'mobile-synopsis-${dark ? 'dark' : 'light-parent'}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await frames(tester);
        await store.flushPendingWrites();
        store.dispose();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    'TV title includes the current season total and keeps remote controls',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      final player = ScriptedPlayer();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: AppLayout(
            television: true,
            child: PlayerScreen(
              detail: story(),
              initialIndex: 2,
              repository: RouteRepository(),
              store: store,
              playerFactory: () => Player(platformPlayer: player),
              videoBuilder: (controls) =>
                  ColoredBox(color: Colors.cyan, child: controls),
            ),
          ),
        ),
      );
      await frames(tester);
      expect(
        tester
            .widget<TelevisionControls>(find.byType(TelevisionControls))
            .title,
        '合成剧情 · 第 3 集 / 共 24 集',
      );
      expect(find.byKey(const ValueKey('tv-player-back')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester);
      await store.flushPendingWrites();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
