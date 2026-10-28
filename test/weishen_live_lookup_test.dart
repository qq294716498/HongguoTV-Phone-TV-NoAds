import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class CapturedSeriesRepository extends FixtureRepository {
  CapturedSeriesRepository(this.rows, this.details);
  final List<Drama> rows;
  final Map<String, dynamic> details;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage(rows);
  @override
  Future<DramaDetail> detail(Drama drama) async {
    final data = details[drama.id] as Map<String, dynamic>;
    final chapters = data['chapters'] as List;
    return DramaDetail(Drama.fromJson(data['drama']), [
      for (var i = 0; i < chapters.length; i++)
        Episode(Map<String, dynamic>.from(chapters[i]), i + 1),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['HG_SERIES_EXPORT'];
  test(
    'real Weishen season two follows and continues to season three',
    () async {
      final rows = (jsonDecode(File(path!).readAsStringSync()) as List)
          .map((row) => Drama.fromJson(row))
          .toList();
      final details = Map<String, dynamic>.from(
        jsonDecode(File('$path.details.json').readAsStringSync()),
      );
      final repository = CapturedSeriesRepository(rows, details);
      final anchor = rows.singleWhere(
        (d) => d.id == 'hongguo:7676383631534722073',
      );
      final next = rows.singleWhere(
        (d) => d.id == 'hongguo:7677963872489196569',
      );
      expect(hongguoSeriesCharacters(anchor.description), contains('陈昊宇'));
      expect(hongguoSameSeries(anchor, next), isTrue);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      addTearDown(store.dispose);
      await store.toggleSeriesFavorite(anchor);
      final updates = FollowUpdates(repository, store);
      addTearDown(updates.dispose);
      await updates.refresh(force: true);
      expect(updates.failed, 0);
      expect(store.hasNextSeason(anchor), isTrue);
      final result = await NextSeasonResolver(repository).resolve(
        anchor,
        knownDramas: store.seriesDramasFor(anchor),
        isCurrent: () => true,
      );
      expect(result?.drama.id, next.id);
      expect(result?.episodes.length, 120);
      expect(result?.episodes.first.number, 1);
      final restored = LocalStore(preferences);
      addTearDown(restored.dispose);
      expect(restored.hasNextSeason(anchor), isTrue);
    },
    skip: path == null
        ? 'requires opt-in upstream series metadata export'
        : false,
  );
}
