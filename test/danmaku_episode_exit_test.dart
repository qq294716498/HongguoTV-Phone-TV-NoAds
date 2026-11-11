import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:duanju_app/danmaku_exit_motion.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show flushDanmaku;

class _ExitHarness {
  _ExitHarness(this.mode, {bool dense = false}) {
    repository = DanmakuFixtureRepository()
      ..response = (request) => DanmakuPage(
        episodeId: request.plan.danmakuId,
        startMs: request.startMs,
        nextMs: request.startMs + 30000,
        items: [
          for (var i = 0; i < (dense ? 90 : 1); i++)
            DanmakuItem(
              id: dense ? 'item-$i' : 'shared',
              text: dense
                  ? '${request.plan.session} item $i'
                  : '${request.plan.session} flight',
              timeMs: request.startMs + i * 100,
            ),
        ],
      );
    controller = DanmakuController(repository, now: () => now);
  }

  final String mode;
  late DanmakuFixtureRepository repository;
  late DanmakuController controller;
  DateTime now = DateTime.utc(2026, 11, 2);
  bool disposed = false;
  bool currentVisible = true;
  double aspectRatio = 16 / 9;
  late StateSetter rebuild;

  void update({
    int position = 0,
    int duration = 120000,
    double speed = 1,
    bool playing = true,
    bool foreground = true,
    bool available = true,
  }) => controller.update(
    position: Duration(milliseconds: position),
    duration: Duration(milliseconds: duration),
    speed: speed,
    playing: playing,
    buffering: false,
    foreground: foreground,
    available: available,
  );

  Future<void> select(
    String session, {
    double speed = 1,
    bool playing = true,
  }) async {
    controller.setPlan(
      PlaybackPlan(
        url: 'file:///synthetic-$session.mp4',
        session: session,
        danmakuId: session,
      ),
    );
    update(speed: speed, playing: playing);
    await flushDanmaku();
  }

