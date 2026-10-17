import 'dart:convert';

import 'package:duanju_app/lan_sync_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = Drama(
    id: 'hongguo:migrate-s1',
    source: 'hongguo',
    title: '迁移合成 第一季',
    episodes: 10,
  );
  const third = Drama(
    id: 'hongguo:migrate-s3',
    source: 'hongguo',
    title: '迁移合成 第三季',
    episodes: 12,
  );
  WatchEntry watch(Drama drama, int minute) => WatchEntry(
    drama: drama,
    episode: 3,
    position: 24,
    duration: 120,
    updatedAt: DateTime.utc(2026, 10, 17, 12, minute),
  );
  Map<String, dynamic> legacy({bool conflict = false}) {
    final doc = LanDocument(replica: '1' * 32);
    doc.reconcile(
      previous: {},
      favorites: {first.id: first},
      states: {},
      history: {first.id: watch(first, 1)},
      oldHistory: {},
    );
    final json = doc.toJson()..['schema'] = 1;
    for (final row in json['records'] as List) {
      for (final cell in row['progress'] as List) {
        (cell['value'] as Map).remove('drama');
        (cell['value'] as Map).remove('cleared');
      }
      if (conflict) {
        (row['progress'] as List).add({
          'v': {'2' * 32: 1},
          'value': {
            'episode': 2,
            'position': 11,
            'duration': 120,
            'updatedAt': DateTime.utc(2026, 10, 17, 12, 2).toIso8601String(),
          },
        });
      }
    }
    return json;
  }

  for (final conflict in [false, true]) {
    test(
      'legacy cached document migrates without losing ${conflict ? 'unresolved choices' : 'the latest actual season'}',
      () async {
        final old = legacy(conflict: conflict);
        SharedPreferences.setMockInitialValues({
          'favorites': jsonEncode([first.toJson()]),
          'history': jsonEncode([
            watch(first, 1).toJson(),
            watch(third, 3).toJson(),
          ]),
          'lanRecords': jsonEncode(old),
        });
        final store = testStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        final doc = store.lanDocument;
        final record = doc.records[first.id]!;
        expect(doc.toJson()['schema'], 2);
        expect(store.history, hasLength(2));
        if (conflict) {
          expect(record.progress.conflict, true);
          expect(
            record.progress.toJson(),
            (old['records'] as List).single['progress'],
          );
          expect(store.seriesWatch(first)!.drama.id, third.id);
        } else {
          expect(record.watch!.drama.id, third.id);
          expect(
            record.progress.version.includes(
              LanDocument.fromJson(old).records[first.id]!.progress.version,
            ),
            true,
          );
          expect(doc.counter, greaterThan(old['counter'] as int));
        }
        await store.ensureLanRecords();
        final restarted = LocalStore(store.preferences);
        addTearDown(restarted.dispose);
        expect(
          restarted.lanDocument.hashFor({'hongguo'}),
          doc.hashFor({'hongguo'}),
        );
      },
    );
  }

  test(
    'legacy progress restored inside a v2 document is still migrated',
    () async {
      final old = legacy()..['schema'] = 2;
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([first.toJson()]),
        'history': jsonEncode([watch(third, 3).toJson()]),
        'lanRecords': jsonEncode(old),
      });
      final store = testStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      expect(store.lanDocument.records[first.id]!.watch!.drama.id, third.id);
    },
  );

  test(
    'progress validates target identity and keeps legacy four-field values readable',
    () {
      final old = LanDocument.fromJson(legacy()).records[first.id]!;
      expect(old.watch!.drama.id, first.id);
      final good = old.toJson();
      good['progress'] = [
        LanValue(old.progress.version, lanProgress(watch(third, 3))).toJson(),
      ];
      expect(LanRecord.fromJson(good).watch!.drama.id, third.id);
      for (final target in [
        const Drama(
          id: 'huangdou:migrate-s3',
          source: 'huangdou',
          title: '迁移合成 第三季',
        ),
        const Drama(
          id: 'hongguo:unrelated-s3',
          source: 'hongguo',
          title: '另一合成 第三季',
        ),
        const Drama(id: 'hongguo:part', source: 'hongguo', title: '迁移合成 第三部'),
      ]) {
        final wrong = Map<String, dynamic>.of(good);
        wrong['progress'] = [
          LanValue(
            old.progress.version,
            lanProgress(watch(target, 3)),
          ).toJson(),
        ];
        expect(() => LanRecord.fromJson(wrong), throwsFormatException);
      }
      expect(
        () => old.progress.merge(
          LanCell([
            LanValue(old.progress.version, lanProgress(watch(third, 3))),
          ]),
        ),
        throwsFormatException,
      );
    },
  );
}
