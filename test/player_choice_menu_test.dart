import 'package:duanju_app/player_choice_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('closing a choice menu does not toggle the video behind it', (
    tester,
  ) async {
    var videoTaps = 0;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => videoTaps++,
            child: Align(
              alignment: Alignment.bottomRight,
              child: PlayerChoiceMenu<int>(
                buttonKey: const ValueKey('quality'),
                label: '1080P',
                tooltip: '清晰度',
                values: const [1080, 720, 0],
                selected: 1080,
                format: (v) => '$v',
                onSelected: (_) {},
                onOpenChanged: (value) => opened = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('quality')));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(videoTaps, 0);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(videoTaps, 1);
  });
  for (final width in [360.0, 1264.0]) {
    testWidgets('quality menu is anchored and selects actual 540P at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      int? chosen;
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: PlayerChoiceMenu<int>(
                buttonKey: const ValueKey('quality'),
                label: '自动（1080P）',
                tooltip: '清晰度',
                values: const [1080, 720, 540, 480, 360, 0],
                selected: 0,
                format: (v) => v == 0 ? '自动' : '${v}P',
                onSelected: (v) => chosen = v,
                onOpenChanged: (v) => opened = v,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('quality')));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      final option = find.byKey(const ValueKey('清晰度-option-540'));
      expect(
        tester.getRect(option).bottom,
        lessThan(tester.getRect(find.byKey(const ValueKey('quality'))).top),
      );
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(chosen, 540);
      expect(opened, isFalse);
      await tester.tap(find.byKey(const ValueKey('quality')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(opened, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
