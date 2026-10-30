import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(640, 360),
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
          var allSeasonsOpened = 0;
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
                  onAllSeasons: () => allSeasonsOpened++,
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
          final allSeasons = find.byKey(const ValueKey('menu-all-seasons'));
          expect(
            find.descendant(of: allSeasons, matching: find.text('查看全季')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: allSeasons,
              matching: find.byIcon(Icons.video_library_outlined),
            ),
            findsOneWidget,
          );
          final allSeasonsRect = tester.getRect(allSeasons);
          final closeRect = tester.getRect(find.byTooltip('关闭菜单'));
          expect(allSeasonsRect.height, 32);
          expect(allSeasonsRect.left, greaterThanOrEqualTo(panel.left));
          expect(allSeasonsRect.right, lessThanOrEqualTo(closeRect.left));
          await tester.tap(allSeasons);
          expect(allSeasonsOpened, 1);
          final grid = find.byKey(const ValueKey('compact-episode-scroll'));
          final gridRect = tester.getRect(grid);
          expect(gridRect.height / panel.height, greaterThanOrEqualTo(.8));
          final first = tester.getRect(
            find.byKey(const ValueKey('menu-episode-1')),
          );
          final sixth = tester.getRect(
            find.byKey(const ValueKey('menu-episode-6')),
          );
          final seventh = tester.getRect(
            find.byKey(const ValueKey('menu-episode-7')),
          );
          expect(sixth.top, first.top);
          expect(seventh.top, greaterThan(first.bottom));
          expect(find.byTooltip('跳转集数'), findsNothing);
          expect(find.byTooltip('下一组选集'), findsNothing);
          final controller = tester.widget<GridView>(grid).controller!;
          controller.jumpTo(controller.position.maxScrollExtent);
          await tester.pumpAndSettle();
          await tester.drag(grid, const Offset(0, -110));
          await tester.pumpAndSettle();
          expect(find.text('51–100 集'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('menu-episode-51')));
          expect(selected, 50);
          await tester.drag(grid, const Offset(0, 110));
          await tester.pumpAndSettle();
          expect(find.text('1–50 集'), findsOneWidget);
          await tester.tap(find.byTooltip('定位当前'));
          await tester.pumpAndSettle();
          final episode = find.byKey(const ValueKey('menu-episode-1'));
          expect(tester.getSize(episode).height, greaterThanOrEqualTo(44));
          await tester.tap(episode);
          expect(selected, 0);
          await tester.drag(grid, const Offset(0, 110));
          await tester.pumpAndSettle();
          expect(find.text('1–50 集'), findsOneWidget);
          if (size.width == 667 && scale == 1) {
            await tester.tap(find.byKey(const ValueKey('episode-range')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('101–139 集').last);
            await tester.pumpAndSettle();
            controller.jumpTo(controller.position.maxScrollExtent);
            await tester.pumpAndSettle();
            await tester.drag(grid, const Offset(0, -110));
            await tester.pumpAndSettle();
            expect(find.text('101–139 集'), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('menu-episode-139')));
            expect(selected, 138);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
