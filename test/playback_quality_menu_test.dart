import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mobile in [true, false]) {
    testWidgets(
      'all four quality preferences remain selectable mobile=$mobile',
      (tester) async {
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerMenu(
                section: PlayerMenuSection.quality,
                episodes: const [],
                currentIndex: 0,
                preferences: const PlaybackPreferences(),
                qualities: const [1080, 720],
                actualQuality: 1080,
                local: false,
                favorite: false,
                mobile: mobile,
                onEpisode: (_) {},
                onFavorite: () async {},
                onPreferences: (value) async => selected.add(value.quality),
              ),
            ),
          ),
        );
        for (final quality in [360, 480, 720, 1080]) {
          final option = find.byKey(ValueKey('menu-quality-$quality'));
          expect(option, findsOneWidget);
          await tester.ensureVisible(option);
          await tester.tap(option);
          await tester.pumpAndSettle();
        }
        expect(selected, [360, 480, 720, 1080]);
      },
    );
  }
}
