import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

void main() {
  setUp(mockPlayerDevice);

  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets('compact TV controls, menu key and held seek at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://example.test/synthetic.mp4'));
      await player.pause();
      await player.seek(const Duration(seconds: 30));
      final seeks = <Duration>[];
      var opens = 0;
      await tester.pumpWidget(
        televisionHost(
          child: Builder(
            builder: (context) => Scaffold(
              body: TelevisionControls(
                player: player,
                title: '合成遥控测试',
                enabled: true,
                showOnPlaybackReady: false,
                onTogglePlayback: player.playOrPause,
                onSeek: (_) {},
                onSeekTo: (target) async {
                  seeks.add(target);
                  await player.seek(target);
                },
                onPrevious: () {},
                onNext: () {},
                onBack: () {},
                onSettings: () async {},
                onEpisodes: () async {
                  opens++;
                  await showDialog<int>(
                    context: context,
                    builder: (_) => TelevisionEpisodeDialog(
                      episodes: List.generate(
                        200,
                        (i) => Episode({'id': '${i + 1}'}, i + 1),
                      ),
                      currentIndex: 70,
                      onAllSeasons: () {},
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks, [const Duration(seconds: 45)]);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(seeks.last, const Duration(seconds: 30));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      }
      expect(seeks, hasLength(2));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks.last, const Duration(seconds: 120));
      expect(find.byKey(const ValueKey('tv-seek-preview')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('tv-control-panel'))).height,
        lessThan(190),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('tv-play-pause'))).height,
        greaterThanOrEqualTo(44),
      );
      focusRemote(tester, find.byKey(const ValueKey('tv-progress')));
      await tester.pump();
      final count = seeks.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks, hasLength(count));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-71');
      final grid = tester.widget<RemoteGrid>(find.byType(RemoteGrid));
      expect(grid.columns, greaterThanOrEqualTo(10));
      expect(grid.itemExtent, 48);
      expect(grid.spacing, 6);
      expect(find.byKey(const ValueKey('tv-all-seasons')), findsOneWidget);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(seeks, hasLength(count));
      expect(opens, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TelevisionEpisodeDialog), findsNothing);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-surface',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  }
}
