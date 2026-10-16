import 'dart:convert';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('large library renders repeated series summaries', () async {
    final dramas = [
      for (var i = 0; i < 1000; i++)
        Drama(
          id: 'hongguo:perf-$i',
          source: 'hongguo',
          title: '合成性能故事${i ~/ 4} 第${i % 4 + 1}季',
          episodes: 80,
        ),
    ];
    final favorites = [for (var i = 0; i < 24; i++) dramas[i * 4]];
    final history = [
      for (var i = 0; i < 60; i++)
        WatchEntry(
          drama: dramas[i],
          episode: 3,
          position: 15,
          duration: 60,
          updatedAt: DateTime.utc(2026, 10, 16).add(Duration(minutes: i)),
        ),
    ];
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode(favorites.map((d) => d.toJson()).toList()),
      'history': jsonEncode(history.map((e) => e.toJson()).toList()),
      'seriesCandidates': jsonEncode(dramas.map((d) => d.toJson()).toList()),
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final timer = Stopwatch()..start();
    for (var frame = 0; frame < 2; frame++) {
      final tracked = store.trackedSeries;
      expect(tracked, hasLength(24));
      for (final drama in tracked) {
        store.seriesWatch(drama);
        store.hasNextSeason(drama);
        expect(store.followedSeries(drama), isNotNull);
      }
      for (final drama in dramas.take(60)) {
        store.followedSeries(drama);
      }
    }
    timer.stop();
    debugPrint('SERIES_BENCHMARK_MS=${timer.elapsedMicroseconds / 1000}');
  });
}
