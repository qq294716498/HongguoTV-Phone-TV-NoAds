import 'dart:async';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:duanju_app/series_browser_screen.dart';
import 'package:duanju_app/series_catalog.dart';
import 'package:duanju_app/episode_browser.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const firstSeason = Drama(
  id: 'hongguo:series-first',
  source: 'hongguo',
  title: '合成故事 第一季',
  episodes: 2,
);
const secondSeason = Drama(
  id: 'hongguo:series-second',
  source: 'hongguo',
  title: '合成故事 第二季',
  episodes: 100,
);
const thirdSeason = Drama(
  id: 'hongguo:series-third',
  source: 'hongguo',
  title: '合成故事 第三季',
  episodes: 3,
);
const unrelatedSeason = Drama(
  id: 'hongguo:another',
  source: 'hongguo',
  title: '另一个故事 第二季',
  episodes: 2,
);

class SeasonRepository extends FixtureRepository {
  final catalogCalls = <(String, int, bool)>[];
  final results = <int, CatalogPage>{};
  final detailResults = <String, DramaDetail>{};
  final pendingDetails = <String, Completer<DramaDetail>>{};
  final resolutions = <(String, int)>[];
  Completer<CatalogPage>? pendingCatalog;
  int? failingPage;
  int activeCatalogs = 0;
  int maximumCatalogs = 0;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    catalogCalls.add((query, page, force));
    activeCatalogs++;
    if (activeCatalogs > maximumCatalogs) maximumCatalogs = activeCatalogs;
    try {
      if (failingPage == page) throw AppFailure('合成搜索失败');
      if (pendingCatalog != null) return await pendingCatalog!.future;
      return results[page] ??
          CatalogPage([
            firstSeason,
            secondSeason,
            thirdSeason,
            unrelatedSeason,
          ]);
    } finally {
      activeCatalogs--;
    }
  }

  DramaDetail makeDetail(Drama drama, {bool vip = false}) =>
      DramaDetail(drama, [
        for (var index = 1; index <= drama.episodes; index++)
          Episode({
            'id': '${drama.id}:$index',
            'currentEpisode': index,
            'vip': vip && index == 2,
          }, index),
      ]);

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      pendingDetails[drama.id] == null
      ? detailResults[drama.id] ?? makeDetail(drama)
      : await pendingDetails[drama.id]!.future;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolutions.add((drama.id, episode.number));
    return PlaybackPlan(
      url: 'file:///synthetic-${episode.number}.mp4',
      session: '${drama.id}:${episode.number}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlayerDevice);

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  WatchEntry watch(Drama drama, int episode, int minute) => WatchEntry(
    drama: drama,
    episode: episode,
    position: 12,
    duration: 60,
    updatedAt: DateTime.utc(2026, 10, 15, 12, minute),
  );

  test(
    'season lookup paginates and excludes unrelated titles and sources',
    () async {
      final repository = SeasonRepository()
        ..results[1] = CatalogPage([
          thirdSeason,
          unrelatedSeason,
        ], hasMore: true)
        ..results[2] = CatalogPage([
          secondSeason,
          const Drama(
            id: 'huangdou:copy',
            source: 'huangdou',
            title: '合成故事 第二季',
          ),
        ]);
      final catalog = SeriesCatalog(
        anchor: firstSeason,
        repository: repository,
        knownDramas: const [],
        allowed: () => true,
      );
      addTearDown(catalog.dispose);
      await catalog.load();
      expect(repository.catalogCalls, [('合成故事', 1, true), ('合成故事', 2, false)]);
      expect(catalog.entries.map((entry) => entry.drama.id), [
        firstSeason.id,
        secondSeason.id,
        thirdSeason.id,
      ]);
      expect(catalog.hasMore, isFalse);
    },
  );

  test(
    'partial search retains its seasons and retries the failed page',
    () async {
      final repository = SeasonRepository()
        ..results[1] = CatalogPage([secondSeason], hasMore: true)
        ..results[2] = CatalogPage([thirdSeason])
        ..failingPage = 2;
      final catalog = SeriesCatalog(
        anchor: firstSeason,
        repository: repository,
        knownDramas: const [],
        allowed: () => true,
      );
      addTearDown(catalog.dispose);
      await catalog.load();
      expect(catalog.error, isNotEmpty);
      expect(
        catalog.entries.map((entry) => entry.drama.id),
        contains(secondSeason.id),
      );
      repository.failingPage = null;
      await catalog.load();
      expect(repository.catalogCalls.map((call) => call.$2), [1, 2, 2]);
      expect(catalog.error, isEmpty);
      expect(catalog.entries, hasLength(3));
    },
  );

  test(
    'lookup keeps a bounded page budget and exposes remaining results',
    () async {
      final repository = SeasonRepository();
      for (var page = 1; page <= 6; page++) {
        repository.results[page] = CatalogPage([], hasMore: true);
      }
      repository.results[7] = CatalogPage([secondSeason]);
      final catalog = SeriesCatalog(
        anchor: firstSeason,
        repository: repository,
        knownDramas: const [],
        allowed: () => true,
      );
      addTearDown(catalog.dispose);
      await catalog.load();
      expect(repository.catalogCalls, hasLength(7));
      expect(catalog.hasMore, isTrue);
      await catalog.load();
      expect(repository.catalogCalls, hasLength(9));
      expect(catalog.hasMore, isFalse);
      expect(catalog.entries, hasLength(2));
    },
  );

  test('a disposed lookup ignores its late response', () async {
    final repository = SeasonRepository()
      ..pendingCatalog = Completer<CatalogPage>();
    final catalog = SeriesCatalog(
      anchor: firstSeason,
      repository: repository,
      knownDramas: const [],
      allowed: () => true,
    );
    final pending = catalog.load();
    catalog.dispose();
    repository.pendingCatalog!.complete(CatalogPage([secondSeason]));
    await pending;
    expect(catalog.entries, hasLength(1));
  });

  test(
    'series follows latest playback, persists, and exposes the next season',
    () async {
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      await store.refreshDramas([firstSeason, secondSeason, thirdSeason]);
      await store.saveWatch(watch(firstSeason, 1, 1));
      await store.saveWatch(watch(secondSeason, 51, 2));
      expect(store.trackedSeries, hasLength(1));
      expect(store.seriesWatch(firstSeason)!.episode, 51);
      expect(store.seriesWatch(firstSeason)!.drama.id, secondSeason.id);
      expect(store.followedSeries(secondSeason)!.id, firstSeason.id);
      expect(store.hasNextSeason(firstSeason), isTrue);
      await store.saveWatch(watch(thirdSeason, 2, 3));
      expect(store.hasNextSeason(firstSeason), isFalse);
      await store.saveWatch(watch(firstSeason, 2, 4));
      expect(store.seriesWatch(firstSeason)!.drama.id, firstSeason.id);
      expect(store.hasNextSeason(firstSeason), isTrue);
      final restarted = LocalStore(store.preferences);
      addTearDown(restarted.dispose);
      expect(restarted.seriesWatch(firstSeason)!.episode, 2);
      expect(restarted.history, hasLength(3));
    },
  );

  test(
    'legacy duplicate follows display once and can be removed as a series',
    () async {
      final store = await createStore();
      await store.toggleFavorite(firstSeason);
      await store.toggleFavorite(secondSeason);
      await store.saveWatch(watch(secondSeason, 4, 1));
      expect(store.trackedSeries, hasLength(1));
      await store.toggleSeriesFavorite(secondSeason);
      expect(store.favorites, isEmpty);
      expect(store.history.single.episode, 4);
    },
  );

  test('plain first-season titles continue to match later seasons', () async {
    final store = await createStore();
    const plain = Drama(id: 'hongguo:plain', source: 'hongguo', title: '合成故事');
    await store.toggleSeriesFavorite(plain);
    await store.refreshDramas([secondSeason]);
    await store.saveWatch(watch(secondSeason, 5, 1));
    expect(store.followedSeries(secondSeason)!.id, plain.id);
    expect(store.seriesWatch(plain)!.episode, 5);
    expect(store.trackedSeries, hasLength(1));
  });

  test(
    'marked follows skip remote reads while unmarked follows remain fresh',
    () async {
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      await store.toggleSeriesFavorite(unrelatedSeason);
      final repository = SeasonRepository();
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      await updates.refresh();
      expect(repository.catalogCalls, hasLength(4));
      expect(repository.catalogCalls.every((call) => call.$3), isTrue);
      expect(repository.maximumCatalogs, 1);
      expect(store.hasNextSeason(firstSeason), isTrue);
      await updates.refresh();
      expect(repository.catalogCalls, hasLength(7));
      expect(repository.catalogCalls.last.$1, '另一个故事 第3季');
      expect(updates.failed, 0);
    },
  );

  test('persisted next-season labels skip fresh controller queries', () async {
    final store = await createStore();
    await store.toggleSeriesFavorite(firstSeason);
    await store.refreshDramas([firstSeason, secondSeason]);
    final restarted = LocalStore(store.preferences);
    addTearDown(restarted.dispose);
    final repository = SeasonRepository();
    final updates = FollowUpdates(repository, restarted);
    addTearDown(updates.dispose);
    await updates.refresh();
    expect(repository.catalogCalls, isEmpty);
    expect(updates.total, 0);
    expect(restarted.hasNextSeason(firstSeason), true);
    await updates.refresh(force: true);
    expect(repository.catalogCalls, hasLength(1));
  });

  test(
    'an unmarked series is queried again after no result or failure',
    () async {
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      final repository = SeasonRepository()
        ..results[1] = CatalogPage([firstSeason]);
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      await updates.refresh();
      expect(store.hasNextSeason(firstSeason), false);
      repository.failingPage = 1;
      await updates.refresh();
      expect(updates.failed, 1);
      repository.failingPage = null;
      await updates.refresh();
      expect(repository.catalogCalls, hasLength(9));
    },
  );

  test('advancing the watched season checks its new successor', () async {
    final store = await createStore();
    await store.toggleSeriesFavorite(firstSeason);
    await store.refreshDramas([firstSeason, secondSeason]);
    final repository = SeasonRepository();
    final updates = FollowUpdates(repository, store);
    addTearDown(updates.dispose);
    await updates.refresh();
    expect(repository.catalogCalls, isEmpty);
    await store.saveWatch(watch(secondSeason, 3, 2));
    expect(store.hasNextSeason(firstSeason), false);
    await updates.refresh();
    expect(repository.catalogCalls, hasLength(1));
    expect(store.hasNextSeason(firstSeason), true);
    await updates.refresh();
    expect(repository.catalogCalls, hasLength(1));
    await store.saveWatch(watch(thirdSeason, 2, 3));
    await updates.refresh();
    expect(repository.catalogCalls, hasLength(4));
    expect(store.hasNextSeason(firstSeason), false);
  });

  test(
    'an imported current-season change invalidates the old next-season label',
    () async {
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      await store.refreshDramas([firstSeason, secondSeason]);
      final repository = SeasonRepository();
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      await updates.refresh();
      expect(repository.catalogCalls, isEmpty);
      final document = store.lanDocument;
      final record = document.records[firstSeason.id]!;
      final moved = record.withField(
        'progress',
        document.edit(record.progress, watch(secondSeason, 4, 2).toJson()),
      );
      await store.applyLanRecords(
        operation: 'test-current-season',
        base: store.lanDocument.hashFor({'hongguo'}),
        sources: {'hongguo'},
        records: [moved],
        epoch: store.profileEpoch,
      );
      expect(store.hasNextSeason(firstSeason), false);
      await updates.refresh();
      expect(repository.catalogCalls, hasLength(1));
      expect(store.hasNextSeason(firstSeason), true);
    },
  );

  test('a current-season change discards a pending old lookup', () async {
    final store = await createStore();
    await store.toggleSeriesFavorite(firstSeason);
    final repository = SeasonRepository()
      ..pendingCatalog = Completer<CatalogPage>();
    final updates = FollowUpdates(repository, store);
    addTearDown(updates.dispose);
    final pending = updates.refresh();
    await store.saveWatch(watch(secondSeason, 4, 2));
    repository.pendingCatalog!.complete(CatalogPage([thirdSeason]));
    await pending;
    expect(store.hasNextSeason(firstSeason), false);
    repository.pendingCatalog = null;
    await updates.refresh();
    expect(repository.catalogCalls, hasLength(2));
    expect(store.hasNextSeason(firstSeason), true);
  });

  test(
    'follow checks cannot save a late response into another user session',
    () async {
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      final repository = SeasonRepository()
        ..pendingCatalog = Completer<CatalogPage>();
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      final pending = updates.refresh();
      await store.switchProfile('default');
      repository.pendingCatalog!.complete(CatalogPage([secondSeason]));
      await pending;
      expect(
        store.seriesDramasFor(firstSeason).map((d) => d.id),
        isNot(contains(secondSeason.id)),
      );
    },
  );

  test(
    'cached series results change after history and favorite edits',
    () async {
      final store = await createStore();
      await store.refreshDramas([firstSeason, secondSeason, thirdSeason]);
      expect(store.followedSeries(secondSeason), isNull);
      expect(store.seriesWatch(firstSeason), isNull);
      await store.toggleSeriesFavorite(firstSeason);
      expect(store.followedSeries(secondSeason)!.id, firstSeason.id);
      await store.saveWatch(watch(secondSeason, 9, 1));
      expect(store.seriesWatch(firstSeason)!.episode, 9);
      await store.removeHistory(secondSeason.id);
      expect(store.seriesWatch(firstSeason), isNull);
      await store.toggleSeriesFavorite(secondSeason);
      expect(store.trackedSeries, isEmpty);
      expect(store.followedSeries(firstSeason), isNull);
    },
  );

  test(
    'series index keeps seasons and parts separate and ignores unrelated titles',
    () async {
      final store = await createStore();
      const part = Drama(
        id: 'hongguo:part',
        source: 'hongguo',
        title: '合成故事 第二部',
      );
      await store.refreshDramas([
        firstSeason,
        secondSeason,
        part,
        unrelatedSeason,
      ]);
      await store.toggleSeriesFavorite(firstSeason);
      expect(store.followedSeries(part), isNull);
      expect(store.followedSeries(unrelatedSeason), isNull);
      expect(store.followedSeries(secondSeason)!.id, firstSeason.id);
    },
  );

  test(
    'follow lookup batches library writes while checking every series',
    () async {
      final store = await createStore();
      for (var i = 0; i < 17; i++) {
        await store.toggleSeriesFavorite(
          Drama(
            id: 'hongguo:batch-$i',
            source: 'hongguo',
            title: '批量合成故事$i 第一季',
          ),
        );
      }
      final repository = SeasonRepository();
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      var writes = 0;
      store.addListener(() => writes++);
      await updates.refresh();
      expect(repository.catalogCalls, hasLength(51));
      expect(updates.checked, 17);
      expect(writes, lessThanOrEqualTo(3));
    },
  );

  Future<void> openBrowser(
    WidgetTester tester,
    SeasonRepository repository,
    LocalStore store, {
    bool television = false,
    void Function(SeriesEpisodeSelection?)? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: television ? televisionTheme(ThemeData()) : ThemeData(),
        home: AppLayout(
          television: television,
          child: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  final selection =
                      await Navigator.push<SeriesEpisodeSelection>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AppLayout(
                            television: television,
                            child: SeriesBrowserScreen(
                              anchor: firstSeason,
                              initialDetail: repository.makeDetail(firstSeason),
                              repository: repository,
                              store: store,
                            ),
                          ),
                        ),
                      );
                  onResult?.call(selection);
                },
                child: const Text('打开全季'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开全季'));
    await tester.pumpAndSettle();
  }

  for (final spec in [
    (const Size(320, 640), false),
    (const Size(390, 844), false),
    (const Size(844, 390), false),
    (const Size(960, 540), true),
  ]) {
    testWidgets(
      'all-season episode numbers stay compact, centered and selectable at ${spec.$1}',
      (tester) async {
        viewport(tester, spec.$1);
        final store = await createStore();
        await store.saveWatch(watch(secondSeason, 1, 1));
        final repository = SeasonRepository();
        SeriesEpisodeSelection? selected;
        await openBrowser(
          tester,
          repository,
          store,
          television: spec.$2,
          onResult: (value) => selected = value,
        );
        await tester.tap(find.byKey(ValueKey('all-season-${secondSeason.id}')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EpisodeBrowser>(find.byType(EpisodeBrowser))
              .denseDesktop,
          true,
        );
        final first = find.byKey(const ValueKey('all-season-episode-1'));
        final rect = tester.getRect(first);
        expect(rect.width, lessThan(84));
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.height, lessThanOrEqualTo(48));
        expect(tester.widget<RemoteEpisodeButton>(first).current, true);
        final label = find.descendant(of: first, matching: find.text('1'));
        expect(tester.getCenter(label).dx, closeTo(rect.center.dx, 1));
        expect(tester.getCenter(label).dy, closeTo(rect.center.dy, 1));
        if (spec.$2) {
          tester.widget<RemoteEpisodeButton>(first).focusNode!.requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(selected!.index, 1);
        } else {
          await tester.tap(find.byTooltip('跳转集数'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '100');
          await tester.tap(find.text('定位'));
          await tester.pumpAndSettle();
          final hundred = find.byKey(const ValueKey('all-season-episode-100'));
          await tester.ensureVisible(hundred);
          expect(tester.getRect(hundred).width, lessThan(84));
          await tester.tap(hundred);
          await tester.pumpAndSettle();
          expect(selected!.index, 99);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'uncached seasons can jump directly to an episode without following',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await createStore();
      final repository = SeasonRepository();
      SeriesEpisodeSelection? selected;
      await openBrowser(
        tester,
        repository,
        store,
        onResult: (value) => selected = value,
      );
      await tester.tap(find.byKey(ValueKey('all-season-${secondSeason.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('跳转集数'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '51');
      await tester.tap(find.text('定位'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('all-season-episode-51')));
      await tester.pumpAndSettle();
      expect(selected!.detail.drama.id, secondSeason.id);
      expect(selected!.index, 50);
      expect(selected!.position, 0);
      expect(store.favorites, isEmpty);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing seasons discards stale detail replies', (tester) async {
    viewport(tester, const Size(390, 844));
    final store = await createStore();
    final repository = SeasonRepository()
      ..pendingDetails[secondSeason.id] = Completer<DramaDetail>();
    await openBrowser(tester, repository, store);
    await tester.tap(find.byKey(ValueKey('all-season-${secondSeason.id}')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('all-season-${firstSeason.id}')));
    await tester.pumpAndSettle();
    repository.pendingDetails[secondSeason.id]!.complete(
      repository.makeDetail(secondSeason),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('all-season-episodes-${firstSeason.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('all-season-episodes-${secondSeason.id}')),
      findsNothing,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('VIP selection still requires explicit confirmation', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final store = await createStore();
    final repository = SeasonRepository();
    repository.detailResults[secondSeason.id] = repository.makeDetail(
      secondSeason,
      vip: true,
    );
    SeriesEpisodeSelection? selected;
    await openBrowser(
      tester,
      repository,
      store,
      onResult: (value) => selected = value,
    );
    await tester.tap(find.byKey(ValueKey('all-season-${secondSeason.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('all-season-episode-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.byType(SeriesBrowserScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('all-season-episode-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('尝试播放'));
    await tester.pumpAndSettle();
    expect(selected!.index, 1);
  });

  testWidgets('TV remote can change seasons and choose an episode', (
    tester,
  ) async {
    viewport(tester, const Size(1280, 720));
    final store = await createStore();
    final repository = SeasonRepository();
    SeriesEpisodeSelection? selected;
    await openBrowser(
      tester,
      repository,
      store,
      television: true,
      onResult: (value) => selected = value,
    );
    final label = find.text('第 1 季 · 2 集');
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('all-season-episodes-${secondSeason.id}')),
      findsOneWidget,
    );
    final episode = find.byKey(const ValueKey('all-season-episode-1'));
    await tester.ensureVisible(episode);
    await tester.tap(episode);
    await tester.pumpAndSettle();
    expect(selected!.detail.drama.id, secondSeason.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail exposes the all-season entry without favorite records', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final store = await createStore();
    final repository = SeasonRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          drama: firstSeason,
          repository: repository,
          store: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('detail-all-seasons'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(SeriesBrowserScreen), findsOneWidget);
    expect(
      find.byKey(ValueKey('all-season-${thirdSeason.id}')),
      findsOneWidget,
    );
    expect(store.favorites, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('player switches to the chosen season and exact episode', (
    tester,
  ) async {
    viewport(tester, const Size(960, 540));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = await createStore();
    final repository = SeasonRepository();
    final platform = ScriptedPlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          detail: repository.makeDetail(firstSeason),
          initialIndex: 0,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) =>
              ColoredBox(color: Colors.black, child: controls),
        ),
      ),
    );
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.text(
        '第 1 集 / 共 ${repository.makeDetail(firstSeason).episodes.length} 集',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-all-seasons')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('all-season-${thirdSeason.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('all-season-episode-2')));
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(repository.resolutions.last, (thirdSeason.id, 2));
    expect(
      find.text(
        '第 2 集 / 共 ${repository.makeDetail(thirdSeason).episodes.length} 集',
      ),
      findsOneWidget,
    );
    expect(platform.opened.last.uri, contains('synthetic-2'));
    tester.widget<PlayerControls>(find.byType(PlayerControls)).onNext!();
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.text(
        '第 3 集 / 共 ${repository.makeDetail(thirdSeason).episodes.length} 集',
      ),
      findsOneWidget,
    );
    tester.widget<PlayerControls>(find.byType(PlayerControls)).onPrevious!();
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.text(
        '第 2 集 / 共 ${repository.makeDetail(thirdSeason).episodes.length} 集',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'follow page keeps the current season and only forces marked checks manually',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await createStore();
      await store.toggleSeriesFavorite(firstSeason);
      await store.saveWatch(watch(secondSeason, 51, 1));
      final repository = SeasonRepository();
      final opened = <String>[];
      Widget page(int visit) => MaterialApp(
        home: Scaffold(
          body: SavedLibrary(
            repository: repository,
            store: store,
            history: false,
            refreshToken: visit,
            onOpen: (_) {},
            onContinue: (drama) => opened.add(drama.id),
          ),
        ),
      );
      await tester.pumpWidget(page(0));
      await tester.pumpAndSettle();
      expect(find.text('想看'), findsNothing);
      expect(find.text('在看'), findsNothing);
      expect(find.text('已看'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Banner && widget.message == '已有下季',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('第 2 季 · 第 51 集'), findsOneWidget);
      final calls = repository.catalogCalls.length;
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      expect(repository.catalogCalls.length, calls);
      await tester.tap(find.byKey(const ValueKey('follow-check-updates')));
      await tester.pumpAndSettle();
      expect(repository.catalogCalls.length, calls + 1);
      await tester.tap(find.byKey(ValueKey('saved-${firstSeason.id}')));
      expect(opened, [secondSeason.id]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final television in [false, true]) {
    testWidgets(
      television
          ? 'TV selection dialog opens all seasons and returns to playback'
          : 'phone portrait selection sheet opens all seasons and returns to playback',
      (tester) async {
        viewport(
          tester,
          television ? const Size(1280, 720) : const Size(390, 844),
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final store = await createStore();
        final repository = SeasonRepository();
        final platform = ScriptedPlayer();
        await tester.pumpWidget(
          AppLayout(
            television: television,
            child: MaterialApp(
              home: PlayerScreen(
                detail: repository.makeDetail(firstSeason),
                initialIndex: 0,
                repository: repository,
                store: store,
                playerFactory: () => Player(platformPlayer: platform),
                videoBuilder: (controls) =>
                    ColoredBox(color: Colors.black, child: controls),
              ),
            ),
          ),
        );
        for (var index = 0; index < 16; index++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.tap(
          find.byKey(
            ValueKey(television ? 'tv-episodes' : 'player-portrait-episodes'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(television ? 'tv-all-seasons' : 'player-all-seasons'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SeriesBrowserScreen), findsOneWidget);
        expect(find.byTooltip('收起面板'), findsNothing);
        await tester.tap(find.byKey(ValueKey('all-season-${thirdSeason.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('all-season-episode-2')));
        for (var index = 0; index < 20; index++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(repository.resolutions.last, (thirdSeason.id, 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }
}
