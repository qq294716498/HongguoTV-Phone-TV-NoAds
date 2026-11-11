import 'package:duanju_app/television_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'remote_test_helpers.dart';

void main() {
  testWidgets('selected playback speed keeps its fill while focus moves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      televisionHost(
        child: Scaffold(
          body: TelevisionSettingsDialog(
            speed: 1,
            quality: 0,
            qualities: const [720, 1080],
            favorite: false,
            onFavorite: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final selected = find.byKey(const ValueKey('tv-speed-1.0'));
    BoxDecoration decoration(Finder item) =>
        tester
                .widget<AnimatedContainer>(
                  find
                      .descendant(
                        of: item,
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    final colors = Theme.of(tester.element(selected)).colorScheme;
    final before = tester.getRect(selected);
    expect(decoration(selected).color, colors.primaryContainer);
    expect(
      (decoration(selected).border! as Border).top.color,
      colors.onSurface,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(decoration(selected).color, colors.primaryContainer);
    expect((decoration(selected).border! as Border).top.color, colors.primary);
    expect(tester.getRect(selected), before);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      (decoration(selected).border! as Border).top.color,
      colors.onSurface,
    );
    expect((decoration(selected).border! as Border).top.width, 3);
    expect(tester.takeException(), isNull);
  });
}
