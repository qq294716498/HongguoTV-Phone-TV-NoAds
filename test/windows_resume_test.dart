import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  testWidgets(
    'restart resumes exact episode paused and persists application volume',
    (tester) async {
      mockPlayerDevice();
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'windows_volume': 0.0,
        'windows_last_volume': 55.0,
      });
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      final repository = RouteRepository();
      final platform = ScriptedPlayer();
      final detail = await repository.detail(FixtureRepository.free);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            detail: detail,
            initialIndex: 1,
            initialPosition: 43.5,
            initiallyPlaying: false,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: platform),
            videoBuilder: (controls) =>
                ColoredBox(color: Colors.black, child: controls),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(platform.played, [false]);
      expect(platform.state.playing, isFalse);
      expect(platform.state.position.inMilliseconds, 43500);
      expect(platform.state.volume, 0);
      final controls = tester.widget<PlayerControls>(
        find.byType(PlayerControls),
      );
      controls.interactions.toggleMute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(platform.state.volume, 55);
      expect(preferences.getDouble('windows_volume'), 55);
      controls.interactions.setVolume(22);
      await tester.pump(const Duration(milliseconds: 300));
      expect(preferences.getDouble('windows_volume'), 22);
      expect(preferences.getDouble('windows_last_volume'), 22);
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await store.flushPendingWrites();
      expect(store.watched(detail.drama.id)?.episode, 2);
      expect(store.watched(detail.drama.id)?.position, 43.5);
      expect(tester.takeException(), isNull);
      store.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
