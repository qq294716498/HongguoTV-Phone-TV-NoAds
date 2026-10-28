import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:duanju_app/series_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

const anchor = Drama(
  id: 'hongguo:42',
  source: 'hongguo',
  title: '谁说没灵根不能修仙的？之无灵证道第42季',
  description: '韩凡在琉璃剑宗修仙。',
);
const next = Drama(
  id: 'hongguo:43',
  source: 'hongguo',
  title: '谁说没灵根不能修仙的？之无灵证道43季',
  description: '韩凡在琉璃剑宗修仙。',
);

class SeasonRepository extends FixtureRepository {
  final searchRequests = <(String, int)>[];
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    searchRequests.add((query, page));
    if (query == '无灵证道 第43季')
      return CatalogPage(page == 2 ? [next] : [anchor], hasMore: page < 2);
    return CatalogPage([anchor]);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'title': '第一集'}, 1),
  ]);
}

class CapturedRepository extends SeasonRepository {
  CapturedRepository(this.data);
  final Map<String, dynamic> data;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    final rows = (data['searches'] as List).where(
      (row) => row['query'] == query && row['page'] == page,
    );
    if (rows.isEmpty) return CatalogPage([]);
    final row = rows.first;
    return CatalogPage(
      (row['items'] as List).map((d) => Drama.fromJson(d)).toList(),
      hasMore: row['hasMore'] == true,
      warning: row['warning'] ?? '',
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final row = data['details'][drama.id];
    if (row == null) return super.detail(drama);
    final chapters = row['chapters'] as List;
    return DramaDetail(Drama.fromJson(row['drama']), [
      for (var i = 0; i < chapters.length; i++)
        Episode(Map<String, dynamic>.from(chapters[i]), i + 1),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'subtitle query recovers season 43 on page two in both entry points',
    () async {
      final repository = SeasonRepository();
      final catalog = SeriesCatalog(
        anchor: anchor,
        repository: repository,
        knownDramas: [],
        allowed: () => true,
      );
      addTearDown(catalog.dispose);
      await catalog.load();
      expect(catalog.entries.map((e) => e.season), [42, 43]);
      expect(repository.searchRequests, contains(('无灵证道 第43季', 2)));
      final detail = await NextSeasonResolver(
        repository,
      ).resolve(anchor, knownDramas: [], isCurrent: () => true);
      expect(detail?.drama.id, next.id);
      expect(
        hongguoSameSeries(
          anchor,
          const Drama(
            id: 'wrong',
            source: 'hongguo',
            title: '谁说没灵根不能修仙的？之无灵证道43季',
            description: '李明在凡间修仙。',
          ),
        ),
        isFalse,
      );
    },
  );
  final path = Platform.environment['HG_LINGGEN_EXPORT'];
  test(
    'live captured season 42 discovers 43 and persists follow notice',
    () async {
      final data =
          jsonDecode(File(path!).readAsStringSync()) as Map<String, dynamic>;
      final repository = CapturedRepository(data);
      final current = Drama.fromJson(
        data['details']['hongguo:7695230118729354265']['drama'],
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LocalStore(prefs);
      addTearDown(store.dispose);
      await store.toggleSeriesFavorite(current);
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      await updates.refresh(force: true);
      expect(store.hasNextSeason(current), isTrue);
      final detail = await NextSeasonResolver(
        repository,
      ).resolve(current, knownDramas: [], isCurrent: () => true);
      expect(detail?.drama.id, 'hongguo:7699400314490735678');
      expect(detail!.episodes, isNotEmpty);
      final restored = LocalStore(prefs);
      addTearDown(restored.dispose);
      expect(restored.hasNextSeason(current), isTrue);
    },
    skip: path == null ? 'requires opt-in upstream metadata' : false,
  );
}
