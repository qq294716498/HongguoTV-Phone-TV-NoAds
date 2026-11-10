import 'package:duanju_app/portrait_video_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'landscape image moves up fifteen percent without changing aspect ratio',
    () {
      for (final viewport in [
        const Size(360, 800),
        const Size(412, 915),
        const Size(320, 480),
        const Size(600, 960),
      ]) {
        for (final aspect in [4 / 3, 16 / 9, 21 / 9]) {
          final rect = portraitLandscapeVideoRect(viewport, aspect)!;
          expect(rect.width / rect.height, closeTo(aspect, .0001));
          expect(rect.width, viewport.width);
          final centered = (viewport.height - rect.height) / 2;
          expect(
            rect.top,
            closeTo(
              (centered - viewport.height * .15).clamp(
                centered < 96 ? centered : 96,
                viewport.height - rect.height,
              ),
              .001,
            ),
          );
          expect(rect.top, lessThan((viewport.height - rect.height) / 2));
          expect(rect.bottom, lessThanOrEqualTo(viewport.height));
        }
      }
    },
  );

  test('saved offsets move both ways and stay within the safe viewport', () {
    const size = Size(420, 900);
    final center = portraitLandscapeVideoRect(size, 16 / 9, verticalOffset: 0)!;
    final down = portraitLandscapeVideoRect(size, 16 / 9, verticalOffset: .15)!;
    expect(center.center.dy, 450);
    expect(down.center.dy, 585);
    for (final offset in [-9.0, -.5, .5, 9.0, double.nan]) {
      final rect = portraitLandscapeVideoRect(
        size,
        16 / 9,
        verticalOffset: offset,
      )!;
      expect(rect.top, greaterThanOrEqualTo(96));
      expect(rect.bottom, lessThanOrEqualTo(900));
      expect(rect.size, center.size);
    }
  });

  test('safe insets and scaled header are reserved', () {
    final rect = portraitLandscapeVideoRect(
      const Size(420, 900),
      16 / 9,
      padding: const EdgeInsets.fromLTRB(12, 44, 18, 34),
      textScaler: TextScaler.linear(2),
    )!;
    expect(rect.left, 12);
    expect(rect.right, 402);
    expect(rect.top, closeTo(44 + (822 - rect.height) / 2 - 822 * .15, .001));
    expect(rect.width / rect.height, closeTo(16 / 9, .0001));
  });

  test('short portrait surface never moves image downward or clips it', () {
    final rect = portraitLandscapeVideoRect(const Size(400, 401), 1.01)!;
    expect(rect.top, closeTo((401 - 400 / 1.01) / 2, .0001));
    expect(rect.bottom, lessThanOrEqualTo(401));
  });

  test(
    'landscape, square, portrait media and invalid geometry are unchanged',
    () {
      for (final size in [const Size(900, 420), const Size(400, 400)]) {
        expect(portraitLandscapeVideoRect(size, 16 / 9), isNull);
      }
      for (final aspect in [
        9 / 16,
        1.0,
        0.0,
        -1.0,
        double.nan,
        double.infinity,
      ]) {
        expect(
          portraitLandscapeVideoRect(const Size(400, 900), aspect),
          isNull,
        );
      }
      expect(portraitLandscapeVideoRect(Size.zero, 16 / 9), isNull);
      expect(
        portraitLandscapeVideoRect(
          const Size(400, 900),
          16 / 9,
          padding: const EdgeInsets.symmetric(horizontal: 250),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'frame and overlaid subtitle share bounds, orientation keeps child state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const frameKey = ValueKey('synthetic-video');
      const captionKey = ValueKey('synthetic-subtitle');
      final stateKey = GlobalKey();
      Widget scene({
        bool enabled = true,
        double aspect = 16 / 9,
        double offset = -.15,
      }) => MaterialApp(
        home: PortraitVideoPosition(
          offset: offset,
          child: Scaffold(
            body: SafeArea(
              child: PortraitVideoFrame(
                enabled: enabled,
                aspectRatio: aspect,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: StatefulBuilder(
                      key: stateKey,
                      builder: (context, setState) => const ColoredBox(
                        key: frameKey,
                        color: Colors.blue,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Text('合成字幕', key: captionKey),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(scene());
      final state = stateKey.currentState;
      final rect = tester.getRect(find.byKey(frameKey));
      expect(rect.center.dy, closeTo(450 - 900 * .15, .001));
      expect(rect.size.aspectRatio, closeTo(16 / 9, .0001));
      expect(tester.getRect(find.byKey(captionKey)).bottom, rect.bottom);
      await tester.pumpWidget(scene(offset: .15));
      expect(
        tester.getRect(find.byKey(frameKey)).center.dy,
        closeTo(585, .001),
      );
      expect(stateKey.currentState, same(state));
      await tester.pumpWidget(scene(enabled: false));
      expect(
        tester.getRect(find.byKey(frameKey)).center.dy,
        closeTo(450, .0001),
      );
      expect(stateKey.currentState, same(state));
      await tester.pumpWidget(scene(aspect: 9 / 16));
      expect(
        tester.getRect(find.byKey(frameKey)).center.dy,
        closeTo(450, .0001),
      );
      expect(stateKey.currentState, same(state));
      tester.view.physicalSize = const Size(900, 420);
      await tester.pumpWidget(scene());
      expect(
        tester.getRect(find.byKey(frameKey)).center,
        offsetMoreOrLessEquals(const Offset(450, 210)),
      );
      expect(stateKey.currentState, same(state));
      expect(tester.takeException(), isNull);
    },
  );
}
