import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

const anchor = Drama(
  id: 'hongguo:1',
  source: 'hongguo',
  title: '合成故事 第一季',
  seriesGroupId: '100',
);
const next = Drama(
  id: 'hongguo:2',
  source: 'hongguo',
  title: '合成故事 第二季',
  seriesGroupId: '100',
);
const third = Drama(
  id: 'hongguo:3',
  source: 'hongguo',
  title: '合成故事 第三季',
  seriesGroupId: '100',
);
const unverifiedAnchor = Drama(
  id: 'hongguo:1',
  source: 'hongguo',
  title: '合成故事 第一季',
);
const unverifiedNext = Drama(
  id: 'hongguo:2',
  source: 'hongguo',
  title: '合成故事 第二季',
);

class LookupRepository extends FixtureRepository {
  final queries = <(String, int, bool)>[];
  final metadataIds = <String>[];
  final detailIds = <String>[];
  final sessions = <TrackedLookupSession>[];
  Future<CatalogPage> Function(String, int)? onCatalog;
  Future<Drama?> Function(Drama)? onMetadata;
  Future<DramaDetail> Function(Drama)? onDetail;

  @override
  SeasonLookupSession seasonLookup() {
    final session = TrackedLookupSession(this);
    sessions.add(session);
    return session;
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    queries.add((query, page, force));
    return await onCatalog?.call(query, page) ?? CatalogPage([]);
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    metadataIds.add(drama.id);
    return await onMetadata?.call(drama);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailIds.add(drama.id);
    return await onDetail?.call(drama) ??
        DramaDetail(drama, [
          Episode({'id': '1'}, 1),
        ]);
  }
}

class TrackedLookupSession extends SeasonLookupSession {
  TrackedLookupSession(super.repository);
  bool disposed = false;
  int cancellations = 0;

