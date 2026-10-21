import 'dart:convert';

import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/watch_reminder_models.dart';
import 'package:duanju_app/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences(super.data) : super.withData();
  String failure = '';
  int snapshots = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith(LocalSnapshot.storageKey)) {
      snapshots++;
      if (failure == 'false') return false;
      if (failure == 'throw') throw StateError('synthetic write failure');
      if (failure == 'after') {
        failure = '';
        await super.setValue(valueType, key, value);
        throw StateError('synthetic acknowledgement failure');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '旧资料');
  const next = Drama(id: 'hongguo:2', source: 'hongguo', title: '新资料');

  Future<(LocalStore, FailingPreferences)> create([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.resetStatic();
    final platform = FailingPreferences({
      for (final entry in initial.entries) 'flutter.${entry.key}': entry.value,
    });
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return (store, platform);
  }

  Future<LocalStore> restart(FailingPreferences platform) async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test(
    'danmaku speed migrates safely and survives restart and backup',
    () async {
      final old = PlaybackPreferences.fromJson({'speed': 1.5});
      expect(old.effectiveDanmakuSpeed(mobile: true), 1.15);
      expect(old.effectiveDanmakuSpeed(mobile: false), 1);
      for (final invalid in [
        null,
        'fast',
        -1,
        0,
        9,
        double.nan,
        double.infinity,
      ]) {
        final parsed = PlaybackPreferences.fromJson({
          'speed': 1.5,
          'danmakuSpeed': invalid,
        });
        expect(parsed.speed, 1.5);
        expect(parsed.danmakuSpeed, isNull);
      }
      final (store, platform) = await create();
      for (final speed in danmakuSpeeds) {
        await store.setPlaybackPreferences(old.copyWith(danmakuSpeed: speed));
        final restored = await restart(platform);
        expect(restored.playbackPreferences.danmakuSpeed, speed);
        expect(restored.playbackPreferences.speed, 1.5);
        final backup = await restored.exportBackup();
        await restored.setPlaybackPreferences(const PlaybackPreferences());
        await restored.importBackup(backup);
        expect(restored.playbackPreferences.danmakuSpeed, speed);
      }
    },
  );

  test(
    'opacity and reminder settings survive restart and backup without changing video speed',
    () async {
      final (store, platform) = await create();
      final value = const PlaybackPreferences(
        speed: 1.5,
        danmakuSpeed: 1.25,
        danmakuOpacity: .35,
        reminders: WatchReminderPreferences(
          dailyEnabled: true,
          dailyLimitMinutes: 90,
          dailyRepeatMinutes: 3,
          bedtimeEnabled: true,
          bedtimeMinute: 1380,
          bedtimeRepeatMinutes: 7,
        ),
      );
      await store.setPlaybackPreferences(value);
      await store.saveWatchReminderProgress(
        'default',
        jsonEncode(
          WatchReminderProgress(
            day: '2026-10-14',
            watchedMs: 3600000,
            bedtimeLatched: true,
          ).toJson(),
        ),
      );
      final restored = await restart(platform);
      expect(restored.playbackPreferences.toJson(), value.toJson());
      expect(restored.watchReminderProgress.watchedMs, 3600000);
      final backup = await restored.exportBackup();
      await restored.setPlaybackPreferences(const PlaybackPreferences());
      await restored.importBackup(backup);
      expect(restored.playbackPreferences.toJson(), value.toJson());
      expect(restored.watchReminderProgress.bedtimeLatched, true);
      expect(
        PlaybackPreferences.fromJson({
          'danmakuOpacity': 'broken',
        }).danmakuOpacity,
        isNull,
      );
      expect(
        const PlaybackPreferences().effectiveDanmakuOpacity(mobile: true),
        .95,
      );
      expect(
        const PlaybackPreferences().effectiveDanmakuOpacity(
          mobile: false,
          television: true,
        ),
        .55,
      );
    },
  );

  for (final failure in ['false', 'throw', 'after']) {
    test(
      'failed $failure writes keep favorites, preferences and progress after restart',
      () async {
        final (store, platform) = await create({
          'plugin_secret': 'outside-the-backup',
        });
        await store.toggleFavorite(drama);
        await store.saveWatch(
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 15,
            duration: 100,
            updatedAt: DateTime.now(),
          ),
        );
        for (final change in <Future<void> Function()>[
          () => store.toggleFavorite(next),
          () => store.clearHistory(),
          () => store.setThemeMode('light'),
          () => store.setPlaybackPreferences(
            const PlaybackPreferences(
              speed: 2,
              quality: 720,
              autoAdvance: false,
            ),
          ),
        ]) {
          platform.failure = failure;
          await expectLater(change(), throwsStateError);
          expect(store.favorites.map((entry) => entry.id), [drama.id]);
          expect(store.watched(drama.id)?.position, 15);
          expect(store.themeMode, 'system');
          expect(store.playbackPreferences.speed, 1);
          final restored = await restart(platform);
          expect(restored.favorites.single.id, drama.id);
          expect(restored.watched(drama.id)?.position, 15);
          expect(restored.themeMode, 'system');
          expect(
            restored.preferences.getString('plugin_secret'),
            'outside-the-backup',
          );
        }
        platform.failure = '';
        await store.toggleFavorite(next);
        expect((await restart(platform)).favorites.length, 2);
      },
    );
  }

  test(
    'backup restoration is one snapshot and never mixes old and new data',
    () async {
      final (store, platform) = await create({'plugin_secret': 'preserved'});
      await store.toggleFavorite(drama);
      await store.saveWatch(
        WatchEntry(
          drama: drama,
          episode: 1,
          position: 10,
          duration: 100,
          updatedAt: DateTime.now(),
        ),
      );
      final old = await store.exportBackup();
      final backup = jsonDecode(old) as Map<String, dynamic>;
      backup['themeMode'] = 'light';
      final library = (backup['libraries'] as Map)['default'] as Map;
      library.remove('followSync');
      library['favorites'] = [next.toJson()];
      library['followStates'] = {};
      library['history'] = [
        WatchEntry(
          drama: next,
          episode: 2,
          position: 30,
          duration: 100,
          updatedAt: DateTime.now(),
        ).toJson(),
      ];
      library['playback'] = const PlaybackPreferences(
        speed: 1.5,
        quality: 1080,
        autoAdvance: false,
      ).toJson();
      final content = jsonEncode(backup);
      for (final failure in ['false', 'throw', 'after']) {
        platform.failure = failure;
        await expectLater(
          store.importBackup(content),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(await store.exportBackup(), old);
        expect(await (await restart(platform)).exportBackup(), old);
      }
      platform.failure = '';
      final before = platform.snapshots;
      await store.importBackup(content);
      expect(platform.snapshots - before, 1);
      final restored = await restart(platform);
      expect(restored.favorites.single.id, next.id);
      expect(restored.history.single.episode, 2);
      expect(restored.themeMode, 'light');
      expect(restored.playbackPreferences.toJson(), library['playback']);
      expect(restored.preferences.getString('plugin_secret'), 'preserved');
      final compatible = jsonDecode(content) as Map<String, dynamic>;
      ((compatible['libraries'] as Map)['default'] as Map).remove('playback');
      await store.importBackup(jsonEncode(compatible));
      expect(
        store.playbackPreferences.toJson(),
        const PlaybackPreferences().toJson(),
      );
    },
  );

  test(
    'queued mutations preserve all successful records and isolate playback preferences',
    () async {
      final (store, platform) = await create();
      await Future.wait([
        store.toggleFavorite(drama),
        store.toggleFavorite(next),
      ]);
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720, autoAdvance: false),
      );
      await store.saveProfile(
        name: '访客',
        sources: ['hongguo'],
        download: false,
      );
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(visitor.id);
      expect(store.playbackPreferences.speed, 1);
      await store.setPlaybackPreferences(const PlaybackPreferences(speed: .75));
      await store.switchProfile('default', pin: 'abcdef12');
      expect(store.playbackPreferences.speed, 1.5);
      final restored = await restart(platform);
      expect(restored.locked, isTrue);
      await restored.switchProfile('default', pin: 'abcdef12');
      expect(restored.favorites.length, 2);
      expect(restored.playbackPreferences.autoAdvance, isFalse);
    },
  );

  for (final records in <Object>[
    'broken-json',
    '[]',
    jsonEncode([
      const LocalProfile(
        id: 'default',
        name: '管理员',
        admin: true,
        salt: '11111111111111111111111111111111',
        pinHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ).toJson(),
      {'id': 'visitor', 'name': 7},
    ]),
    jsonEncode([
      {
        'id': 'default',
        'name': '管理员',
        'admin': true,
        'sources': [],
        'salt': 'bad',
      },
    ]),
  ]) {
    test(
      'damaged profiles remain locked without replacing raw data: $records',
      () async {
        final (store, platform) = await create({
          'profiles': records,
          'favorites': jsonEncode([drama.toJson()]),
        });
        expect(store.configurationError, isNotNull);
        expect(store.locked, isTrue);
        expect(store.profile.admin, isFalse);
        expect(store.canDownload, isFalse);
        expect(store.favorites, isEmpty);
        expect(store.sources, isEmpty);
        await expectLater(store.switchProfile('default'), throwsStateError);
        expect(platform.snapshots, 0);
        final restored = await restart(platform);
        expect(restored.configurationError, isNotNull);
        expect(restored.preferences.get('profiles'), records);
        expect(store.exportRecoveryData(), contains('旧资料'));
      },
    );
  }

  testWidgets(
    'damaged profile screen offers recovery without an unlocked administrator',
    (tester) async {
      final (store, _) = await create({'profiles': 'bad'});
      await tester.pumpWidget(
        MaterialApp(home: ProfilesScreen(store: store, locked: true)),
      );
      expect(find.text('从备份恢复'), findsOneWidget);
      expect(find.text('重新读取配置'), findsOneWidget);
      expect(find.text('导出原始配置'), findsOneWidget);
      expect(find.text('添加用户'), findsNothing);
      expect(find.text('管理员 · 全部权限'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
