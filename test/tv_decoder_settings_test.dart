import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:duanju_app/tv_decoder_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  testWidgets(
    'global decoder settings include physical TV in standard layout and persist',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      addTearDown(store.dispose);
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, danmaku: false),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AppLayout(
            television: false,
            deviceTelevision: true,
            child: SettingsScreen(
              repository: FixtureRepository(),
              store: store,
            ),
          ),
        ),
      );
      final entry = find.byKey(const ValueKey('global-tv-decoder-settings'));
      if (defaultTargetPlatform != TargetPlatform.android) {
        expect(entry, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tv-decoder-software')));
      await tester.pumpAndSettle();
      expect(store.playbackPreferences.tvDecoderMode, TvDecoderMode.software);
      expect(store.playbackPreferences.speed, 1.5);
      expect(store.playbackPreferences.danmaku, false);
      final restored = LocalStore(preferences);
      addTearDown(restored.dispose);
      expect(
        restored.playbackPreferences.tvDecoderMode,
        TvDecoderMode.software,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
