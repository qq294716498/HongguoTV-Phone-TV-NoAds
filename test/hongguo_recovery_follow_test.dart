import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:duanju_app/series_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const original = Drama(
  id: 'hongguo:a',
  source: 'hongguo',
  title: '觉醒伪神：神明弃我我自为神2',
  description: '主角林凡被神明抛弃，与苏月踏上逆天之路。',
  episodes: 2,
);
const sequel = Drama(
  id: 'hongguo:b',
  source: 'hongguo',
  title: '觉醒伪神：神明弃我自为神3',
  description: '林凡获得新的力量，苏月在危机中与他并肩作战。',
  episodes: 2,
);

class RecoveringRepository extends FixtureRepository {
  int calls = 0;
  String code = 'hongguo_empty_response';
  int failures = 2;
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    calls++;
    if (calls <= failures) throw AppFailure('empty', code: code);
    return const PlaybackPlan(
      url: 'file:///synthetic.mp4',
      session: 'recovered',
    );
  }
}

class SearchRecoveryRepository extends FixtureRepository {
  final queries = <String>[];
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    queries.add(query);
    if (queries.length == 1) throw AppFailure('temporary search failure');
    return CatalogPage([sequel]);
  }
}

class ThinDescriptionRepository extends FixtureRepository {
  int hydrated = 0;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage([
    Drama(id: sequel.id, source: sequel.source, title: sequel.title),
  ]);
  @override
  Future<DramaDetail> detail(Drama drama) async {
    hydrated++;
    return DramaDetail(drama.id == sequel.id ? sequel : original, [
      Episode({'id': '1'}, 1),
    ]);
  }
}

void main() {
  test(
    'near-title search results fetch missing synopsis before matching',
    () async {
      final repository = ThinDescriptionRepository();
      final catalog = SeriesCatalog(
        anchor: original,
        repository: repository,
        knownDramas: [],
        allowed: () => true,
      );
      await catalog.load();
      expect(catalog.entries.map((e) => e.drama.id), contains(sequel.id));
      expect(repository.hydrated, 1);
      catalog.dispose();
      final result = await NextSeasonResolver(
        repository,
      ).resolve(original, knownDramas: [], isCurrent: () => true);
      expect(result?.drama.id, sequel.id);
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  test('empty source resolves on third round without changing drama', () async {
    final repository = RecoveringRepository();
    final loader = PlaybackLoader(repository, retryDelay: Duration.zero);
    final rounds = <int>[];
    final plan = await loader.load(
      original,
      Episode({'id': '1'}, 1),
      onRetry: rounds.add,
    );
    expect(plan?.session, 'recovered');
    expect(rounds, [2, 3]);
    expect(repository.calls, 3);
    await loader.close();
  });
  test(
    'persistent empty body is bounded and source restriction is not retried',
    () async {
      for (final code in [
        'hongguo_empty_response',
        'source_blocked',
        'local_media',
      ]) {
        final repository = RecoveringRepository()
          ..failures = 20
          ..code = code;
        final loader = PlaybackLoader(repository, retryDelay: Duration.zero);
        await expectLater(
          loader.load(original, Episode({'id': '1'}, 1)),
          throwsA(isA<AppFailure>()),
        );
        expect(repository.calls, code == 'hongguo_empty_response' ? 3 : 1);
        await loader.close();
      }
    },
  );
  test('cancel during backoff prevents another source request', () async {
    final repository = RecoveringRepository();
    final ready = Completer<void>();
    final loader = PlaybackLoader(
      repository,
      retryDelay: const Duration(milliseconds: 20),
    );
    final pending = loader.load(
      original,
      Episode({'id': '1'}, 1),
      onRetry: (_) => ready.complete(),
    );
    await ready.future;
    await loader.cancel();
    expect(await pending, isNull);
    expect(repository.calls, 1);
    await loader.close();
  });
  test(
    'numeric seasons and close titles use shared synopsis character evidence',
    () {
      expect(hongguoSeriesInfo(original)?.season, 2);
      expect(hongguoSeriesInfo(sequel)?.season, 3);
      expect(hongguoSameSeries(original, sequel), isTrue);
      expect(
        hongguoSameSeries(
          original,
          const Drama(
            id: 'hongguo:c',
            source: 'hongguo',
            title: '觉醒伪神：神明弃我自为神3',
            description: '主角陈浩重生归来。',
          ),
        ),
        isFalse,
      );
      expect(
        hongguoSameSeries(
          original,
          const Drama(
            id: 'hongguo:d',
            source: 'hongguo',
            title: '都市神医第三季',
            description: '林凡获得新的力量。',
          ),
        ),
        isFalse,
      );
      expect(hongguoSeriesEntries(original, [sequel]).map((e) => e.season), [
        2,
        3,
      ]);
    },
  );
  test('close-title follow notice survives local store reload', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    await store.toggleSeriesFavorite(original);
    await store.refreshDramas([sequel]);
    expect(store.hasNextSeason(original), isTrue);
    final restored = LocalStore(preferences);
    expect(restored.hasNextSeason(original), isTrue);
    expect(restored.followedSeries(sequel)?.id, original.id);
    restored.dispose();
    store.dispose();
  });
  test(
    'automatic next season also recovers search and uses character match',
    () async {
      final repository = SearchRecoveryRepository();
      final result = await NextSeasonResolver(
        repository,
      ).resolve(original, knownDramas: [], isCurrent: () => true);
      expect(result?.drama.id, sequel.id);
    },
  );
  test('base search failure still tries targeted next season search', () async {
    final repository = SearchRecoveryRepository();
    final catalog = SeriesCatalog(
      anchor: original,
      repository: repository,
      knownDramas: [],
      allowed: () => true,
    );
    await catalog.load();
    expect(catalog.entries.map((e) => e.drama.id), contains(sequel.id));
    expect(repository.queries.length, 2);
    catalog.dispose();
  });
}
