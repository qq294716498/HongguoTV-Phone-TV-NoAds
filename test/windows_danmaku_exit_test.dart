import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:duanju_app/danmaku_exit_motion.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show flushDanmaku, updateDanmaku;

PlaybackPlan _plan(String id) => PlaybackPlan(
  url: 'https://media.example.test/$id.mp4',
  session: 'synthetic-$id',
  danmakuId: id,
);

Finder _active() => find.byKey(const ValueKey('danmaku-motion-shared'));
Finder _exit(int serial) =>
    find.byKey(ValueKey('windows-danmaku-exit-motion-$serial'));
Finder _allExits() => find.byWidgetPredicate(
  (widget) =>
      widget is Transform &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'windows-danmaku-exit-motion-',
      ),
);

Offset _position(WidgetTester tester, Finder motion) => tester.getTopLeft(
  find.descendant(of: motion, matching: find.byType(DanmakuEmojiText)),
);

class _Harness {
  _Harness(this.tester, this.controller);
  final WidgetTester tester;
  final DanmakuController controller;
  bool disposed = false;

  Future<void> render({
    double aspect = 16 / 9,
    double speed = 1,
    bool currentVisible = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: DanmakuOverlay(
            controller: controller,
            aspectRatio: aspect,
            desktop: true,
            speed: speed,
            currentVisible: currentVisible,
          ),
        ),
      ),
    ),
  );

  Future<void> next(String id, {bool playing = true, double rate = 1}) async {
    controller.setPlan(_plan(id));
    updateDanmaku(controller, playing: playing, speed: rate);
    await flushDanmaku();
    await tester.pump();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (!disposed) {
      disposed = true;
      controller.dispose();
    }
  }
}

Future<_Harness> _create(
  WidgetTester tester, {
  double rate = 1,
  int position = 0,
}) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = DanmakuFixtureRepository()
    ..response = (request) => DanmakuPage(
      episodeId: request.plan.danmakuId,
      startMs: request.startMs,
      nextMs: request.startMs + 30000 < request.durationMs
          ? request.startMs + 30000
          : request.durationMs,
      items: [
        DanmakuItem(
          id: 'shared',
          text: 'episode-${request.plan.danmakuId}',
          timeMs: request.plan.danmakuId == 'A' ? position : request.startMs,
        ),
      ],
    );
  final controller = DanmakuController(repository)..setPlan(_plan('A'));
  final harness = _Harness(tester, controller);
  addTearDown(harness.dispose);
  updateDanmaku(controller, speed: rate, position: position);
  await flushDanmaku();
  await harness.render();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(_active(), findsOneWidget);
  return harness;
}

