import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:duanju_app/series_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fixtures.dart';

const anchor = Drama(id: 'hongguo:1', source: 'hongguo', title: '合成故事（第一季）');
const next = Drama(id: 'hongguo:2', source: 'hongguo', title: '合成故事（2季）');

class TargetedSeasonRepository extends FixtureRepository {
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
    return CatalogPage(query == '合成故事 第2季' ? [next] : [anchor]);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'title': '第一集'}, 1),
  ]);
}

void main() {
  test('bracket and optional season prefix keep a precise series key', () {
    expect(hongguoSeriesInfo(anchor)!.key, hongguoSeriesInfo(next)!.key);
    expect(hongguoSeriesInfo(next)!.season, 2);
    expect(
      hongguoSeriesInfo(
        const Drama(id: 'hongguo:3', source: 'hongguo', title: '四季如春'),
      ),
      isNull,
    );
  });
  test('following falls back to targeted signed catalog searches', () async {
    final repository = TargetedSeasonRepository();
    final catalog = SeriesCatalog(
      anchor: anchor,
      repository: repository,
      knownDramas: [],
      allowed: () => true,
    );
    addTearDown(catalog.dispose);
    await catalog.load();
    expect(catalog.entries.map((entry) => entry.drama.id), [
      anchor.id,
      next.id,
    ]);
    expect(repository.queries, ['合成故事', '合成故事 第二季', '合成故事 第2季']);
  });
  test('automatic next season uses the same targeted recovery', () async {
    final repository = TargetedSeasonRepository();
    final result = await NextSeasonResolver(
      repository,
    ).resolve(anchor, knownDramas: [], isCurrent: () => true);
    expect(result!.drama.id, next.id);
  });
}
