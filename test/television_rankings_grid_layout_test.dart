import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class GridRankingRepository extends FixtureRepository {
  bool empty = false;
  bool rankingFailure = false;
  final selected = <String>[];
  final requestedBoards = <String>[];

  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(
      id: 'hongguo-hot',
      source: 'hongguo',
      name: '总热播榜',
      description: '今日热播 · 合成排行',
    ),
    RankingBoard(id: 'hongguo-comic', source: 'hongguo', name: '漫剧榜'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    requestedBoards.add(board);
    if (rankingFailure) throw AppFailure('合成榜单加载失败');
    return RankingPage(
      items: empty
          ? []
          : [
              for (var index = 1; index <= 48; index++)
                RankingItem(
                  index,
                  Drama(
                    id: 'hongguo:$board-$index',
                    source: 'hongguo',
                    title: '合成榜单第 $index 部：这是一段用来验证电视大字体与遥控浏览的长标题',
                    category: '真人剧 · 合成分类',
                    episodes: 120,
                    vip: index == 1,
                  ),
                  metric: '${12000 - index * 100}万热度',
                ),
            ],
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    selected.add(drama.id);
    return super.detail(drama);
  }
}

void main() {
  final baseline = Platform.environment['HG_RANKINGS_BASELINE'] == 'true';
  final geometry = <Map<String, Object>>[];

  setUpAll(() async {
    final font = Platform.environment['HG_UI_FONT'];
    if (font != null) {
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

  tearDownAll(() async {
    final output = Platform.environment['HG_RANKINGS_GEOMETRY'];
    if (output != null) {
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(geometry));
    }
  });

  void viewport(WidgetTester tester, Size size, double scale) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (output == null) return;
    await tester.runAsync(() async {
      await Directory(output).create(recursive: true);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('rankings-capture')),
      );
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<LocalStore> local() async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setSource('hongguo');
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    GridRankingRepository repository,
    LocalStore store, {
    bool embedded = false,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('rankings-capture'),
        child: embedded
            ? DuanjuApp(repository: repository, store: store, television: true)
            : televisionHost(
                child: RankingsScreen(
                  repository: repository,
                  store: store,
                  initialGroup: 'hongguo',
                ),
              ),
      ),
    );
    await tester.pumpAndSettle();
    if (embedded) {
      final category = find.byKey(const ValueKey('category-hongguo-hot'));
      focusRemote(tester, category);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
    }
  }

  Finder gridFinder() => find.descendant(
    of: find.byType(RankingsScreen),
    matching: find.byType(RemoteGrid),
  );

  Map<String, Object> measure(WidgetTester tester) {
    final grid = tester.widget<RemoteGrid>(gridFinder());
    final visible = tester
        .getRect(gridFinder())
        .intersect(Offset.zero & tester.view.physicalSize);
    final rows = <double>{};
    var cards = 0;
    for (final id in grid.itemKeys) {
      final item = find.byKey(ValueKey('rank-$id'));
      if (item.evaluate().isEmpty) continue;
      final rect = tester.getRect(item);
      if (rect.left >= visible.left - .5 &&
          rect.right <= visible.right + .5 &&
          rect.top >= visible.top - .5 &&
          rect.bottom <= visible.bottom + .5) {
        rows.add((rect.top * 10).round() / 10);
        cards++;
      }
    }
    return {
      'columns': grid.columns,
      'completeRows': rows.length,
      'completeCards': cards,
      'itemExtent': grid.itemExtent,
      'viewport': [visible.left, visible.top, visible.width, visible.height],
    };
  }

  for (final embedded in [false, true]) {
    for (final size in [
      const Size(960, 540),
      const Size(1280, 720),
      const Size(1920, 1080),
    ]) {
      for (final scale in [1.0, 1.3, 1.5]) {
        testWidgets('TV rankings grid $size font $scale embedded $embedded', (
          tester,
        ) async {
          viewport(tester, size, scale);
          final repository = GridRankingRepository();
          await mount(tester, repository, await local(), embedded: embedded);
          final result = measure(tester);
          final data = {
            'width': size.width,
            'height': size.height,
            'scale': scale,
            'embedded': embedded,
            'baseline': baseline,
            ...result,
          };
          geometry.add(data);
          debugPrint('TV_RANKINGS_GEOMETRY ${jsonEncode(data)}');
          if (!baseline) {
            expect(result['columns'] as int, greaterThanOrEqualTo(2));
            expect(result['completeRows'] as int, greaterThanOrEqualTo(2));
            final first = find.byKey(
              const ValueKey('rank-1-hongguo:hongguo-hot-1'),
            );
            final title = find.descendant(
              of: first,
              matching: find.text(repositoryTitle(1)),
            );
            final text = tester.widget<Text>(title);
            expect(text.style!.fontSize, 17);
            expect(text.maxLines, 2);
            final cover = tester.widget<DramaCover>(
              find.descendant(of: first, matching: find.byType(DramaCover)),
            );
            expect(cover.showMetadata, isFalse);
            final card = tester.getRect(first);
            for (final child in [
              title,
              find.descendant(of: first, matching: find.text('11900万热度')),
              find.descendant(
                of: first,
                matching: find.text('VIP · 共 120 集 · 真人剧 · 合成分类'),
              ),
            ]) {
              final rect = tester.getRect(child);
              expect(rect.left, greaterThanOrEqualTo(card.left));
              expect(rect.right, lessThanOrEqualTo(card.right));
              expect(rect.top, greaterThanOrEqualTo(card.top));
              expect(rect.bottom, lessThanOrEqualTo(card.bottom));
            }
          }
          if (!baseline) {
            final grid = tester.widget<RemoteGrid>(gridFinder());
            for (final movement in [
              (LogicalKeyboardKey.arrowRight, 1),
              (LogicalKeyboardKey.arrowDown, 1 + grid.columns),
              (LogicalKeyboardKey.arrowUp, 1),
              (LogicalKeyboardKey.arrowLeft, 0),
            ]) {
              await tester.sendKeyEvent(movement.$1);
              await tester.pumpAndSettle();
              expect(
                FocusManager.instance.primaryFocus?.debugLabel,
                'remote-${grid.itemKeys[movement.$2]}',
              );
            }
          }
          await capture(
            tester,
            '${baseline ? 'before' : 'after'}-${embedded ? 'inline' : 'standalone'}-${size.width.toInt()}x${size.height.toInt()}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets(
    'TV ranking switches boards from a grid and retries an empty error',
    (tester) async {
      viewport(tester, const Size(960, 540), 1.5);
      final repository = GridRankingRepository();
      await mount(tester, repository, await local());
      focusRemote(tester, find.byKey(const ValueKey('category-hongguo-comic')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(repository.requestedBoards, ['hongguo-hot', 'hongguo-comic']);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-1-hongguo:hongguo-comic-1',
      );
      expect(tester.widget<RemoteGrid>(gridFinder()).columns, 2);
      repository.empty = true;
      await tester.tap(find.byTooltip('更新榜单'));
      await tester.pumpAndSettle();
      expect(find.text('暂无榜单内容'), findsOneWidget);
      repository.rankingFailure = true;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('榜单暂时无法加载'), findsOneWidget);
      expect(find.textContaining('合成榜单加载失败'), findsOneWidget);
      repository.empty = false;
      repository.rankingFailure = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(gridFinder(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

String repositoryTitle(int index) => '合成榜单第 $index 部：这是一段用来验证电视大字体与遥控浏览的长标题';
