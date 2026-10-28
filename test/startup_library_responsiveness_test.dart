import 'dart:async';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'large catalog merge yields to UI events and preserves next season',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      addTearDown(store.dispose);
      for (var i = 0; i < 100; i++) {
        await store.toggleFavorite(
          Drama(
            id: 'hongguo:favorite$i',
            source: 'hongguo',
            title: '追剧编号${i}第一季',
            description: '少年林凡在山村觉醒，获得神秘传承。' * 10,
          ),
        );
      }
      const anchor = Drama(
        id: 'hongguo:weishen2',
        source: 'hongguo',
        title: '觉醒伪神：神明弃我我自为神2',
        description: '陈昊宇在异世觉醒。',
      );
      const sequel = Drama(
        id: 'hongguo:weishen3',
        source: 'hongguo',
        title: '觉醒伪神：神明弃我我自为神3',
        description: '陈昊宇获得神秘力量。',
      );
      await store.toggleFavorite(anchor);
      final rows = List.generate(
        8500,
        (i) => Drama(
          id: 'hongguo:$i',
          source: 'hongguo',
          title: '合成剧集${i}第二季',
          description: '陈昊宇在异世觉醒，遭遇神明抛弃，凭借自己的力量寻找真相。' * 10,
        ),
      )..add(sequel);
      var ticks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      try {
        await store.refreshDramas(rows);
      } finally {
        heartbeat.cancel();
      }
      expect(
        ticks,
        greaterThan(2),
        reason: 'UI timers must run while the large merge is in progress',
      );
      expect(
        store.following(anchor.id)!.seriesSeasons.keys,
        contains(sequel.id),
      );
      final restored = LocalStore(preferences);
      addTearDown(restored.dispose);
      expect(
        restored.following(anchor.id)!.seriesSeasons.keys,
        contains(sequel.id),
      );
    },
  );
}
