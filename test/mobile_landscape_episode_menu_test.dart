import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(667, 375),
    const Size(844, 390),
    const Size(932, 430),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'landscape episodes stay compact and selectable $size scale=$scale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          int? selected;
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  padding: const EdgeInsets.only(right: 24),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: PlayerMenu(
                  section: PlayerMenuSection.episodes,
                  episodes: [
                    for (var i = 1; i <= 139; i++) Episode({'id': '$i'}, i),
                  ],
                  currentIndex: 0,
                  preferences: const PlaybackPreferences(),
                  qualities: const [],
                  actualQuality: 0,
                  local: false,
                  favorite: false,
                  mobile: true,
                  onEpisode: (index) => selected = index,
                  onAllSeasons: () {},
                  onPreferences: (_) async {},
                  onFavorite: () async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final panel = tester.getRect(
            find.byKey(const ValueKey('player-menu-panel')),
          );
          expect(panel.width, lessThanOrEqualTo(320));
          expect(panel.width, lessThan(size.width * .4));
          expect(panel.right, lessThanOrEqualTo(size.width - 24));
          final episode = find.byKey(const ValueKey('menu-episode-1'));
          expect(tester.getSize(episode).height, greaterThanOrEqualTo(44));
          await tester.tap(episode);
          expect(selected, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
