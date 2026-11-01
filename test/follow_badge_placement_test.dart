import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:duanju_app/television_saved_library.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

const followedDrama = Drama(
  id: 'hongguo:badge-followed',
  source: 'hongguo',
  title: '合成剧目与长标题测试第四十三季',
  episodes: 120,
  category: '合成分类',
  seriesGroupId: '4300',
  vip: true,
  releaseStatus: 'ongoing',
);

const nextDrama = Drama(
  id: 'hongguo:badge-next',
  source: 'hongguo',
  title: '合成剧目与长标题测试第四十四季',
  episodes: 100,
  seriesGroupId: '4300',
);

const higherDrama = Drama(
  id: 'hongguo:badge-higher',
  source: 'hongguo',
  title: '合成剧目与长标题测试第四十六季',
  episodes: 100,
  seriesGroupId: '4300',
);

class _BadgeRepository extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage([
    followedDrama,
    for (var i = 2; i <= 6; i++)
      Drama(
        id: 'hongguo:badge-$i',
        source: 'hongguo',
        title: '合成剧目第$i季',
        episodes: 80,
        category: '合成分类',
      ),
  ], hasMore: false);
}

void main() {
  setUpAll(() async {
    for (final spec in [
      ('HG_UI_FONT', 'Roboto'),
      ('HG_UI_ICON_FONT', 'MaterialIcons'),
    ]) {
      final path = Platform.environment[spec.$1];
      if (path != null) {
        await (FontLoader(spec.$2)..addFont(
              Future.value(
                ByteData.sublistView(await File(path).readAsBytes()),
              ),
            ))
            .load();
      }
    }
  });

  void viewport(WidgetTester tester, Size size, double scale) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Widget host(Widget child, {required bool television}) =>
      television ? televisionHost(child: child) : MaterialApp(home: child);

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['HG_FOLLOW_BADGE_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('follow-badge-capture')),
    );
    await tester.runAsync(() async {
      await Directory(directory).create(recursive: true);
      final picture = await boundary.toImage(pixelRatio: 1);
      final data = await picture.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      picture.dispose();
    });
  }

  Future<LocalStore> followedStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.toggleFavorite(followedDrama);
    await store.saveWatch(
      WatchEntry(
        drama: followedDrama,
        episode: 37,
        position: 79,
        duration: 180,
        updatedAt: DateTime.utc(2026, 11, 1),
      ),
    );
    return store;
  }

  for (final spec in [
    ('phone320', const Size(320, 844), false),
    ('phone390', const Size(390, 844), false),
    ('windows', const Size(1280, 720), false),
    ('tv', const Size(960, 540), true),
  ]) {
    for (final scale in [1.0, 1.3, 1.5]) {
      testWidgets(
        '${spec.$1} corner badge keeps card geometry at font $scale',
        (tester) async {
          viewport(tester, spec.$2, scale);
          final repository = _BadgeRepository();
          final nodes = List.generate(3, (_) => FocusNode());
          addTearDown(() {
            for (final node in nodes) {
              node.dispose();
            }
          });
          var tapped = 0;
          Widget page(bool badge) => host(
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    Widget card(int i) => DramaTile(
                      key: ValueKey('badge-card-$i'),
                      drama: followedDrama,
                      repository: repository,
                      subtitle: '第 43 季 · 第 37 集 · 1:19',
                      badge: badge ? '已追剧' : null,
                      focusNode: nodes[i],
                      onTap: () => tapped++,
                    );
                    if (spec.$3) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < 3; i++)
                            SizedBox(
                              width: 160,
                              height: DramaTile.extentFor(context, 146) + 14,
                              child: card(i),
                            ),
                        ],
                      );
                    }
                    return GridView.builder(
                      gridDelegate: dramaGridDelegate(
                        context,
                        constraints.maxWidth,
                      ),
                      itemCount: 3,
                      itemBuilder: (_, index) => card(index),
                    );
                  },
                ),
              ),
            ),
            television: spec.$3,
          );
          final tile = find.byKey(const ValueKey('badge-card-0'));
          Finder inside(Finder matching) =>
              find.descendant(of: tile, matching: matching).first;
          await tester.pumpWidget(page(false));
          await tester.pumpAndSettle();
          final cover = tester.getRect(inside(find.byType(DramaCover)));
          final tileRect = tester.getRect(tile);
          final title = tester.getRect(inside(find.text(followedDrama.title)));
          final subtitle = tester.getRect(
            inside(find.text('第 43 季 · 第 37 集 · 1:19')),
          );
          await tester.pumpWidget(page(true));
          await tester.pumpAndSettle();
          expect(tester.getRect(inside(find.byType(DramaCover))), cover);
          expect(tester.getRect(tile), tileRect);
          expect(tester.getRect(inside(find.text(followedDrama.title))), title);
          expect(
            tester.getRect(inside(find.text('第 43 季 · 第 37 集 · 1:19'))),
            subtitle,
          );
          final banner = tester.widget<Banner>(inside(find.byType(Banner)));
          expect(banner.message, '已追剧');
          expect(banner.location, BannerLocation.topStart);
          expect(banner.layoutDirection, TextDirection.ltr);
          final vip = tester.getRect(inside(find.text('VIP')));
          final episodes = tester.getRect(inside(find.text('共 120 集')));
          expect(vip.top - cover.top, greaterThanOrEqualTo(62));
          expect(vip.bottom, lessThan(episodes.top));
          expect(vip.bottom, lessThan(cover.bottom));
          expect(episodes.bottom, lessThan(cover.bottom));
          expect(
            tester
                .renderObject<RenderParagraph>(
                  inside(find.text('第 43 季 · 第 37 集 · 1:19')),
                )
                .constraints
                .maxWidth,
            closeTo(cover.width - 4, .001),
          );
          if (spec.$3) {
            nodes[0].requestFocus();
            await tester.pumpAndSettle();
            expect(nodes[0].hasPrimaryFocus, true);
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            expect(tapped, 1);
          } else {
            await tester.tapAt(cover.topLeft + const Offset(25, 25));
            expect(tapped, 1);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final television in [false, true]) {
    testWidgets('rank and VIP avoid the corner ribbon tv=$television', (
      tester,
    ) async {
      viewport(
        tester,
        television ? const Size(960, 540) : const Size(320, 844),
        1.5,
      );
      var menu = 0;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Builder(
                builder: (context) => SizedBox(
                  width: television ? 160 : 90,
                  height:
                      DramaTile.extentFor(context, television ? 146 : 90) +
                      (television ? 14 : 0),
                  child: DramaTile(
                    drama: followedDrama,
                    repository: _BadgeRepository(),
                    badge: '已追剧',
                    rank: 3,
                    actions: IconButton(
                      key: const ValueKey('rank-menu'),
                      onPressed: () => menu++,
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
          television: television,
        ),
      );
      await tester.pumpAndSettle();
      final cover = tester.getRect(find.byType(DramaCover));
      final rank = tester.getRect(
        find.byKey(const ValueKey('drama-info-rank')),
      );
      final vip = tester.getRect(find.text('VIP'));
      expect(rank.top, greaterThan(cover.bottom));
      expect(rank.overlaps(cover), false);
      expect(vip.top - cover.top, greaterThanOrEqualTo(62));
      expect(vip.overlaps(rank), false);
      await tester.tap(find.byKey(const ValueKey('rank-menu')));
      expect(menu, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final television in [false, true]) {
    for (final history in [false, true]) {
      testWidgets('saved history=$history tv=$television keeps follow state', (
        tester,
      ) async {
        viewport(
          tester,
          television ? const Size(960, 540) : const Size(390, 844),
          1.5,
        );
        final store = await followedStore();
        final opened = <String>[];
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('follow-badge-capture'),
            child: host(
              Scaffold(
                body: SavedLibrary(
                  repository: _BadgeRepository(),
                  store: store,
                  history: history,
                  onOpen: (drama) => opened.add(drama.id),
                  onContinue: (drama) => opened.add(drama.id),
                ),
              ),
              television: television,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('saved-hongguo:badge-followed'));
        expect(tile, findsOneWidget);
        expect(store.followedSeries(followedDrama), isNotNull);
        expect(store.seriesWatch(followedDrama)?.episode, 37);
        expect(store.seriesWatch(followedDrama)?.position, 79);
        if (history) {
          final badge = find.descendant(
            of: tile,
            matching: find.byType(Banner),
          );
          expect(tester.widget<Banner>(badge).message, '已追剧');
        } else {
          expect(find.text('已追剧'), findsNothing);
          if (television) {
            expect(find.byType(TelevisionSavedTile), findsOneWidget);
            expect(tester.widget<TelevisionSavedTile>(tile).badge, isNull);
          } else {
            expect(tester.widget<DramaTile>(tile).badge, isNull);
          }
          await store.applySeasonCheck(
            followed: followedDrama,
            anchor: followedDrama,
            resolvedAnchor: followedDrama,
            next: nextDrama,
            complete: true,
            isCurrent: () => true,
          );
          await tester.pumpAndSettle();
          if (television) {
            expect(tester.widget<TelevisionSavedTile>(tile).badge, '已有下季');
          } else {
            final badge = find.descendant(
              of: tile,
              matching: find.byType(Banner),
            );
            expect(tester.widget<Banner>(badge).message, '已有下季');
          }
          await store.applySeasonCheck(
            followed: followedDrama,
            anchor: followedDrama,
            resolvedAnchor: followedDrama,
            next: null,
            complete: true,
            isCurrent: () => true,
          );
          await tester.pumpAndSettle();
          if (television) {
            expect(tester.widget<TelevisionSavedTile>(tile).badge, isNull);
          } else {
            expect(tester.widget<DramaTile>(tile).badge, isNull);
          }
        }
        if (television) {
          focusRemote(tester, tile);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(tile);
        }
        expect(opened, [followedDrama.id]);
        await capture(tester, 'saved-$history-tv-$television-large');
        expect(store.followedSeries(followedDrama), isNotNull);
        expect(store.seriesWatch(followedDrama)?.position, 79);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final television in [false, true]) {
    for (final history in [false, true]) {
      testWidgets(
        'status priority on ${history ? 'history' : 'home'} tv=$television',
        (tester) async {
          viewport(
            tester,
            television ? const Size(960, 540) : const Size(320, 844),
            1.5,
          );
          final store = await followedStore();
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('follow-badge-capture'),
              child: host(
                history
                    ? Scaffold(
                        body: SavedLibrary(
                          repository: _BadgeRepository(),
                          store: store,
                          history: true,
                          onOpen: (_) {},
                          onContinue: (_) {},
                        ),
                      )
                    : HomeScreen(repository: _BadgeRepository(), store: store),
                television: television,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final tile = find.byKey(
            ValueKey('${history ? 'saved-' : ''}${followedDrama.id}'),
          );
          void status(String? expected) {
            final banners = find.descendant(
              of: tile,
              matching: find.byType(Banner),
            );
            if (expected == null) {
              expect(banners, findsNothing);
            } else {
              expect(banners, findsOneWidget);
              expect(tester.widget<Banner>(banners).message, expected);
            }
          }

          Future<void> check(Drama? next) => store.applySeasonCheck(
            followed: followedDrama,
            anchor: followedDrama,
            resolvedAnchor: followedDrama,
            next: next,
            complete: true,
            isCurrent: () => true,
          );
          status('已追剧');
          await store.refreshDramas([higherDrama]);
          await tester.pumpAndSettle();
          expect(store.hasNextSeason(followedDrama), false);
          status('已追剧');
          await check(nextDrama);
          await tester.pumpAndSettle();
          expect(store.hasNextSeason(followedDrama), true);
          status('已有下季');
          await capture(
            tester,
            '${history ? 'history' : 'home'}-tv-$television-next',
          );
          await check(null);
          await store.refreshDramas([nextDrama]);
          await tester.pumpAndSettle();
          expect(store.hasNextSeason(followedDrama), false);
          status('已追剧');
          expect(store.followedSeries(followedDrama), isNotNull);
          expect(store.seriesWatch(followedDrama)?.position, 79);
          await capture(
            tester,
            '${history ? 'history' : 'home'}-tv-$television-follow',
          );
          await store.toggleFavorite(followedDrama);
          await tester.pumpAndSettle();
          status(null);
          expect(store.followedSeries(followedDrama), isNull);
          expect(store.seriesWatch(followedDrama)?.position, 79);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
