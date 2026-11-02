import 'package:duanju_app/player_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_fixtures.dart';
import 'player_transport_controls_test.dart' show TransportFixture;

void main() {
  setUp(mockPlayerDevice);

  AnimatedOpacity chrome(WidgetTester tester) => tester.widget<AnimatedOpacity>(
    find.byKey(const ValueKey('player-chrome')),
  );

  Slider progress(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const ValueKey('player-progress')));

  Future<TransportFixture> hidden(WidgetTester tester) async {
    final fixture = TransportFixture();
    await fixture.mount(tester, size: const Size(960, 540));
    await fixture.player.play();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(chrome(tester).opacity, 0);
    return fixture;
  }

  for (final speed in [1.0, 1.5]) {
    testWidgets(
      'hidden progress stays current without rebuilding chrome at ${speed}x',
      (tester) async {
        final fixture = await hidden(tester);
        await fixture.player.setRate(speed);
        await tester.pump();
        final oldHook = debugOnRebuildDirtyWidget;
        var builds = 0;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          oldHook?.call(element, builtOnce);
          if (element.widget is PlayerControls) builds++;
        };
        try {
          for (var i = 1; i <= 10; i++) {
            await fixture.player.seek(
              Duration(milliseconds: 30000 + (i * 100 * speed).round()),
            );
            fixture.platform.buffered(Duration(seconds: 60 + i));
            await tester.pump(const Duration(milliseconds: 100));
            expect(chrome(tester).opacity, 0);
          }
          expect(builds, 0);
        } finally {
          debugOnRebuildDirtyWidget = oldHook;
        }
        await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(chrome(tester).opacity, 1);
        expect(progress(tester).value, 30 + speed);
        expect(progress(tester).secondaryTrackValue, 70);
        await fixture.player.seek(const Duration(seconds: 44));
        await tester.pump();
        expect(progress(tester).value, 44);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('buffering still reveals hidden chrome and current progress', (
    tester,
  ) async {
    final fixture = await hidden(tester);
    await fixture.player.seek(const Duration(seconds: 48));
    fixture.platform.buffering(true);
    await tester.pump();
    await tester.pump();
    expect(chrome(tester).opacity, 1);
    expect(progress(tester).value, 48);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    fixture.platform.buffering(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'pause and a manual seek still reveal usable transport controls',
    (tester) async {
      final fixture = await hidden(tester);
      await fixture.player.seek(const Duration(seconds: 51));
      await fixture.player.pause();
      await tester.pumpAndSettle();
      expect(chrome(tester).opacity, 1);
      expect(progress(tester).value, 51);
      progress(tester).onChangeStart!(20);
      progress(tester).onChanged!(20);
      await tester.pump();
      expect(progress(tester).value, 20);
      progress(tester).onChangeEnd!(20);
      await tester.pumpAndSettle();
      expect(fixture.platform.state.position, const Duration(seconds: 20));
      expect(progress(tester).value, 20);
      expect(chrome(tester).opacity, 1);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
