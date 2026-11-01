import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/episode_browser.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class RemoteRankingRepository extends FixtureRepository {
  Drama? selectedDrama;
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热榜'),
    RankingBoard(id: 'hongguo-real', source: 'hongguo', name: '真人剧榜'),
  ];
  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage(
    items: List.generate(
      30,
      (index) => RankingItem(
        index + 1,
        Drama(
          id: 'hongguo:tv-rank-${index + 1}',
          source: 'hongguo',
          title: '合成榜单第 ${index + 1} 部 · 遥控选片示例',
          category: '合成分类',
        ),
        metric: '${12000 - index * 100}万热度',
      ),
    ),
  );
  @override
  Future<DramaDetail> detail(Drama drama) async {
    selectedDrama = drama;
    return super.detail(drama);
  }
}

void main() {
  Widget host({required Widget child}) {
    final app = televisionHost(child: child) as MaterialApp;
    final theme = ThemeData.dark();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Platform.environment['HG_UI_FONT'] == null
          ? app.theme
          : app.theme!.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'UiPreviewCJK'),
            ),
      builder: app.builder,
      home: app.home,
    );
  }

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUpAll(() async {
    final font = Platform.environment['HG_UI_FONT'];
    if (font != null) {
      await (FontLoader('UiPreviewCJK')..addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())),
          ))
          .load();
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())),
          ))
          .load();
    }
    final icons = Platform.environment['HG_UI_ICON_FONT'];
    if (icons != null) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await File(icons).readAsBytes())),
          ))
          .load();
    }
  });

  testWidgets(
    'TV ranking grid arrows scroll beyond built rows, OK opens the focused drama, back restores it',
    (tester) async {
      size(tester);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final repository = RemoteRankingRepository();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: host(
            child: RankingsScreen(
              repository: repository,
              store: store,
              initialGroup: 'hongguo',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-1-hongguo:tv-rank-1',
      );
      final first = tester.getRect(
        find.byKey(const ValueKey('rank-1-hongguo:tv-rank-1')),
      );
      final fourth = tester.getRect(
        find.byKey(const ValueKey('rank-4-hongguo:tv-rank-4')),
      );
      expect(first.height, inInclusiveRange(118, 160));
      final third = tester.getRect(
        find.byKey(const ValueKey('rank-3-hongguo:tv-rank-3')),
      );
      expect(first.top, third.top);
      expect(fourth.top, greaterThan(first.bottom));
      expect(fourth.bottom, lessThanOrEqualTo(540));
      await capture(tester, 'tv-rankings');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      for (var index = 0; index < 7; index++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-24-hongguo:tv-rank-24',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(repository.selectedDrama?.id, 'hongguo:tv-rank-24');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-24-hongguo:tv-rank-24',
      );
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-23-hongguo:tv-rank-23',
      );
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-20-hongguo:tv-rank-20',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV choice menu starts at a saved offscreen choice and cancel restores the opener',
    (tester) async {
      size(tester);
      int? picked;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: host(
            child: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => RemoteButton(
                    key: const ValueKey('choice-opener'),
                    label: '切换站源',
                    autofocus: true,
                    onPressed: () async {
                      picked = await showRemoteChoice<int>(
                        context: context,
                        title: '切换站源',
                        values: List.generate(28, (index) => index),
                        selected: 20,
                        label: (value) => '合成站源 $value',
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-20');
      await capture(tester, 'tv-source-menu');
      for (var index = 0; index < 6; index++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.select);
      expect(picked, 26);
      await press(tester, LogicalKeyboardKey.select);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(picked, isNull);
      expect(find.byKey(const ValueKey('remote-choice-20')), findsNothing);
      await press(tester, LogicalKeyboardKey.select);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-20');
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'TV episode range menu selects the next offscreen group without a pointer',
    (tester) async {
      size(tester);
      int? located;
      await tester.pumpWidget(
        host(
          child: Scaffold(
            body: EpisodeRangeBar(
              episodes: List.generate(
                2000,
                (index) => Episode({'id': '${index + 1}'}, index + 1),
              ),
              page: 35,
              onLocate: (index) => located = index,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focusRemote(tester, find.byKey(const ValueKey('episode-range')));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-35');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(located, 1800);
      expect(tester.takeException(), isNull);
    },
  );
}
