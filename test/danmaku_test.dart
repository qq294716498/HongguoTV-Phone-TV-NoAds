import 'dart:convert';

import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'danmaku_fixtures.dart';
import 'local_persistence_test.dart' show FailingPreferences;

const danmakuPlan = PlaybackPlan(
  url: 'https://media.example.test/synthetic.mp4',
  session: 'current',
  danmakuId: '1001',
);

void updateDanmaku(
  DanmakuController controller, {
  int position = 0,
  int duration = 180000,
  bool playing = true,
  bool buffering = false,
  bool foreground = true,
  double speed = 1,
}) {
  controller.update(
    position: Duration(milliseconds: position),
    duration: Duration(milliseconds: duration),
    speed: speed,
    playing: playing,
    buffering: buffering,
    foreground: foreground,
    available: true,
  );
}

Future<void> flushDanmaku() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nearby duplicates merge by displayed content and unique identity', () {
    final merged = mergeDanmaku(const [
      DanmakuItem(id: 'a', text: '好看 [偷笑]', timeMs: 1000),
      DanmakuItem(id: 'a', text: '好看 [偷笑]', timeMs: 1000),
      DanmakuItem(id: 'b', text: ' 好看  🤭 ', timeMs: 2500),
      DanmakuItem(id: 'c', text: '好看 [捂嘴笑]', timeMs: 4000),
      DanmakuItem(id: 'd', text: '好看 🤭', timeMs: 4001),
      DanmakuItem(id: 'e', text: '别的内容', timeMs: 1000),
    ]);
    expect(merged.map((item) => item.id), ['a', 'e', 'd']);
    expect(merged.map((item) => item.repeatCount), [3, 1, 1]);
    expect(danmakuFlightText(merged.first), '好看 [偷笑]  ♥ 3');
    expect(danmakuFlightText(merged.last), '好看 🤭');
  });

  test(
    'adjacent pages merge across cursors and reset for the next episode',
    () async {
      final repository = DanmakuFixtureRepository()
        ..response = (request) => DanmakuPage(
          episodeId: request.plan.danmakuId,
          startMs: request.startMs,
          nextMs: request.startMs + 30000,
          items: [
            DanmakuItem(
              id: '${request.startMs}',
              text: '合成重复弹幕',
              timeMs: request.startMs == 0 ? 29500 : 30500,
            ),
          ],
        );
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller, position: 22000);
      await flushDanmaku();
      expect(controller.items.single.repeatCount, 2);
      expect(controller.items.single.timeMs, 29500);
      updateDanmaku(controller, position: 22500);
      await flushDanmaku();
      expect(controller.items.single.repeatCount, 2);
      controller.setPlan(
        const PlaybackPlan(
          url: 'https://media.example.test/second.mp4',
          session: 'next',
          danmakuId: '1002',
        ),
      );
      expect(controller.items, isEmpty);
      updateDanmaku(controller);
      await flushDanmaku();
      expect(controller.items.single.repeatCount, 1);
    },
  );

  test(
    'danmaku keeps zero timestamps and text while rejecting unverified items and windows',
    () {
      final json = <String, dynamic>{
        'episodeId': '1001',
        'startMs': 0,
        'nextMs': 30000,
        'items': [
          {'id': 'literal', 'text': '<b>文字</b>\n第二行', 'timeMs': 0},
          {'id': 'later', 'text': '下一条', 'timeMs': 15000},
          {'id': 'literal', 'text': '重复', 'timeMs': 1},
          {'id': 'fraction', 'text': '无效', 'timeMs': 1.2},
          {'id': 'missing', 'text': '普通评论'},
          {'id': 'outside', 'text': '越界', 'timeMs': 30000},
        ],
      };
      DanmakuPage parse(Map<String, dynamic> value) => DanmakuPage.fromJson(
        value,
        episodeId: '1001',
        startMs: 0,
        durationMs: 60000,
      );
      final page = parse(json);
      expect(page.items.map((item) => item.timeMs), [0, 15000]);
      expect(page.items.first.text, '<b>文字</b> 第二行');
      for (final invalid in [
        {...json, 'episodeId': 'other'},
        {...json, 'startMs': 1},
        {...json, 'nextMs': 0},
        {...json, 'nextMs': 60001},
        {...json, 'nextMs': 30000.0},
        {...json, 'items': null},
      ]) {
        expect(() => parse(invalid), throwsFormatException);
      }
      expect(parse({...json, 'items': []}).items, isEmpty);
    },
  );

  test(
    'windows load independently, use source cursors, and keep one optional request active',
    () async {
      final repository = DanmakuFixtureRepository()..holdDanmaku = true;
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      updateDanmaku(controller, position: 1000);
      expect(repository.danmakuCalls.length, 1);
      final first = repository.danmakuCalls.first;
      first.result.complete(
        DanmakuPage(
          episodeId: '1001',
          startMs: 0,
          nextMs: 12000,
          items: const [],
        ),
      );
      await flushDanmaku();
      updateDanmaku(controller, position: 5000);
      expect(repository.danmakuCalls.last.startMs, 12000);
      updateDanmaku(controller, position: 5100);
      expect(repository.danmakuCalls.length, 2);
      repository.danmakuCalls.last.result.complete(
        DanmakuFixtureRepository.page(repository.danmakuCalls.last),
      );
      await flushDanmaku();
      expect(repository.primaryCalls, 0);
      expect(repository.fallbackCalls, 0);
      expect(repository.active, isEmpty);
    },
  );

  test(
    'short upstream windows catch up to a seek without repeating the same request',
    () async {
      final repository = DanmakuFixtureRepository()
        ..response = (request) => DanmakuPage(
          episodeId: request.plan.danmakuId,
          startMs: request.startMs,
          nextMs: request.startMs + 1000,
          items: const [],
        );
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller, position: 20000, playing: false);
      await flushDanmaku();
      expect(repository.danmakuCalls.map((call) => call.startMs), [0, 20000]);
      expect(controller.loading, isFalse);
    },
  );

  test(
    'episode changes, disabling and disposal reject late optional responses',
    () async {
      final repository = DanmakuFixtureRepository()..holdDanmaku = true;
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      updateDanmaku(controller);
      final first = repository.danmakuCalls.single;
      controller.setPlan(
        const PlaybackPlan(
          url: 'https://media.example.test/second.mp4',
          session: 'next',
          danmakuId: '1002',
        ),
      );
      updateDanmaku(controller);
      final second = repository.danmakuCalls.last;
      first.result.complete(DanmakuFixtureRepository.page(first));
      await flushDanmaku();
      expect(controller.items, isEmpty);
      expect(repository.danmakuCancellations, 1);
      controller.setEnabled(false);
      second.result.complete(DanmakuFixtureRepository.page(second));
      await flushDanmaku();
      expect(controller.items, isEmpty);
      expect(controller.visible, isFalse);
      controller.setEnabled(true);
      final third = repository.danmakuCalls.last;
      controller.dispose();
      third.result.completeError(StateError('late failure'));
      await flushDanmaku();
      expect(repository.danmakuCancellations, 3);
      expect(repository.primaryCalls, 0);
    },
  );

  test(
    'local media without source identity and unsupported sessions skip danmaku',
    () async {
      final repository = DanmakuFixtureRepository();
      final controller = DanmakuController(repository);
      addTearDown(controller.dispose);
      for (final plan in [
        const PlaybackPlan(
          url: 'file:///synthetic.mp4',
          local: true,
          session: 'local',
        ),
        const PlaybackPlan(
          url: 'https://media.example.test/other.mp4',
          session: 'other',
        ),
      ]) {
        controller.setPlan(plan);
        updateDanmaku(controller);
        expect(controller.visible, isFalse);
      }
      await flushDanmaku();
      expect(repository.danmakuCalls, isEmpty);
    },
  );

  test(
    'pausing and buffering stop motion and background cancels optional loading',
    () async {
      final repository = DanmakuFixtureRepository()..holdDanmaku = true;
      final controller = DanmakuController(repository)..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller, buffering: true);
      expect(repository.danmakuCalls, isEmpty);
      expect(controller.moving, isFalse);
      updateDanmaku(controller, playing: false);
      expect(repository.danmakuCalls.length, 1);
      expect(controller.moving, isFalse);
      updateDanmaku(controller, foreground: false);
      expect(repository.danmakuCancellations, 1);
      expect(controller.visible, isFalse);
      final old = repository.danmakuCalls.single;
      old.result.complete(DanmakuFixtureRepository.page(old));
      await flushDanmaku();
      expect(controller.items, isEmpty);
      updateDanmaku(controller);
      expect(repository.danmakuCalls.length, 2);
      controller.beginSeek();
      expect(controller.visible, isFalse);
      final stale = repository.danmakuCalls.last;
      stale.result.complete(DanmakuFixtureRepository.page(stale));
      await flushDanmaku();
      controller.endSeek(const Duration(seconds: 65));
      expect(repository.danmakuCalls.last.startMs, 60000);
    },
  );

  test(
    'failed optional windows back off and retry without resolving media',
    () async {
      var now = DateTime(2026);
      final repository = DanmakuFixtureRepository()..failDanmaku = true;
      final controller = DanmakuController(repository, now: () => now)
        ..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      expect(controller.canRetry, isTrue);
      for (var i = 0; i < 10; i++) {
        updateDanmaku(controller, position: i * 100);
      }
      expect(repository.danmakuCalls.length, 1);
      now = now.add(const Duration(seconds: 16));
      repository.failDanmaku = false;
      updateDanmaku(controller, position: 1000);
      await flushDanmaku();
      expect(repository.danmakuCalls.length, 2);
      expect(controller.canRetry, isFalse);
      expect(controller.items.length, 1);
      expect(repository.primaryCalls + repository.fallbackCalls, 0);
    },
  );

  test(
    'ordinary media samples keep animation anchors while seeks and speed changes resync',
    () async {
      var now = DateTime(2026);
      final controller = DanmakuController(
        DanmakuFixtureRepository(),
        now: () => now,
      )..setPlan(danmakuPlan);
      addTearDown(controller.dispose);
      updateDanmaku(controller);
      await flushDanmaku();
      final initial = controller.motionRevision;
      for (var i = 1; i <= 4; i++) {
        now = now.add(const Duration(milliseconds: 250));
        updateDanmaku(controller, position: i * 250);
      }
      expect(controller.motionRevision, initial);
      updateDanmaku(controller, position: 1000, speed: 3);
      expect(controller.motionRevision, initial + 1);
      now = now.add(const Duration(milliseconds: 500));
      updateDanmaku(controller, position: 2500, speed: 3);
      expect(controller.motionRevision, initial + 1);
      controller.beginSeek();
      controller.endSeek(const Duration(milliseconds: 3000));
      expect(controller.motionRevision, initial + 3);
      updateDanmaku(controller, position: 3000, playing: false, speed: 3);
      expect(controller.moving, isFalse);
    },
  );

  test('long playback retains only nearby bounded windows', () async {
    final repository = DanmakuFixtureRepository();
    final controller = DanmakuController(repository)..setPlan(danmakuPlan);
    addTearDown(controller.dispose);
    for (var page = 0; page < 25; page++) {
      updateDanmaku(
        controller,
        position: page * 30000,
        duration: 1800000,
        playing: false,
      );
      await flushDanmaku();
      expect(controller.items.length, lessThanOrEqualTo(6));
    }
    expect(controller.items.first.timeMs, greaterThan(0));
    expect(repository.danmakuCalls.length, 25);
  });

  test(
    'lane scheduling bounds density and avoids collisions between different text widths',
    () {
      final items = [
        for (var i = 0; i < 120; i++)
          DanmakuItem(
            id: '$i',
            text: i.isEven ? '短' : '较长的合成文字',
            timeMs: i * 180,
          ),
      ];
      for (final (rows, lifetime) in [(4, danmakuLifetimeMs), (2, 32000)]) {
        final flights = planDanmaku(
          items,
          width: 500,
          rows: rows,
          lifetimeMs: lifetime,
          measure: (text) => text.length * 18,
        );
        expect(flights.length, lessThan(items.length));
        for (var position = 0; position < 40000; position += 100) {
          final active = flights
              .where(
                (flight) =>
                    position >= flight.item.timeMs &&
                    position < flight.item.timeMs + lifetime,
              )
              .toList();
          expect(active.length, lessThanOrEqualTo(24));
          for (var a = 0; a < active.length; a++) {
            for (var b = a + 1; b < active.length; b++) {
              if (active[a].lane != active[b].lane) continue;
              double x(int index) =>
                  500 -
                  (500 + active[index].width) *
                      (position - active[index].item.timeMs) /
                      lifetime;
              expect(x(a) + active[a].width, lessThanOrEqualTo(x(b) + .001));
            }
          }
        }
      }
    },
  );

  test(
    'danmaku preference survives restart, backup, old backups and user switching',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'synthetic-pin',
      );
      await store.setPlaybackPreferences(
        const PlaybackPreferences(danmaku: false),
      );
      final backup = await store.exportBackup();
      await store.saveProfile(
        name: '访客',
        sources: ['hongguo'],
        download: false,
      );
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(visitor.id);
      expect(store.playbackPreferences.danmaku, isTrue);
      await store.switchProfile('default', pin: 'synthetic-pin');
      expect(store.playbackPreferences.danmaku, isFalse);
      final restarted = LocalStore(await SharedPreferences.getInstance());
      addTearDown(restarted.dispose);
      await restarted.switchProfile('default', pin: 'synthetic-pin');
      expect(restarted.playbackPreferences.danmaku, isFalse);
      await store.importBackup(backup);
      expect(store.locked, isTrue);
      await store.switchProfile('default', pin: 'synthetic-pin');
      expect(store.playbackPreferences.danmaku, isFalse);
      final legacy = jsonDecode(backup) as Map<String, dynamic>;
      (((legacy['libraries'] as Map)['default'] as Map)['playback'] as Map)
          .remove('danmaku');
      await store.importBackup(jsonEncode(legacy));
      expect(store.locked, isTrue);
      await store.switchProfile('default', pin: 'synthetic-pin');
      expect(store.playbackPreferences.danmaku, isTrue);
    },
  );

  test('a failed preference save keeps the previous danmaku switch', () async {
    SharedPreferences.resetStatic();
    final platform = FailingPreferences({});
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setPlaybackPreferences(
      const PlaybackPreferences(danmaku: false),
    );
    platform.failure = 'false';
    await expectLater(
      store.setPlaybackPreferences(const PlaybackPreferences(danmaku: true)),
      throwsStateError,
    );
    expect(store.playbackPreferences.danmaku, isFalse);
  });
}
