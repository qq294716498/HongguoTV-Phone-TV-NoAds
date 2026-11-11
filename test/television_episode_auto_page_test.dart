import 'package:duanju_app/episode_browser.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'remote_test_helpers.dart';

void main() {
  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets('TV episode row boundaries page without selecting at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        televisionHost(
          child: Scaffold(
            body: EpisodeBrowser(
              episodes: List.generate(
                103,
                (i) => Episode({'id': '${i + 1}'}, i + 1),
              ),
              currentNumber: 50,
              onSelected: selected.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> focusNumber(int number) async {
        final target = find.byWidgetPredicate(
          (widget) => widget is RemoteEpisodeButton && widget.number == number,
        );
        tester.widget<RemoteEpisodeButton>(target).focusNode!.requestFocus();
        await tester.pumpAndSettle();
      }

      int focusedNumber() => tester
          .widgetList<RemoteEpisodeButton>(find.byType(RemoteEpisodeButton))
          .singleWhere((button) => button.focusNode?.hasFocus ?? false)
          .number;
      final columns = tester
          .widget<RemoteGrid>(find.byType(RemoteGrid))
          .columns;
      await focusNumber(50);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedNumber(), 51 + 49 % columns);
      expect(selected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focusedNumber(), 50);
      expect(selected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      for (var step = 0; step < 50 && focusedNumber() != 100; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(focusedNumber(), 100);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedNumber(), (101 + 49 % columns).clamp(101, 103));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RemoteEpisodeButton && widget.number == 1,
        ),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focusedNumber(), greaterThanOrEqualTo(51));
      expect(focusedNumber(), lessThanOrEqualTo(100));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, [focusedNumber() - 1]);
      for (var step = 0; step < 100 && focusedNumber() > columns; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        tester.widget<RemoteGrid>(find.byType(RemoteGrid)).itemKeys.first,
        '1',
      );
      expect(selected, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
