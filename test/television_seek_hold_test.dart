import 'package:duanju_app/models.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class SeekHoldFixture {
  final platform = ScriptedPlayer();
  late final player = Player(platformPlayer: platform);
  final controls = GlobalKey<TelevisionControlsState>();
  final seeks = <Duration>[];
  late StateSetter rebuild;
  var title = '合成遥控测试 · 第 1 集';
  var enabled = true;
  var episodePanels = 0;

  Future<void> mount(WidgetTester tester, {bool playing = true}) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await player.open(Media('https://example.test/synthetic.mp4'));
    platform.state = platform.state.copyWith(
      duration: const Duration(minutes: 10),
    );
    await player.seek(const Duration(minutes: 5));
    if (!playing) await player.pause();
    await tester.pumpWidget(
      televisionHost(
        child: Builder(
          builder: (context) => Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                rebuild = setState;
                return TelevisionControls(
                  key: controls,
                  player: player,
                  title: title,
                  enabled: enabled,
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
                    episodePanels++;
                    await showDialog<int>(
                      context: context,
                      builder: (_) => TelevisionEpisodeDialog(
                        episodes: List.generate(
                          20,
                          (i) => Episode({'id': '${i + 1}'}, i + 1),
                        ),
                        currentIndex: 0,
                        onAllSeasons: () {},
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-surface');
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  setUp(mockPlayerDevice);

  for (final key in [
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  ]) {
    for (final playing in [true, false]) {
      testWidgets(
        'held ${key.keyLabel}, playing=$playing waits for release across delayed repeats',
        (tester) async {
          final fixture = SeekHoldFixture();
          await fixture.mount(tester, playing: playing);
          await tester.sendKeyDownEvent(key);
          await tester.pump(const Duration(milliseconds: 700));
          expect(fixture.seeks, isEmpty);
          expect(find.byKey(const ValueKey('tv-seek-preview')), findsOneWidget);
          expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
          await fixture.player.pause();
          await tester.pump();
          expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
          expect(
            FocusManager.instance.primaryFocus?.debugLabel,
            'tv-player-surface',
          );
          for (var i = 0; i < 6; i++) {
            await tester.sendKeyRepeatEvent(key);
            await tester.pump(const Duration(milliseconds: 350));
            expect(fixture.seeks, isEmpty);
          }
          expect(find.byKey(const ValueKey('tv-seek-preview')), findsOneWidget);
          expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
          await tester.sendKeyUpEvent(key);
          await tester.pump();
          final seconds = key == LogicalKeyboardKey.arrowRight ? 420 : 180;
          expect(fixture.seeks, [Duration(seconds: seconds)]);
          expect(fixture.player.state.playing, false);
          await tester.pump(const Duration(seconds: 3));
          expect(fixture.seeks, hasLength(1));
          expect(find.byKey(const ValueKey('tv-seek-preview')), findsNothing);
          await fixture.dispose(tester);
        },
      );
    }
  }

  testWidgets(
    'a transient playing event cannot move focus from an active seek',
    (tester) async {
      final fixture = SeekHoldFixture();
      await fixture.mount(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await fixture.player.pause();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fixture.seeks, isEmpty);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-surface',
      );
      await fixture.player.playOrPause();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fixture.seeks, [const Duration(seconds: 330)]);
      expect(fixture.player.state.playing, true);
      expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
      await fixture.dispose(tester);
    },
  );

  testWidgets(
    'short seek commits once and visible controls retain arrow navigation',
    (tester) async {
      final fixture = SeekHoldFixture();
      await fixture.mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fixture.seeks, [const Duration(seconds: 315)]);
      expect(fixture.player.state.playing, true);
      await tester.pump(const Duration(seconds: 3));
      expect(fixture.seeks, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-player-forward',
      );
      expect(fixture.seeks, hasLength(1));
      focusRemote(tester, find.byKey(const ValueKey('tv-progress')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(fixture.seeks, hasLength(1));
      await fixture.dispose(tester);
    },
  );

  testWidgets('an active seek keeps repeats when controls become visible', (
    tester,
  ) async {
    final fixture = SeekHoldFixture();
    await fixture.mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-control-panel')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fixture.seeks, isEmpty);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-player-play');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 330)]);
    await fixture.dispose(tester);
  });

  testWidgets(
    'media seek keys work while controls are visible and preserve focus',
    (tester) async {
      final fixture = SeekHoldFixture();
      await fixture.mount(tester, playing: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      for (final key in [
        LogicalKeyboardKey.mediaFastForward,
        LogicalKeyboardKey.mediaRewind,
      ]) {
        await tester.sendKeyDownEvent(key);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.sendKeyRepeatEvent(key);
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          fixture.seeks.length,
          key == LogicalKeyboardKey.mediaFastForward ? 0 : 1,
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'tv-player-play',
        );
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }
      expect(fixture.seeks, [
        const Duration(seconds: 330),
        const Duration(seconds: 300),
      ]);
      expect(fixture.player.state.playing, false);
      await fixture.dispose(tester);
    },
  );

  testWidgets('return and menu finish a seek without applying stale repeats', (
    tester,
  ) async {
    final fixture = SeekHoldFixture();
    await fixture.mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(fixture.controls.currentState!.handleBack(), true);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 315)]);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 3));
    expect(fixture.seeks, hasLength(1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(fixture.episodePanels, 1);
    expect(fixture.seeks, [
      const Duration(seconds: 315),
      const Duration(seconds: 330),
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TelevisionEpisodeDialog), findsNothing);
    expect(find.byKey(const ValueKey('tv-control-panel')), findsNothing);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 3));
    expect(fixture.seeks, hasLength(2));
    await fixture.dispose(tester);
  });

  for (final disable in [true, false]) {
    testWidgets(
      'episode transition disable=$disable discards an uncommitted seek',
      (tester) async {
        final fixture = SeekHoldFixture();
        await fixture.mount(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 100));
        fixture.rebuild(() {
          fixture.title = '合成遥控测试 · 第 2 集';
          fixture.enabled = !disable;
        });
        await tester.pump();
        if (disable) {
          fixture.rebuild(() => fixture.enabled = true);
          await tester.pump();
          await tester.pump();
        }
        await fixture.player.seek(const Duration(seconds: 7));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(seconds: 3));
        expect(fixture.seeks, isEmpty);
        expect(fixture.player.state.position, const Duration(seconds: 7));
        expect(find.byKey(const ValueKey('tv-seek-preview')), findsNothing);
        await fixture.dispose(tester);
      },
    );
  }

  for (final lifecycle in [
    AppLifecycleState.inactive,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$lifecycle cancels a held seek before returning to playback', (
      tester,
    ) async {
      final fixture = SeekHoldFixture();
      await fixture.mount(tester);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(seconds: 3));
      expect(fixture.seeks, isEmpty);
      expect(fixture.player.state.position, const Duration(minutes: 5));
      expect(find.byKey(const ValueKey('tv-seek-preview')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fixture.seeks, [const Duration(seconds: 315)]);
      await fixture.dispose(tester);
    });
  }

  testWidgets('focus moving to another route cancels the held seek', (
    tester,
  ) async {
    final fixture = SeekHoldFixture();
    await fixture.mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    final navigator = Navigator.of(
      tester.element(find.byType(TelevisionControls)),
    );
    final route = navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: TextButton(
            autofocus: true,
            onPressed: () {},
            child: const Text('其他页面'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fixture.seeks, isEmpty);
    navigator.pop();
    await tester.pumpAndSettle();
    await route;
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 3));
    expect(fixture.seeks, isEmpty);
    expect(find.byKey(const ValueKey('tv-seek-preview')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(fixture.seeks, [const Duration(seconds: 315)]);
    await fixture.dispose(tester);
  });
}