void main() {
  for (final rate in [1.0, 1.5]) {
    testWidgets(
      'desktop $rate playback rate preserves x and velocity, then retires within 600ms',
      (tester) async {
        final harness = await _create(tester, rate: rate);
        final before = _position(tester, _active());
        harness.controller.setPlan(null);
        await tester.pump();
        expect(_active(), findsNothing);
        expect(_exit(1), findsOneWidget);
        expect(_position(tester, _exit(1)), before);
        final zero = _position(tester, _exit(1)).dx;
        await tester.pump(const Duration(milliseconds: 1));
        final firstTravel = zero - _position(tester, _exit(1)).dx;
        expect(
          firstTravel,
          closeTo(960 / 10 * danmakuBaselineSpeed / 1000, .01),
        );
        await harness.next('B', rate: rate);
        expect(_active(), findsOneWidget);
        expect(_exit(1), findsOneWidget);
        expect(
          tester
              .widgetList<DanmakuEmojiText>(find.byType(DanmakuEmojiText))
              .map((w) => w.text),
          containsAll(['episode-A', 'episode-B']),
        );
        var previous = _position(tester, _exit(1)).dx;
        final displacements = <double>[];
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final next = _position(tester, _exit(1)).dx;
          displacements.add(previous - next);
          expect(next, lessThan(previous));
          previous = next;
        }
        for (var frame = 1; frame < displacements.length; frame++) {
          expect(displacements[frame], greaterThan(displacements[frame - 1]));
        }
        await tester.pump(const Duration(milliseconds: 440));
        expect(_exit(1), findsNothing);
        expect(_active(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'held video hides and defers only new comments while previous comments retire',
    (tester) async {
      final harness = await _create(tester);
      harness.controller.setPlan(null);
      await harness.render(currentVisible: false);
      await harness.next('B');
      expect(_exit(1), findsOneWidget);
      expect(_active(), findsNothing);
      await tester.pump(const Duration(milliseconds: 610));
      expect(_allExits(), findsNothing);
      expect(_active(), findsNothing);
      await harness.render();
      expect(_active(), findsOneWidget);
      expect(_position(tester, _active()).dx, closeTo(960, .01));
      expect(
        tester.widget<DanmakuEmojiText>(find.byType(DanmakuEmojiText)).text,
        'episode-B',
      );
    },
  );

  for (final dilation in [1.0, 2.0]) {
    testWidgets(
      'exit deadlines start at the event before a delayed first frame, dilation $dilation',
      (tester) async {
        final previousDilation = timeDilation;
        timeDilation = dilation;
        try {
          final harness = await _create(tester);
          harness.controller.setPlan(null);
          await tester.pump(const Duration(milliseconds: 610));
          expect(_allExits(), findsNothing);
          expect(find.byType(DanmakuEmojiText), findsNothing);
          expect(tester.binding.transientCallbackCount, 0);
        } finally {
          timeDilation = previousDilation;
        }
      },
    );
  }

  testWidgets(
    'staggered expiry preserves another captured text element without rebuilding it',
    (tester) async {
      final harness = await _create(tester);
      harness.controller.setPlan(null);
      await harness.render(aspect: 9 / 16);
      await harness.next('B');
      await tester.pump(const Duration(milliseconds: 300));
      await harness.next('C');
      expect(_allExits(), findsNWidgets(2));
      final oldHook = debugOnRebuildDirtyWidget;
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        oldHook?.call(element, builtOnce);
        if (element.widget case DanmakuEmojiText(text: 'episode-B')) builds++;
      };
      try {
        await tester.pump(const Duration(milliseconds: 301));
        expect(_exit(1), findsNothing);
        expect(_exit(2), findsOneWidget);
        expect(builds, 0);
      } finally {
        debugOnRebuildDirtyWidget = oldHook;
      }
    },
  );

  testWidgets(
    'normal end keeps the last frame visible before native next-plan handoff',
    (tester) async {
      final harness = await _create(tester, position: 179500);
      final before = _position(tester, _active());
      updateDanmaku(harness.controller, position: 180000, playing: false);
      await tester.pump();
      expect(_active(), findsNothing);
      expect(_exit(1), findsOneWidget);
      expect(_position(tester, _exit(1)), before);
      await tester.pump(const Duration(milliseconds: 250));
      harness.controller.setPlan(null);
      await tester.pump();
      await harness.next('B');
      expect(_exit(1), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 351));
      expect(_exit(1), findsNothing);
      expect(_active(), findsOneWidget);
    },
  );

  testWidgets(
    'rapid episode switches retain older exit deadlines and isolate reused IDs',
    (tester) async {
      final harness = await _create(tester);
      await harness.next('B');
      await tester.pump(const Duration(milliseconds: 300));
      final previous = _position(tester, _exit(1));
      await harness.next('C');
      expect(_position(tester, _exit(1)), previous);
      expect(_exit(2), findsOneWidget);
      expect(_allExits(), findsNWidgets(2));
      await tester.pump(const Duration(milliseconds: 301));
      expect(_exit(1), findsNothing);
      expect(_exit(2), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_allExits(), findsNothing);
      final text = tester.widget<DanmakuEmojiText>(
        find.byType(DanmakuEmojiText),
      );
      expect(text.text, 'episode-C');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paused new playback keeps its own comments still while old comments retire',
    (tester) async {
      final harness = await _create(tester);
      await harness.next('B', playing: false);
      final beforeExit = _position(tester, _exit(1)).dx;
      final beforeActive = _position(tester, _active()).dx;
      await tester.pump(const Duration(milliseconds: 100));
      expect(_position(tester, _exit(1)).dx, lessThan(beforeExit));
      expect(_position(tester, _active()).dx, beforeActive);
      updateDanmaku(harness.controller);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_position(tester, _active()).dx, lessThan(beforeActive));
      await tester.pump(const Duration(milliseconds: 401));
      expect(_allExits(), findsNothing);
    },
  );

  testWidgets(
    'explicit access reset purges an exit even when the plan is already null',
    (tester) async {
      final harness = await _create(tester);
      harness.controller.setPlan(null);
      await tester.pump();
      expect(_exit(1), findsOneWidget);
      harness.controller.setPlan(null, retirePrevious: false);
      await tester.pump();
      expect(_allExits(), findsNothing);
      expect(find.byType(DanmakuEmojiText), findsNothing);
    },
  );

  for (final policy in ['disabled', 'background', 'disposed']) {
    testWidgets('$policy clears desktop exits and releases their ticker', (
      tester,
    ) async {
      final harness = await _create(tester);
      harness.controller.setPlan(null);
      await tester.pump();
      expect(_exit(1), findsOneWidget);
      switch (policy) {
        case 'disabled':
          harness.controller.setEnabled(false);
        case 'background':
          updateDanmaku(harness.controller, foreground: false);
        case 'disposed':
          harness.controller.dispose();
          harness.disposed = true;
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(_allExits(), findsNothing);
      await harness.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'seek within the same episode keeps its existing clear semantics',
    (tester) async {
      final harness = await _create(tester);
      harness.controller.beginSeek();
      await tester.pump();
      harness.controller.endSeek(const Duration(seconds: 5));
      await tester.pump();
      expect(_active(), findsNothing);
      expect(_allExits(), findsNothing);
    },
  );

  testWidgets(
    'an aspect change preserves the old viewport origin and cached text motion',
    (tester) async {
      final harness = await _create(tester);
      final before = _position(tester, _active());
      harness.controller.setPlan(null);
      await harness.render(aspect: 9 / 16);
      expect(_position(tester, _exit(1)), before);
      final oldHook = debugOnRebuildDirtyWidget;
      var textRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        oldHook?.call(element, builtOnce);
        if (element.widget is DanmakuEmojiText) textRebuilds++;
      };
      try {
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(textRebuilds, 0);
      } finally {
        debugOnRebuildDirtyWidget = oldHook;
      }
      expect(_position(tester, _exit(1)).dx, lessThan(before.dx));
      expect(_position(tester, _exit(1)).dy, before.dy);
      await tester.pump(const Duration(milliseconds: 409));
      expect(_allExits(), findsNothing);
    },
  );

  testWidgets(
    'many quick switches stay bounded and never revive an old episode',
    (tester) async {
      final harness = await _create(tester);
      for (var episode = 0; episode < 20; episode++) {
        await harness.next('quick-$episode');
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester
              .widgetList<DanmakuEmojiText>(find.byType(DanmakuEmojiText))
              .length,
          lessThanOrEqualTo(maxDanmakuFlights),
        );
      }
      await tester.pump(const Duration(milliseconds: 601));
      expect(_allExits(), findsNothing);
      expect(
        tester
            .widgetList<DanmakuEmojiText>(find.byType(DanmakuEmojiText))
            .map((w) => w.text),
        everyElement('episode-quick-19'),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
