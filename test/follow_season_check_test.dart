import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:duanju_app/season_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const first = Drama(
  id: 'hongguo:cache-first',
  source: 'hongguo',
  title: '缓存合成故事 第一季',
  episodes: 3,
  seriesGroupId: '100',
);
const second = Drama(
  id: 'hongguo:cache-second',
  source: 'hongguo',
  title: '缓存合成故事 第二季',
  episodes: 3,
  seriesGroupId: '100',
);
const third = Drama(
  id: 'hongguo:cache-third',
  source: 'hongguo',
  title: '缓存合成故事 第三季',
  episodes: 3,
  seriesGroupId: '100',
);

class CheckRepository extends FixtureRepository {
  List<Drama> items = [];
  AppFailure? failure;
  String warning = '';
  bool hasMore = false;
  final calls = <(String, bool)>[];
  int active = 0;
  int maximum = 0;
  String blockedPrefix = '';
  Completer<CatalogPage>? blocked;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    calls.add((query, force));
    active++;
    if (active > maximum) maximum = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failure != null) throw failure!;
      if (blocked != null && query.startsWith(blockedPrefix)) {
        return await blocked!.future;
      }
      return CatalogPage(items, warning: warning, hasMore: hasMore);
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var now = DateTime.utc(2026, 10, 30, 12);

  Future<LocalStore> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(
      await SharedPreferences.getInstance(),
      now: () => now,
      pinHasher: testPinHasher,
    );
    addTearDown(store.dispose);
    return store;
  }

  FollowUpdates follow(CheckRepository repository, LocalStore store) {
    final updates = FollowUpdates(repository, store);
    addTearDown(updates.dispose);
    return updates;
  }

  Future<void> until(bool Function() condition) async {
    for (var index = 0; index < 1000 && !condition(); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
  }

  setUp(() => now = DateTime.utc(2026, 10, 30, 12));

  test(
    'page replacement waits for an in-flight check and avoids duplicate work',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()
        ..blocked = Completer<CatalogPage>()
        ..blockedPrefix = '';
      final firstPage = follow(repository, store);
      final secondPage = follow(repository, store);
      final oldRequest = firstPage.refresh();
      await until(() => repository.active == 1);
      firstPage.cancel();
      final newRequest = secondPage.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repository.maximum, 1);
      repository.blocked!.complete(CatalogPage([]));
      await Future.wait([oldRequest, newRequest]);
      expect(repository.maximum, 1);
      expect(store.hasConfirmedNoNextSeason(first), isTrue);
    },
  );

  test('manual refresh bypasses a successful twelve hour cache', () async {
    final store = await create();
    await store.toggleSeriesFavorite(first);
    final repository = CheckRepository();
    final updates = follow(repository, store);
    await updates.refresh();
    final count = repository.calls.length;
    now = now.add(const Duration(hours: 11));
    await updates.refresh();
    expect(repository.calls.length, count);
    await updates.refresh(force: true);
    expect(repository.calls.length, greaterThan(count));
    now = now.add(const Duration(hours: 11));
    await updates.refresh();
    expect(updates.total, 0);
  });

  testWidgets(
    'switching away keeps shared follow checks running and restores results',
    (tester) async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()
        ..blocked = Completer<CatalogPage>()
        ..blockedPrefix = '';
      final shared = follow(repository, store);
      Widget followPage() => MaterialApp(
        home: Scaffold(
          body: SavedLibrary(
            repository: repository,
            store: store,
            history: false,
            followUpdates: shared,
            onOpen: (_) {},
            onContinue: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(followPage());
      await tester.pump(const Duration(milliseconds: 20));
      expect(repository.active, 1);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(shared.checking, isTrue);
      repository.blocked!.complete(CatalogPage([]));
      for (var i = 0; i < 30 && shared.checking; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(shared.checking, isFalse);
      expect(store.hasConfirmedNoNextSeason(first), isTrue);
      final calls = repository.calls.length;
      await tester.pumpWidget(followPage());
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.calls.length, calls);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'manual refresh requested during checking runs after the in-flight batch',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()
        ..blocked = Completer<CatalogPage>()
        ..blockedPrefix = '';
      final updates = follow(repository, store);
      final firstBatch = updates.refresh();
      await until(() => repository.active == 1);
      await updates.refresh(force: true);
      repository.blocked!.complete(CatalogPage([]));
      await firstBatch;
      await until(() => repository.calls.any((call) => call.$2));
      await until(() => !updates.checking);
      expect(repository.maximum, 1);
      expect(store.hasConfirmedNoNextSeason(first), isTrue);
    },
  );

  test('three tracked dramas use a single worker', () async {
    final store = await create();
    for (var index = 0; index < 3; index++) {
      await store.toggleSeriesFavorite(
        Drama(
          id: 'hongguo:serial-$index',
          source: 'hongguo',
          title: '串行故事$index 第一季',
          seriesGroupId: 'serial-$index',
        ),
      );
    }
    final repository = CheckRepository();
    await follow(repository, store).refresh();
    expect(repository.maximum, 1);
    expect(store.trackedSeries.every(store.hasConfirmedNoNextSeason), isTrue);
    now = now.add(const Duration(hours: 12, seconds: 1));
    expect(store.trackedSeries.any(store.hasConfirmedNoNextSeason), isFalse);
  });

  test(
    'six cold empty checks use three workers and warm checks make no reads',
    () async {
      final store = await create();
      for (var index = 0; index < 6; index++) {
        await store.toggleSeriesFavorite(
          Drama(
            id: 'hongguo:empty-$index',
            source: 'hongguo',
            title: '待查故事$index 第一季',
            seriesGroupId: '${index + 1}',
          ),
        );
      }
      final repository = CheckRepository();
      final updates = follow(repository, store);
      await updates.refresh();
      expect(updates.checked, 6);
      expect(updates.failed, 0);
      expect(repository.calls, hasLength(6));
      expect(repository.calls.every((call) => !call.$2), isTrue);
      expect(repository.maximum, 3);
      await updates.refresh();
      expect(updates.total, 0);
      expect(repository.calls, hasLength(6));
      now = now.add(const Duration(hours: 12, milliseconds: 1));
      await updates.refresh();
      expect(updates.checked, 6);
      expect(repository.calls, hasLength(12));
    },
  );

  test(
    'a verified first result is visible while another follow is pending',
    () async {
      final store = await create();
      const slow = Drama(
        id: 'hongguo:slow',
        source: 'hongguo',
        title: '慢合成故事 第一季',
        seriesGroupId: '200',
      );
      await store.toggleSeriesFavorite(first);
      await store.toggleSeriesFavorite(slow);
      for (var index = 0; index < 2; index++) {
        await store.toggleSeriesFavorite(
          Drama(
            id: 'hongguo:extra-$index',
            source: 'hongguo',
            title: '额外故事$index 第一季',
            seriesGroupId: '${300 + index}',
          ),
        );
      }
      final repository = CheckRepository()
        ..items = [second]
        ..blockedPrefix = '慢合成故事'
        ..blocked = Completer<CatalogPage>();
      final updates = follow(repository, store);
      final pending = updates.refresh();
      await until(() => store.hasNextSeason(first));
      expect(updates.checking, isTrue);
      expect(store.hasNextSeason(first), isTrue);
      expect(store.hasNextSeason(slow), isFalse);
      repository.blocked!.complete(CatalogPage([]));
      await pending;
      expect(updates.checked, 4);
      expect(updates.failed, 0);
    },
  );

  test(
    'positive badges skip automatic and manual refresh after restart and expiry',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final watched = WatchEntry(
        drama: first,
        episode: 2,
        position: 31,
        duration: 90,
        updatedAt: now,
      );
      await store.saveWatch(watched);
      final repository = CheckRepository()..items = [second];
      await follow(repository, store).refresh();
      expect(repository.calls, hasLength(1));
      expect(store.hasNextSeason(first), isTrue);
      final restarted = LocalStore(store.preferences, now: () => now);
      addTearDown(restarted.dispose);
      final updates = follow(repository, restarted);
      now = now.add(const Duration(days: 2));
      repository.items = [];
      repository.failure = AppFailure('should not be called');
      await updates.refresh();
      await updates.refresh(force: true);
      expect(updates.total, 0);
      expect(updates.failed, 0);
      expect(repository.calls, hasLength(1));
      expect(restarted.hasNextSeason(first), isTrue);
      expect(restarted.watched(first.id)!.toJson(), watched.toJson());
    },
  );

  test('advancing the watched season makes the next anchor eligible', () async {
    final store = await create();
    await store.toggleSeriesFavorite(first);
    final repository = CheckRepository()..items = [second];
    final updates = follow(repository, store);
    await updates.refresh();
    expect(store.hasNextSeason(first), isTrue);
    await store.saveWatch(
      WatchEntry(
        drama: second,
        episode: 1,
        position: 2,
        duration: 90,
        updatedAt: now,
      ),
    );
    expect(store.hasNextSeason(first), isFalse);
    repository.items = [third];
    await updates.refresh();
    expect(repository.calls, hasLength(2));
    expect(store.hasNextSeason(second), isTrue);
  });

  test(
    'one normal empty response ends the card even when more pages exist',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()..hasMore = true;
      final updates = follow(repository, store);
      await updates.refresh();
      expect(repository.calls, hasLength(1));
      expect(updates.checked, 1);
      expect(updates.failed, 0);
      expect(store.hasConfirmedNoNextSeason(first), isTrue);
      await updates.refresh();
      expect(repository.calls, hasLength(1));
    },
  );

  test(
    'partial unknown has short cooldown and never creates a negative result',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()..warning = '合成部分结果';
      final updates = follow(repository, store);
      await updates.refresh();
      expect(updates.failed, 1);
      expect(store.hasConfirmedNoNextSeason(first), isFalse);
      expect(repository.calls, hasLength(1));
      await updates.refresh();
      expect(repository.calls, hasLength(1));
      now = now.add(const Duration(seconds: 6));
      expect(store.shouldCheckNextSeason(first), isTrue);
      repository.warning = '';
      repository.items = [second];
      await updates.refresh();
      expect(store.hasNextSeason(first), isTrue);
      expect(repository.calls, hasLength(2));
    },
  );

  test(
    'a verified positive remains cached even with an unrelated partial warning',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()
        ..items = [second]
        ..warning = '合成其他分类未完成';
      final updates = follow(repository, store);
      await updates.refresh();
      expect(updates.failed, 0);
      expect(store.hasNextSeason(first), isTrue);
      now = now.add(const Duration(minutes: 1));
      await updates.refresh();
      expect(repository.calls, hasLength(1));
    },
  );

  test(
    'server retry time is shared and manual force cannot bypass it',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()
        ..failure = AppFailure(
          '合成限流',
          code: 'source_blocked',
          retryAt: now.add(const Duration(minutes: 5)),
        );
      final updates = follow(repository, store);
      await updates.refresh();
      expect(repository.calls, hasLength(1));
      expect(store.seasonChecksBlocked, isTrue);
      await updates.refresh(force: true);
      expect(repository.calls, hasLength(1));
      now = now.add(const Duration(minutes: 5, milliseconds: 1));
      repository.failure = null;
      await updates.refresh(force: true);
      expect(repository.calls, hasLength(2));
      expect(repository.calls.skip(1).every((call) => call.$2), isTrue);
    },
  );

  test('only an immediate verified season gets a badge', () async {
    final store = await create();
    await store.toggleSeriesFavorite(first);
    await store.refreshDramas([third]);
    expect(store.hasNextSeason(first), isFalse);
    const loose = Drama(
      id: 'hongguo:loose',
      source: 'hongguo',
      title: '缓存合成故事 第二季',
    );
    await store.refreshDramas([loose]);
    expect(store.hasNextSeason(first), isFalse);
    await store.refreshDramas([second]);
    expect(store.hasNextSeason(first), isTrue);
    expect(store.shouldCheckNextSeason(first), isTrue);
  });

  test('changed current season and cancellation discard old writes', () async {
    final store = await create();
    await store.toggleSeriesFavorite(first);
    await store.saveWatch(
      WatchEntry(
        drama: second,
        episode: 1,
        position: 20,
        duration: 60,
        updatedAt: now,
      ),
    );
    await store.applySeasonCheck(
      followed: first,
      anchor: first,
      resolvedAnchor: first,
      next: second,
      complete: true,
      isCurrent: () => true,
    );
    expect(store.hasNextSeason(first), isFalse);
    expect(store.shouldCheckNextSeason(second), isTrue);
    await store.applySeasonCheck(
      followed: first,
      anchor: second,
      resolvedAnchor: second,
      next: third,
      complete: true,
      isCurrent: () => false,
    );
    expect(store.hasNextSeason(first), isFalse);
    expect(store.shouldCheckNextSeason(second), isTrue);
  });

  test('cache is local derived state and backup import resets it', () async {
    final store = await create();
    await store.toggleSeriesFavorite(first);
    final repository = CheckRepository()..items = [second];
    await follow(repository, store).refresh();
    final backup = await store.exportBackup();
    expect(
      (jsonDecode(backup) as Map)['libraries']['default'],
      isNot(contains('seasonChecks')),
    );
    expect(
      jsonEncode(store.lanDocument.toJson()),
      isNot(contains('seasonChecks')),
    );
    expect(store.shouldCheckNextSeason(first), isFalse);
    await store.importBackup(backup);
    expect(store.favorites.single.id, first.id);
    expect(store.shouldCheckNextSeason(first), isTrue);
  });

  test(
    'official group index finds renamed seasons without merging other groups',
    () async {
      final store = await create();
      const renamed = Drama(
        id: 'hongguo:renamed',
        source: 'hongguo',
        title: '另一标题 第二季',
        seriesGroupId: '100',
      );
      const unrelated = Drama(
        id: 'hongguo:other',
        source: 'hongguo',
        title: '缓存合成故事 第二季',
        seriesGroupId: '999',
      );
      await store.toggleSeriesFavorite(first);
      await store.refreshDramas([renamed, unrelated]);
      expect(
        store.seriesDramasFor(first).map((drama) => drama.id),
        contains(renamed.id),
      );
      expect(store.followedSeries(renamed)?.id, first.id);
      expect(store.followedSeries(unrelated), isNull);
      expect(store.hasNextSeason(first), isTrue);
    },
  );

  test('clock rollback never makes a derived check fresh', () {
    final check = SeasonCheck.observed(
      first,
      checkedAt: now,
      nextId: null,
      complete: true,
    );
    expect(check.isFresh(now.subtract(const Duration(seconds: 1))), isFalse);
    expect(
      check.isFresh(now.add(const Duration(hours: 11, minutes: 59))),
      isTrue,
    );
    expect(check.isFresh(now.add(const Duration(hours: 12))), isFalse);
    expect(SeasonCheck.fromJson(check.toJson()).matches(first), isTrue);
  });

  test(
    'auto playback warm view aligns sparse anchor and honors complete none',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()..items = [second];
      await follow(repository, store).refresh();
      final sparse = Drama(
        id: first.id,
        source: first.source,
        title: first.title,
      );
      final warm = store.nextSeasonDramasFor(sparse);
      expect(warm.first.seriesGroupId, '100');
      expect(warm.map((drama) => drama.id), [first.id, second.id]);
      final resolver = NextSeasonResolver(repository);
      final before = repository.calls.length;
      final ready = await resolver.resolve(
        sparse,
        knownDramas: warm,
        isCurrent: () => true,
      );
      expect(ready?.drama.id, second.id);
      expect(repository.calls, hasLength(before));
      await store.applySeasonCheck(
        followed: first,
        anchor: first,
        resolvedAnchor: first,
        next: null,
        complete: true,
        isCurrent: () => true,
      );
      expect(
        store.seriesDramasFor(first).map((drama) => drama.id),
        contains(second.id),
      );
      expect(store.nextSeasonDramasFor(sparse).map((drama) => drama.id), [
        first.id,
      ]);
      expect(store.hasFreshNoNextSeason(sparse), isTrue);
      repository.items = [];
      final absent = await resolver.resolve(
        sparse,
        knownDramas: store.nextSeasonDramasFor(sparse),
        isCurrent: () => true,
      );
      expect(absent, isNull);
      expect(repository.calls, hasLength(before + 3));
    },
  );

  test(
    'expired or failed overlays never feed an old positive to auto playback',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository()..items = [second];
      final updates = follow(repository, store);
      await updates.refresh();
      now = now.add(const Duration(hours: 12, seconds: 1));
      expect(store.nextSeasonDramasFor(first).map((drama) => drama.id), [
        first.id,
      ]);
      repository.failure = AppFailure('合成检查失败');
      await updates.refresh();
      expect(store.hasNextSeason(first), isTrue);
      expect(store.hasFreshNoNextSeason(first), isFalse);
      expect(store.nextSeasonDramasFor(first).map((drama) => drama.id), [
        first.id,
      ]);
      expect(
        store.seriesDramasFor(first).map((drama) => drama.id),
        contains(second.id),
      );
      now = now.add(const Duration(seconds: 6));
      expect(store.nextSeasonDramasFor(first).map((drama) => drama.id), [
        first.id,
      ]);
    },
  );

  test(
    'new explicit group or season evidence cannot inherit an old warm overlay',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      await follow(CheckRepository()..items = [second], store).refresh();
      final changedGroup = Drama(
        id: first.id,
        source: first.source,
        title: first.title,
        seriesGroupId: '999',
      );
      final changed = store.nextSeasonDramasFor(changedGroup);
      expect(changed, hasLength(1));
      expect(changed.single.seriesGroupId, '999');
      final changedSeason = Drama(
        id: first.id,
        source: first.source,
        title: '缓存合成故事 第二季',
      );
      final moved = store.nextSeasonDramasFor(changedSeason);
      expect(moved, hasLength(1));
      expect(moved.single.title, changedSeason.title);
    },
  );

  test(
    'only complete negative within its actual TTL can skip auto search',
    () async {
      final store = await create();
      await store.toggleSeriesFavorite(first);
      final repository = CheckRepository();
      final updates = follow(repository, store);
      await updates.refresh();
      final sparse = Drama(
        id: first.id,
        source: first.source,
        title: first.title,
      );
      expect(store.hasFreshNoNextSeason(sparse), isTrue);
      now = now.subtract(const Duration(seconds: 1));
      expect(store.hasFreshNoNextSeason(sparse), isFalse);
      now = now.add(const Duration(hours: 12, seconds: 1));
      expect(store.hasFreshNoNextSeason(sparse), isFalse);
      repository.warning = '合成部分响应';
      await updates.refresh();
      expect(store.hasFreshNoNextSeason(sparse), isFalse);
      expect(store.nextSeasonDramasFor(sparse), hasLength(1));
      now = now.add(const Duration(seconds: 6));
      repository.warning = '';
      repository.failure = AppFailure(
        '合成限制',
        code: 'source_blocked',
        retryAt: now.add(const Duration(minutes: 3)),
      );
      await updates.refresh();
      expect(store.seasonChecksBlocked, isTrue);
      expect(store.hasFreshNoNextSeason(sparse), isFalse);
    },
  );
}