  Future<void> mount(WidgetTester tester, {double speed = 1}) async {
    tester.view.physicalSize = mode == 'mobile'
        ? const Size(420, 880)
        : const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(dispose);
    await select('A', speed: speed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return DanmakuOverlay(
                controller: controller,
                aspectRatio: aspectRatio,
                currentVisible: currentVisible,
                mobile: mode == 'mobile',
                television: mode == 'tv',
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await advance(tester, const Duration(seconds: 1));
  }

  Future<void> advance(WidgetTester tester, Duration elapsed) async {
    now = now.add(elapsed);
    await tester.pump(elapsed);
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    controller.dispose();
  }
}

Finder _exits() => find.byWidgetPredicate(
  (widget) =>
      widget is Transform &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'danmaku-exit-motion-',
      ),
);

Finder _exitText(String text) =>
    find.ancestor(of: find.text(text), matching: _exits());

Offset _textOrigin(WidgetTester tester, Finder motion) => tester.getTopLeft(
  find.descendant(of: motion, matching: find.byType(DanmakuEmojiText)),
);

void main() {
  for (final mode in ['mobile', 'tv']) {
    testWidgets(
      '$mode live and retiring motion share one ticker without frame builds',
      (tester) async {
        final harness = _ExitHarness(mode);
        await harness.mount(tester);
        final live = find.byKey(const ValueKey('danmaku-motion-shared'));
        final before = _textOrigin(tester, live).dx;
        final previousHook = debugOnRebuildDirtyWidget;
        var builds = 0;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousHook?.call(element, builtOnce);
          if (element.findAncestorWidgetOfExactType<DanmakuOverlay>() != null) {
            builds++;
          }
        };
        try {
          for (var frame = 0; frame < 12; frame++) {
            await harness.advance(tester, const Duration(milliseconds: 16));
            expect(tester.binding.transientCallbackCount, 1);
          }
          expect(builds, 0);
          expect(_textOrigin(tester, live).dx, lessThan(before));
          harness.controller.setPlan(null);
          await harness.select('B');
          await tester.pump();
          final retiring = _exitText('A flight');
          expect(retiring, findsOneWidget);
          final exitBefore = _textOrigin(tester, retiring).dx;
          builds = 0;
          for (var frame = 0; frame < 12; frame++) {
            await harness.advance(tester, const Duration(milliseconds: 16));
            expect(tester.binding.transientCallbackCount, 1);
          }
          expect(builds, 0);
          expect(_textOrigin(tester, retiring).dx, lessThan(exitBefore));
        } finally {
          debugOnRebuildDirtyWidget = previousHook;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['mobile', 'tv', 'legacy']) {
    for (final speed in [1.0, 1.5]) {
      testWidgets(
        '$mode ${speed}x transition preserves actual position and velocity',
        (tester) async {
          final harness = _ExitHarness(mode);
          await harness.mount(tester, speed: speed);
          final live = find.byKey(const ValueKey('danmaku-motion-shared'));
          final earlier = _textOrigin(tester, live).dx;
          await harness.advance(tester, const Duration(milliseconds: 10));
          final current = _textOrigin(tester, live).dx;
          final velocity = (earlier - current) / .01;
          expect(velocity, greaterThan(0));
          harness.controller.setPlan(null);
          await tester.pump();
          expect(live, findsNothing);
          final old = _exitText('A flight');
          expect(old, findsOneWidget);
          final first = _textOrigin(tester, old).dx;
          expect(first, closeTo(current, .01));
          await harness.advance(tester, const Duration(milliseconds: 1));
          expect(
            (first - _textOrigin(tester, old).dx) / .001,
            closeTo(velocity, .2),
          );
          await harness.select('B', speed: speed, playing: false);
          await tester.pump();
          expect(harness.controller.positionMs, 0);
          expect(find.text('B flight'), findsOneWidget);
          expect(_exitText('A flight'), findsOneWidget);
          final before = _textOrigin(tester, old).dx;
          final oldHook = debugOnRebuildDirtyWidget;
          var textBuilds = 0;
          debugOnRebuildDirtyWidget = (element, builtOnce) {
            oldHook?.call(element, builtOnce);
            if (element.widget is DanmakuEmojiText) textBuilds++;
          };
          try {
            for (var frame = 0; frame < 10; frame++) {
              await harness.advance(tester, const Duration(milliseconds: 16));
            }
            expect(textBuilds, 0);
          } finally {
            debugOnRebuildDirtyWidget = oldHook;
          }
          expect(
            _textOrigin(tester, old).dx,
            lessThan(before - velocity * .16),
          );
          await harness.advance(tester, danmakuExitDuration);
          expect(_exits(), findsNothing);
          expect(find.text('B flight'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('$mode rapid A B C changes keep the original exit deadline', (
      tester,
    ) async {
      final harness = _ExitHarness(mode);
      await harness.mount(tester);
      harness.controller.setPlan(null);
      await tester.pump();
      await harness.select('B');
      await tester.pump();
      await harness.advance(tester, const Duration(milliseconds: 120));
      final a = _exitText('A flight');
      final before = _textOrigin(tester, a).dx;
      harness.controller.setPlan(null);
      await tester.pump();
      expect(_textOrigin(tester, a).dx, closeTo(before, .01));
      await harness.select('C');
      await tester.pump();
      expect(_exits(), findsNWidgets(2));
      expect(find.text('C flight'), findsOneWidget);
      final oldHook = debugOnRebuildDirtyWidget;
      var remainingTextBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        oldHook?.call(element, builtOnce);
        final widget = element.widget;
        if (widget is DanmakuEmojiText && widget.text == 'B flight')
          remainingTextBuilds++;
      };
      try {
        await harness.advance(tester, const Duration(milliseconds: 490));
        expect(remainingTextBuilds, 0);
      } finally {
        debugOnRebuildDirtyWidget = oldHook;
      }
      expect(find.text('A flight'), findsNothing);
      expect(_exitText('B flight'), findsOneWidget);
      expect(_exits().evaluate().length, lessThanOrEqualTo(maxDanmakuFlights));
      await harness.advance(tester, const Duration(milliseconds: 120));
      expect(_exits(), findsNothing);
      expect(find.text('C flight'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$mode natural completion retires before delayed next-plan loading',
      (tester) async {
        final harness = _ExitHarness(mode);
        await harness.mount(tester);
        final live = find.byKey(const ValueKey('danmaku-motion-shared'));
        final before = _textOrigin(tester, live).dx;
        harness.update(position: 120000);
        await tester.pump();
        expect(harness.controller.atEnd, isTrue);
        expect(
          _textOrigin(tester, _exitText('A flight')).dx,
          closeTo(before, .01),
        );
        await harness.advance(tester, const Duration(milliseconds: 150));
        harness.controller.setPlan(null);
        await tester.pump();
        expect(_exitText('A flight'), findsOneWidget);
        await harness.advance(tester, const Duration(milliseconds: 460));
        expect(_exits(), findsNothing);
        await harness.select('B');
        await tester.pump();
        expect(find.text('B flight'), findsOneWidget);
        expect(find.text('A flight'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final reason in ['disabled', 'background', 'access']) {
      testWidgets(
        '$mode $reason clears exits immediately even with no current plan',
        (tester) async {
          final harness = _ExitHarness(mode);
          await harness.mount(tester);
          harness.controller.setPlan(null);
          await tester.pump();
          expect(_exits(), findsOneWidget);
          switch (reason) {
            case 'disabled':
              harness.controller.setEnabled(false);
            case 'background':
              harness.update(
                duration: 0,
                playing: false,
                foreground: false,
                available: false,
              );
            case 'access':
              harness.controller.setPlan(null, retirePrevious: false);
          }
          await tester.pump();
          expect(_exits(), findsNothing);
          await harness.advance(tester, const Duration(seconds: 1));
          expect(find.text('A flight'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('$mode delayed first frame does not extend the exit deadline', (
      tester,
    ) async {
      final harness = _ExitHarness(mode);
      await harness.mount(tester);
      harness.controller.setPlan(null);
      await harness.advance(tester, const Duration(milliseconds: 610));
      expect(_exits(), findsNothing);
      expect(find.text('A flight'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$mode retained old viewport exits while new live content is hidden',
      (tester) async {
        final harness = _ExitHarness(mode);
        await harness.mount(tester);
        final before = _textOrigin(
          tester,
          find.byKey(const ValueKey('danmaku-motion-shared')),
        );
        harness.controller.setPlan(null);
        harness.rebuild(() {
          harness.currentVisible = false;
          harness.aspectRatio = 9 / 16;
        });
        await harness.select('B');
        await tester.pump();
        expect(find.text('B flight'), findsNothing);
        expect(harness.controller.items.single.text, 'B flight');
        expect(
          _textOrigin(tester, _exitText('A flight')),
          closeToOffset(before, .01),
        );
        await harness.advance(tester, const Duration(milliseconds: 200));
        expect(_exitText('A flight'), findsOneWidget);
        harness.rebuild(() => harness.currentVisible = true);
        await tester.pump();
        expect(find.text('B flight'), findsOneWidget);
        expect(harness.controller.positionMs, 0);
        await harness.advance(tester, const Duration(milliseconds: 410));
        expect(_exits(), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$mode seeking does not retire flights and disposal stops pending exit ticks',
      (tester) async {
        final harness = _ExitHarness(mode);
        await harness.mount(tester);
        final revision = harness.controller.planRevision;
        harness.controller.beginSeek();
        harness.controller.endSeek(const Duration(milliseconds: 1000));
        await tester.pump();
        expect(harness.controller.planRevision, revision);
        expect(_exits(), findsNothing);
        await harness.select('B');
        await tester.pump();
        await harness.advance(tester, const Duration(seconds: 1));
        harness.controller.setPlan(null);
        await tester.pump();
        expect(_exits().evaluate(), isNotEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        harness.dispose();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rapid dense mobile transitions keep a shared bounded flight budget',
    (tester) async {
      final harness = _ExitHarness('mobile', dense: true);
      await harness.mount(tester);
      for (var i = 1; i <= 60; i++) {
        harness.update(position: i * 100);
        await harness.advance(tester, const Duration(milliseconds: 100));
      }
      var peak = 0;
      for (var episode = 0; episode < 12; episode++) {
        harness.controller.setPlan(null);
        await harness.select('next-$episode');
        await tester.pump();
        await harness.advance(tester, const Duration(milliseconds: 100));
        final normal = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Transform &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'danmaku-motion-',
                  ),
            )
            .evaluate()
            .length;
        final total = normal + _exits().evaluate().length;
        if (total > peak) peak = total;
        expect(total, lessThanOrEqualTo(maxDanmakuFlights));
      }
      expect(peak, greaterThan(4));
      await harness.advance(tester, danmakuExitDuration);
      expect(_exits(), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Matcher closeToOffset(Offset expected, double tolerance) => predicate<Offset>(
  (actual) => (actual - expected).distance <= tolerance,
  'within $tolerance pixels of $expected',
);