  @override
  Future<void> cancelPending() async {
    cancellations++;
    await super.cancelPending();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<NextSeasonLookupResult> lookup(
    LookupRepository repository, {
    Drama current = anchor,
    Iterable<Drama> known = const [],
    bool trust = true,
    bool force = false,
  }) => NextSeasonResolver(repository).lookup(
    current,
    knownDramas: known,
    isCurrent: () => true,
    trustKnownNext: trust,
    force: force,
  );

  test(
    'verified known next skips metadata and search and reads detail once',
    () async {
      final repository = LookupRepository();
      final detail = await NextSeasonResolver(
        repository,
      ).resolve(anchor, knownDramas: [next], isCurrent: () => true);
      expect(detail?.drama.id, next.id);
      expect(repository.queries, isEmpty);
      expect(repository.metadataIds, isEmpty);
      expect(repository.detailIds, [next.id]);
      expect(repository.sessions.single.disposed, isTrue);
    },
  );

  test(
    'trusted warm lookup merges a cached anchor without replacing explicit input',
    () async {
      final repository = LookupRepository();
      final result = await lookup(
        repository,
        current: unverifiedAnchor,
        known: [anchor, next],
      );
      expect(result.anchor.seriesGroupId, '100');
      expect(result.next?.id, next.id);
      expect(repository.queries, isEmpty);
      expect(repository.metadataIds, isEmpty);
      expect(repository.detailIds, [next.id]);
      const changed = Drama(
        id: 'hongguo:1',
        source: 'hongguo',
        title: '合成故事 第二季',
        seriesGroupId: '200',
      );
      final fresh = await lookup(
        repository,
        current: changed,
        known: [anchor, next],
      );
      expect(fresh.anchor.title, changed.title);
      expect(fresh.anchor.seriesGroupId, '200');
      expect(fresh.next, isNull);
      expect(fresh.complete, isTrue);
    },
  );

  test(
    'untrusted lookup does not take cached anchor or next metadata',
    () async {
      final repository = LookupRepository();
      final result = await lookup(
        repository,
        current: unverifiedAnchor,
        known: [anchor, next],
        trust: false,
      );
      expect(result.anchor.seriesGroupId, isEmpty);
      expect(result.next, isNull);
      expect(result.complete, isTrue);
      expect(repository.detailIds, isEmpty);
      expect(repository.queries, hasLength(3));
    },
  );

  test('group conflict found in metadata skips candidate details', () async {
    const otherGroup = Drama(
      id: 'hongguo:2',
      source: 'hongguo',
      title: '合成故事 第二季',
      seriesGroupId: '200',
    );
    final repository = LookupRepository();
    repository.onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
    repository.onMetadata = (drama) async =>
        drama.id == anchor.id ? anchor : otherGroup;
    final result = await lookup(repository, current: unverifiedAnchor);
    expect(result.next, isNull);
    expect(result.complete, isTrue);
    expect(repository.metadataIds, [next.id, anchor.id]);
    expect(repository.detailIds, isEmpty);
  });

  test(
    'anchor metadata rejects later conflicting snapshot candidates without details',
    () async {
      const otherGroup = Drama(
        id: 'hongguo:8',
        source: 'hongguo',
        title: '合成故事 第二季',
        seriesGroupId: '200',
      );
      final repository = LookupRepository();
      repository.onCatalog = (_, _) async =>
          CatalogPage([unverifiedNext, otherGroup]);
      repository.onMetadata = (drama) async =>
          drama.id == anchor.id ? anchor : next;
      final result = await lookup(repository, current: unverifiedAnchor);
      expect(result.next?.id, next.id);
      expect(repository.detailIds, [next.id]);
      expect(repository.metadataIds, isNot(contains(otherGroup.id)));
    },
  );

  test(
    'expired known next cannot renew itself without a current search',
    () async {
      final repository = LookupRepository();
      final result = await lookup(repository, known: [next], trust: false);
      expect(result.next, isNull);
      expect(result.complete, isTrue);
      expect(repository.queries, [
        ('合成故事 第2季', 1, false),
        ('合成故事 第二季', 1, false),
        ('合成故事', 1, false),
      ]);
      expect(repository.metadataIds, isEmpty);
      expect(
        result.candidates.map((drama) => drama.id),
        isNot(contains(next.id)),
      );
    },
  );

  test(
    'six cold empty follows need eighteen searches and no HTML metadata',
    () async {
      final repository = LookupRepository();
      for (var index = 0; index < 6; index++) {
        final result = await lookup(
          repository,
          current: Drama(
            id: 'hongguo:${index + 10}',
            source: 'hongguo',
            title: '合成待续故事$index 第一季',
          ),
          trust: false,
        );
        expect(result.next, isNull);
        expect(result.complete, isTrue);
      }
      expect(repository.queries, hasLength(18));
      expect(repository.queries.every((query) => !query.$3), isTrue);
      expect(repository.metadataIds, isEmpty);
      expect(repository.detailIds, isEmpty);
      expect(repository.sessions.every((session) => session.disposed), isTrue);
    },
  );

  test(
    'targeted verified hit stops before further pages and broad search',
    () async {
      final repository = LookupRepository()
        ..onCatalog = (_, _) async => CatalogPage([next], hasMore: true);
      final result = await lookup(repository);
      expect(result.next?.id, next.id);
      expect(repository.queries, [('合成故事 第2季', 1, false)]);
      expect(repository.detailIds, [next.id]);
    },
  );

  test('only explicit force invalidates the first page search cache', () async {
    final repository = LookupRepository();
    await lookup(repository, known: [next], force: true);
    expect(repository.queries, hasLength(3));
    expect(repository.queries.every((query) => query.$3), isTrue);
    expect(repository.detailIds, isEmpty);
  });

  test('broad search remains a fallback after targeted terms', () async {
    final repository = LookupRepository()
      ..onCatalog = (query, _) async =>
          CatalogPage(query == '合成故事' ? [next] : []);
    final result = await lookup(repository);
    expect(result.next?.id, next.id);
    expect(repository.queries.map((query) => query.$1), [
      '合成故事 第2季',
      '合成故事 第二季',
      '合成故事',
    ]);
  });

  test(
    'bare numeric and subtitle queries stay ahead of Chinese variants',
    () async {
      const current = Drama(
        id: 'hongguo:42',
        source: 'hongguo',
        title: '谁说没灵根不能修仙的？之无灵证道42',
        seriesGroupId: '100',
      );
      final repository = LookupRepository();
      await lookup(repository, current: current);
      expect(repository.queries.map((query) => query.$1), [
        '无灵证道 第43季',
        '谁说没灵根不能修仙的？之无灵证道43',
        '谁说没灵根不能修仙的？之无灵证道',
      ]);
      expect(repository.metadataIds, isEmpty);
    },
  );

  test(
    'official group proves a renamed next and rejects a same-name other group',
    () async {
      const renamed = Drama(
        id: 'hongguo:4',
        source: 'hongguo',
        title: '全新剧名 第二季',
        seriesGroupId: '100',
      );
      const impostor = Drama(
        id: 'hongguo:5',
        source: 'hongguo',
        title: '合成故事 第二季',
        seriesGroupId: '200',
      );
      expect(hongguoVerifiedSameSeries(anchor, renamed), isTrue);
      expect(hongguoVerifiedSameSeries(anchor, impostor), isFalse);
      final repository = LookupRepository()
        ..onCatalog = (_, _) async => CatalogPage([impostor, renamed]);
      final result = await lookup(repository);
      expect(result.next?.id, renamed.id);
      expect(repository.detailIds, [renamed.id]);
    },
  );

  test(
    'missing synopsis requires independent metadata before accepting a hit',
    () async {
      final repository = LookupRepository();
      repository.onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
      repository.onMetadata = (drama) async =>
          drama.id == anchor.id ? anchor : next;
      final result = await lookup(repository, current: unverifiedAnchor);
      expect(result.anchor.seriesGroupId, '100');
      expect(result.next?.seriesGroupId, '100');
      expect(repository.metadataIds, [next.id, anchor.id]);
      expect(repository.detailIds, [next.id]);
    },
  );

  test(
    'same title without group or synopsis is unknown rather than positive or none',
    () async {
      final repository = LookupRepository()
        ..onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
      final result = await lookup(repository, current: unverifiedAnchor);
      expect(result.next, isNull);
      expect(result.complete, isFalse);
      expect(result.warning, isNotEmpty);
      expect(repository.detailIds, [anchor.id, next.id]);
    },
  );

  test('fresh unrelated synopsis rejects a same-name candidate', () async {
    const current = Drama(
      id: 'hongguo:1',
      source: 'hongguo',
      title: '合成故事 第一季',
      description: '陈昊宇在异世觉醒。',
    );
    final repository = LookupRepository();
    repository.onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
    repository.onDetail = (drama) async => DramaDetail(
      Drama(
        id: drama.id,
        source: drama.source,
        title: drama.title,
        description: '林凡在都市重生。',
      ),
      [
        Episode({'id': '1'}, 1),
      ],
    );
    final result = await lookup(repository, current: current);
    expect(result.next, isNull);
    expect(result.complete, isTrue);
    expect(repository.detailIds, [next.id]);
  });

  test('a season gap never counts as the immediate next season', () async {
    final repository = LookupRepository()
      ..onCatalog = (_, _) async => CatalogPage([third]);
    final result = await lookup(repository);
    expect(result.next, isNull);
    expect(result.complete, isTrue);
    expect(repository.detailIds, isEmpty);
  });

  test('duplicate same-season versions remain ambiguous', () async {
    const duplicate = Drama(
      id: 'hongguo:9',
      source: 'hongguo',
      title: '合成故事 第2季',
      seriesGroupId: '100',
    );
    final repository = LookupRepository()
      ..onCatalog = (_, _) async => CatalogPage([next, duplicate]);
    final result = await lookup(repository);
    expect(result.ambiguous, isTrue);
    expect(result.next, isNull);
    await expectLater(
      NextSeasonResolver(
        repository,
      ).resolve(anchor, knownDramas: [next, duplicate], isCurrent: () => true),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          'next_season_ambiguous',
        ),
      ),
    );
  });

  test('final detail identity mismatch is rejected', () async {
    final repository = LookupRepository();
    repository.onCatalog = (_, _) async => CatalogPage([next]);
    repository.onDetail = (_) async => DramaDetail(third, [
      Episode({'id': '1'}, 1),
    ]);
    await expectLater(
      lookup(repository),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          'next_season_ambiguous',
        ),
      ),
    );
  });

  test('a listed next without episodes is not reported as playable', () async {
    final repository = LookupRepository();
    repository.onCatalog = (_, _) async => CatalogPage([next]);
    repository.onDetail = (drama) async => DramaDetail(drama, []);
    await expectLater(
      lookup(repository),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'code',
          'next_season_empty',
        ),
      ),
    );
  });

  test(
    'VIP next exists but automatic playback retains the VIP guard',
    () async {
      final repository = LookupRepository();
      repository.onCatalog = (_, _) async => CatalogPage([next]);
      repository.onDetail = (drama) async => DramaDetail(drama, [
        Episode({'id': '1', 'vip': true}, 1),
      ]);
      expect((await lookup(repository)).next?.id, next.id);
      await expectLater(
        NextSeasonResolver(
          repository,
        ).resolve(anchor, knownDramas: [], isCurrent: () => true),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            'next_season_vip',
          ),
        ),
      );
    },
  );

  test(
    'partial and truncated responses cannot produce a complete negative',
    () async {
      for (final warning in ['', '部分分类尚未完成']) {
        final repository = LookupRepository()
          ..onCatalog = (_, _) async =>
              CatalogPage([], hasMore: true, warning: warning);
        final result = await lookup(repository);
        expect(result.next, isNull);
        expect(result.complete, isFalse);
        expect(repository.queries, hasLength(warning.isEmpty ? 9 : 3));
      }
    },
  );

  test('partial response can retain an independently verified next', () async {
    final repository = LookupRepository()
      ..onCatalog = (_, _) async => CatalogPage([next], warning: '部分分类尚未完成');
    final result = await lookup(repository);
    expect(result.next?.id, next.id);
    expect(result.warning, '部分分类尚未完成');
    expect(result.complete, isFalse);
  });

  test(
    'metadata timeout cancels in-flight work and never caches an empty certainty',
    () async {
      final pending = Completer<Drama?>();
      final repository = LookupRepository();
      repository.onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
      repository.onMetadata = (_) => pending.future;
      final result = await NextSeasonResolver(
        repository,
        lookupBudget: const Duration(milliseconds: 100),
        requestBudget: const Duration(milliseconds: 5),
      ).lookup(anchor, knownDramas: [], isCurrent: () => true);
      expect(result.next, isNull);
      expect(result.complete, isFalse);
      expect(repository.sessions.single.cancellations, 1);
      expect(repository.sessions.single.disposed, isTrue);
      pending.complete(anchor);
    },
  );

  test('existing character evidence skips optional HTML metadata', () async {
    const current = Drama(
      id: 'hongguo:1',
      source: 'hongguo',
      title: '合成故事 第一季',
      description: '林凡在古界获得力量。',
    );
    const sequel = Drama(
      id: 'hongguo:2',
      source: 'hongguo',
      title: '合成故事 第二季',
      description: '林凡在古界继续修炼。',
    );
    final pending = Completer<Drama?>();
    final repository = LookupRepository();
    repository.onMetadata = (_) => pending.future;
    repository.onCatalog = (_, _) async => CatalogPage([sequel]);
    final result = await NextSeasonResolver(
      repository,
      lookupBudget: const Duration(milliseconds: 100),
      requestBudget: const Duration(milliseconds: 5),
    ).lookup(current, knownDramas: [], isCurrent: () => true);
    expect(result.next?.id, sequel.id);
    expect(repository.sessions.single.cancellations, 0);
    expect(repository.metadataIds, isEmpty);
    pending.complete(current);
  });

  test(
    'metadata timeout allows later detail evidence within the same budget',
    () async {
      const current = Drama(
        id: 'hongguo:1',
        source: 'hongguo',
        title: '合成故事 第一季',
        description: '林凡在古界获得力量。',
      );
      const sequel = Drama(
        id: 'hongguo:2',
        source: 'hongguo',
        title: '合成故事 第二季',
        description: '林凡在古界继续修炼。',
      );
      final pending = Completer<Drama?>();
      final repository = LookupRepository();
      repository.onCatalog = (_, _) async => CatalogPage([unverifiedNext]);
      repository.onMetadata = (drama) =>
          drama.id == next.id ? pending.future : Future.value(null);
      repository.onDetail = (_) async => DramaDetail(sequel, [
        Episode({'id': '1'}, 1),
      ]);
      final result = await NextSeasonResolver(
        repository,
        lookupBudget: const Duration(milliseconds: 100),
        requestBudget: const Duration(milliseconds: 5),
      ).lookup(current, knownDramas: [], isCurrent: () => true);
      expect(result.next?.id, next.id);
      expect(result.warning, isNotEmpty);
      expect(repository.sessions.single.cancellations, 1);
      pending.complete(sequel);
    },
  );

  test(
    'source backoff stops further searches and still disposes the lookup',
    () async {
      final repository = LookupRepository()
        ..onCatalog = (_, _) async =>
            throw AppFailure('稍后重试', code: 'source_blocked');
      await expectLater(
        lookup(repository),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            'source_blocked',
          ),
        ),
      );
      expect(repository.queries, hasLength(1));
      expect(repository.sessions.single.disposed, isTrue);
    },
  );

  test(
    'cancellation during detail rejects late results and closes the session',
    () async {
      final pending = Completer<DramaDetail>();
      var current = true;
      final repository = LookupRepository()..onDetail = (_) => pending.future;
      final result = NextSeasonResolver(
        repository,
      ).resolve(anchor, knownDramas: [next], isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(
        DramaDetail(next, [
          Episode({'id': '1'}, 1),
        ]),
      );
      await expectLater(
        result,
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            'next_season_cancelled',
          ),
        ),
      );
      expect(repository.sessions.single.disposed, isTrue);
    },
  );
}
