import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old and invalid offsets default safely, copy preserves position', () {
    for (final value in [null, 'bad', double.nan, double.infinity]) {
      final preferences = PlaybackPreferences.fromJson({
        'portraitVideoOffset': value,
      });
      expect(preferences.portraitVideoOffset, -.15);
    }
    final preferences = PlaybackPreferences.fromJson({
      'portraitVideoOffset': .2,
    });
    expect(
      PlaybackPreferences.fromJson(
        preferences.copyWith(speed: 1.5).toJson(),
      ).portraitVideoOffset,
      .2,
    );
    expect(
      PlaybackPreferences.fromJson({
        'portraitVideoOffset': 9,
      }).portraitVideoOffset,
      .5,
    );
  });

  testWidgets(
    'vertical slider saves and survives restart without changing other preferences',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AppLayout(
            television: false,
            deviceTelevision: false,
            child: SettingsScreen(
              repository: FixtureRepository(),
              store: store,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('portrait-video-position-setting')),
      );
      await tester.pumpAndSettle();
      expect(find.text('上移 15%'), findsOneWidget);
      final slider = find.byKey(const ValueKey('portrait-video-offset-slider'));
      await tester.drag(slider, const Offset(0, 40));
      await tester.pumpAndSettle();
      final selected = tester.widget<Slider>(slider).value;
      expect(selected, greaterThan(-.15));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      SharedPreferences.resetStatic();
      final restored = LocalStore(await SharedPreferences.getInstance());
      addTearDown(restored.dispose);
      expect(restored.playbackPreferences.portraitVideoOffset, selected);
      expect(restored.playbackPreferences.speed, 1.5);
      expect(restored.playbackPreferences.quality, 720);
      await tester.tap(
        find.byKey(const ValueKey('portrait-video-position-setting')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认（上移 15%）'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.portraitVideoOffset, selected);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('Windows and TV do not expose the phone position setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        MaterialApp(
          home: AppLayout(
            television: platform == TargetPlatform.android,
            deviceTelevision: platform == TargetPlatform.android,
            child: SettingsScreen(
              repository: FixtureRepository(),
              store: store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('portrait-video-position-setting')),
        findsNothing,
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
