import 'dart:async';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'remote_test_helpers.dart';

void main() {
  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets('TV keyboard fits all keys with large text at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        televisionHost(
          child: const Scaffold(
            body: TelevisionSearchDialog(title: '搜索', initialValue: 'ABC'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final zero = tester.getRect(find.byKey(const ValueKey('tv-key-0')));
      final search = tester.getRect(find.widgetWithText(RemoteButton, '搜索'));
      expect(zero.bottom, lessThanOrEqualTo(search.top));
      expect(search.bottom, lessThan(size.height));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('TV suggestions ignore late replies after edits and clearing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = <String, Completer<List<String>>>{};
    var cancelled = 0;
    await tester.pumpWidget(
      televisionHost(
        child: Scaffold(
          body: TelevisionSearchDialog(
            title: '搜索',
            initialValue: '',
            onCancel: () {
              cancelled++;
            },
            suggestions: (query) =>
                (pending[query] = Completer<List<String>>()).future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = Offset.zero & tester.view.physicalSize;
    for (final key in ['A', 'Z', '0', '9']) {
      final rect = tester.getRect(find.byKey(ValueKey('tv-key-$key')));
      expect(bounds.contains(rect.topLeft), true);
      expect(bounds.contains(rect.bottomRight), true);
    }
    await tester.tap(find.byKey(const ValueKey('tv-key-A')));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.byKey(const ValueKey('tv-key-B')));
    await tester.pump(const Duration(milliseconds: 260));
    pending['AB']!.complete(['新结果']);
    await tester.pumpAndSettle();
    pending['A']!.complete(['旧结果']);
    await tester.pumpAndSettle();
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tv-key-C')));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.text('清空'));
    pending['ABC']!.complete(['清空后的旧结果']);
    await tester.pumpAndSettle();
    expect(find.text('清空后的旧结果'), findsNothing);
    expect(find.text('历史搜索'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(cancelled, 1);
  });

  testWidgets(
    'explicit TV search submits typed query, not the first suggestion',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        televisionHost(
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => TelevisionSearchDialog(
                      title: '找剧',
                      initialValue: 'ABC',
                      suggestions: (_) async => ['其他剧名'],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(result, 'ABC');
      expect(tester.takeException(), isNull);
    },
  );
}
