import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fixtures.dart';
import 'local_persistence_test.dart' show FailingPreferences;

class ControlledPlaybackStore extends LocalStore {
  ControlledPlaybackStore(super.preferences);

  Completer<void>? pending;
  bool reject = false;
  final changes = <bool>[];

  @override
  Future<void> setWindowsVideoCompatibility(bool value) async {
    changes.add(value);
    await pending?.future;
    if (reject) throw StateError('synthetic save failure');
    await super.setWindowsVideoCompatibility(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const switchKey = ValueKey('windows-video-compatibility');

  Future<LocalStore> restart() async {
    SharedPreferences.resetStatic();
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    LocalStore store, {
    bool television = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: AppLayout(
        television: television,
        child: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    ),
  );

  test(
    'old and malformed compatibility fields preserve other playback choices',
    () {
      expect(const PlaybackPreferences().windowsVideoCompatibility, false);
      for (final field in [null, false, 'true', 1, [], {}]) {
        final preferences = PlaybackPreferences.fromJson({
          'speed': 1.5,
          'quality': 720,
          'danmaku': false,
          'windowsVideoCompatibility': ?field,
        });
        expect(preferences.windowsVideoCompatibility, false);
        expect(preferences.speed, 1.5);
        expect(preferences.quality, 720);
        expect(preferences.danmaku, false);
      }
      final enabled = PlaybackPreferences.fromJson({
        'windowsVideoCompatibility': true,
      });
      expect(enabled.windowsVideoCompatibility, true);
      expect(
        PlaybackPreferences.fromJson(
          enabled.copyWith(speed: 2).toJson(),
        ).windowsVideoCompatibility,
        true,
      );
    },
  );

  test(
    'legacy settings opt in explicitly and survive fresh preference instances',
    () async {
      SharedPreferences.setMockInitialValues({
        'playback': jsonEncode({
          'speed': 1.5,
          'quality': 720,
          'danmaku': false,
        }),
      });
      final original = await restart();
      expect(original.playbackPreferences.windowsVideoCompatibility, false);
      await original.setPlaybackPreferences(
        original.playbackPreferences.copyWith(windowsVideoCompatibility: true),
      );
      final restored = await restart();
      expect(restored.playbackPreferences.windowsVideoCompatibility, true);
      expect(restored.playbackPreferences.speed, 1.5);
      expect(restored.playbackPreferences.quality, 720);
      expect(restored.playbackPreferences.danmaku, false);
      await restored.setPlaybackPreferences(
        restored.playbackPreferences.copyWith(speed: 2, danmaku: true),
      );
      final unrelatedChange = await restart();
      expect(
        unrelatedChange.playbackPreferences.windowsVideoCompatibility,
        true,
      );
      expect(unrelatedChange.playbackPreferences.speed, 2);
      expect(unrelatedChange.playbackPreferences.danmaku, true);
      await unrelatedChange.setPlaybackPreferences(
        unrelatedChange.playbackPreferences.copyWith(
          windowsVideoCompatibility: false,
        ),
      );
      final disabled = await restart();
      expect(disabled.playbackPreferences.windowsVideoCompatibility, false);
      expect(disabled.playbackPreferences.speed, 2);
      expect(disabled.playbackPreferences.quality, 720);
    },
  );

  for (final compatibilityFirst in [true, false]) {
    test(
      'queued playback and compatibility changes merge both directions, compatibilityFirst=$compatibilityFirst',
      () async {
        for (final enabled in [true, false]) {
          SharedPreferences.setMockInitialValues({});
          final store = await restart();
          await store.setPlaybackPreferences(
            PlaybackPreferences(
              speed: 1.5,
              quality: 720,
              windowsVideoCompatibility: !enabled,
            ),
          );
          final stalePlayback = store.playbackPreferences.copyWith(
            speed: 2,
            danmaku: false,
          );
          Future<void> savePlayback() => store.setPlaybackPreferences(
            stalePlayback,
            preserveWindowsVideoCompatibility: true,
          );
          Future<void> saveCompatibility() =>
              store.setWindowsVideoCompatibility(enabled);
          await Future.wait([
            compatibilityFirst ? saveCompatibility() : savePlayback(),
            compatibilityFirst ? savePlayback() : saveCompatibility(),
          ]);
          final restored = await restart();
          expect(
            restored.playbackPreferences.windowsVideoCompatibility,
            enabled,
          );
          expect(restored.playbackPreferences.speed, 2);
          expect(restored.playbackPreferences.quality, 720);
          expect(restored.playbackPreferences.danmaku, false);
        }
      },
    );
  }

  test(
    'atomic preference saves retain old data on storage failure and recover',
    () async {
      SharedPreferences.resetStatic();
      final storage = FailingPreferences({});
      SharedPreferencesStorePlatform.instance = storage;
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720),
      );
      final stalePlayback = store.playbackPreferences.copyWith(speed: 2);
      storage.failure = 'false';
      await expectLater(
        store.setWindowsVideoCompatibility(true),
        throwsStateError,
      );
      expect(store.playbackPreferences.windowsVideoCompatibility, false);
      expect(store.playbackPreferences.speed, 1.5);
      storage.failure = '';
      await store.setWindowsVideoCompatibility(true);
      storage.failure = 'false';
      await expectLater(
        store.setPlaybackPreferences(
          stalePlayback,
          preserveWindowsVideoCompatibility: true,
        ),
        throwsStateError,
      );
      expect(store.playbackPreferences.windowsVideoCompatibility, true);
      expect(store.playbackPreferences.speed, 1.5);
      storage.failure = '';
      await store.setPlaybackPreferences(
        stalePlayback,
        preserveWindowsVideoCompatibility: true,
      );
      final restored = await restart();
      expect(restored.playbackPreferences.windowsVideoCompatibility, true);
      expect(restored.playbackPreferences.speed, 2);
      expect(restored.playbackPreferences.quality, 720);
    },
  );

  Map<String, Object> profilesFixture() => {
    'profiles': jsonEncode([
      const LocalProfile(
        id: 'default',
        name: '管理员',
        admin: true,
        salt: '00000000000000000000000000000000',
        pinHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ).toJson(),
      const LocalProfile(
        id: 'guest',
        name: '访客',
        sources: ['hongguo'],
      ).toJson(),
    ]),
    'forceLogin': false,
    'playback': jsonEncode({'speed': 1.5, 'windowsVideoCompatibility': true}),
    'profile.guest.playback': jsonEncode({'speed': .75}),
  };

  Map<String, dynamic> snapshotPlayback(SharedPreferences preferences) {
    final snapshot =
        jsonDecode(preferences.getString(LocalSnapshot.storageKey)!) as Map;
    return jsonDecode((snapshot['values'] as Map)['playback'] as String)
        as Map<String, dynamic>;
  }

  for (final compatibilityOnly in [true, false]) {
    test(
      'queued playback changes cannot cross profile switch, compatibilityOnly=$compatibilityOnly',
      () async {
        SharedPreferences.setMockInitialValues(profilesFixture());
        final store = await restart();
        final oldPlayback = store.playbackPreferences;
        final switched = store.switchProfile('guest');
        final outdated = compatibilityOnly
            ? store.setWindowsVideoCompatibility(true)
            : store.setPlaybackPreferences(
                oldPlayback.copyWith(speed: 2),
                preserveWindowsVideoCompatibility: true,
              );
        final rejected = expectLater(outdated, throwsStateError);
        await switched;
        await rejected;
        expect(store.profile.id, 'guest');
        expect(store.playbackPreferences.windowsVideoCompatibility, false);
        expect(store.playbackPreferences.speed, .75);
        final original = snapshotPlayback(store.preferences);
        expect(original['windowsVideoCompatibility'], true);
        expect(original['speed'], 1.5);
      },
    );
  }

  test('locked profile rejects pending and subsequent mode changes', () async {
    SharedPreferences.setMockInitialValues(profilesFixture());
    final store = await restart();
    final pending = store.setWindowsVideoCompatibility(false);
    store.lock();
    await expectLater(pending, throwsStateError);
    await expectLater(
      store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 2),
        preserveWindowsVideoCompatibility: true,
      ),
      throwsStateError,
    );
    expect(store.locked, true);
    expect(store.preferences.getString(LocalSnapshot.storageKey), isNull);
    expect(
      jsonDecode(
        store.preferences.getString('playback')!,
      )['windowsVideoCompatibility'],
      true,
    );
  });

  testWidgets(
    'Windows settings save the mode and restore its displayed choice',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await restart();
      await mount(tester, store);
      final toggle = find.byKey(switchKey);
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      expect(find.text('视频兼容模式'), findsOneWidget);
      expect(find.textContaining('重新打开播放页后生效'), findsOneWidget);
      expect(find.textContaining('硬件 VSR 增强'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.windowsVideoCompatibility, true);
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      await tester.pumpWidget(const SizedBox.shrink());
      final restored = await restart();
      await mount(tester, restored);
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(restored.playbackPreferences.windowsVideoCompatibility, false);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'compatibility setting is absent outside the Windows desktop interface',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await restart();
      for (final television in [false, true]) {
        await mount(tester, store, television: television);
        final expected =
            defaultTargetPlatform == TargetPlatform.windows && !television;
        expect(find.byKey(switchKey), expected ? findsOneWidget : findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'an open global danmaku menu preserves a concurrently saved compatibility choice',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await restart();
      await mount(tester, store);
      await tester.tap(find.byKey(const ValueKey('global-danmaku-settings')));
      await tester.pumpAndSettle();
      final danmaku = find.byKey(const ValueKey('player-danmaku-enabled'));
      final toggle = tester.widget<SwitchListTile>(danmaku).onChanged!;
      final compatibility = store.setWindowsVideoCompatibility(true);
      toggle(false);
      await compatibility;
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.windowsVideoCompatibility, true);
      expect(store.playbackPreferences.danmaku, false);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('a pending save rejects repeated toggle requests', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ControlledPlaybackStore(
      await SharedPreferences.getInstance(),
    );
    addTearDown(store.dispose);
    final pending = Completer<void>();
    store.pending = pending;
    await mount(tester, store);
    final toggle = find.byKey(switchKey);
    final onChanged = tester.widget<SwitchListTile>(toggle).onChanged!;
    onChanged(true);
    onChanged(false);
    await tester.pump();
    expect(store.changes, hasLength(1));
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(store.playbackPreferences.windowsVideoCompatibility, false);
    pending.complete();
    await tester.pumpAndSettle();
    expect(store.playbackPreferences.windowsVideoCompatibility, true);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'failed saves retain the old mode and use the normal error feedback',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = ControlledPlaybackStore(
        await SharedPreferences.getInstance(),
      )..reject = true;
      addTearDown(store.dispose);
      await mount(tester, store);
      final toggle = find.byKey(switchKey);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.windowsVideoCompatibility, false);
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      expect(find.text('操作未完成，原记录已保留。请查看日记中的具体原因。'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
