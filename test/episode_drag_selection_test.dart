import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/episode_drag_selection.dart';

void main() {
  Future<({ScrollController scroll, Set<int> Function() selected})> mount(
    WidgetTester tester, {
    Set<int> initial = const {},
    int count = 120,
    int limit = 500,
    ValueChanged<Set<int>>? onChanged,
  }) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var selected = Set<int>.of(initial);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 240,
              child: StatefulBuilder(
                builder: (context, setState) => EpisodeDragSelection(
                  controller: scroll,
                  columns: 5,
                  itemExtent: 40,
                  spacing: 5,
                  padding: const EdgeInsets.all(5),
                  numbers: List.generate(count, (index) => index + 1),
                  selected: selected,
                  limit: limit,
                  onChanged: (next) {
                    setState(() => selected = next);
                    onChanged?.call(next);
                  },
                  child: GridView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(5),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisExtent: 40,
                          mainAxisSpacing: 5,
                          crossAxisSpacing: 5,
                        ),
                    itemCount: count,
                    itemBuilder: (context, index) => TextButton(
                      key: ValueKey('cell-${index + 1}'),
                      onPressed: () => setState(() {
                        if (!selected.remove(index + 1)) {
                          selected.add(index + 1);
                        }
                      }),
                      child: Text('${index + 1}'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (scroll: scroll, selected: () => selected);
  }

  Finder cell(int number) => find.byKey(ValueKey('cell-$number'));

  testWidgets('tap and vertical scrolling keep their original behavior', (
    tester,
  ) async {
    final state = await mount(tester);
    await tester.tap(cell(2));
    await tester.pump();
    expect(state.selected(), {2});
    await tester.drag(cell(12), const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(state.scroll.offset, greaterThan(0));
    expect(state.selected(), {2});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final initial in [
    <int>{},
    {1, 2, 3, 4, 5},
  ]) {
    testWidgets(
      'horizontal drag sets a range once and restores on reversal: $initial',
      (tester) async {
        final state = await mount(tester, initial: initial);
        final gesture = await tester.startGesture(tester.getCenter(cell(2)));
        await gesture.moveTo(tester.getCenter(cell(4)));
        await tester.pump();
        expect(state.selected(), initial.isEmpty ? {2, 3, 4} : {1, 5});
        await gesture.moveTo(tester.getCenter(cell(3)));
        await tester.pump();
        expect(state.selected(), initial.isEmpty ? {2, 3} : {1, 4, 5});
        await gesture.moveTo(tester.getCenter(cell(3)));
        await tester.pump();
        expect(state.selected(), initial.isEmpty ? {2, 3} : {1, 4, 5});
        await gesture.up();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'long press can select vertically and auto-scroll beyond the first page',
    (tester) async {
      final state = await mount(tester);
      final gesture = await tester.startGesture(tester.getCenter(cell(1)));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(cell(16)));
      await tester.pump();
      expect(state.selected(), containsAll(List.generate(16, (i) => i + 1)));
      final region = tester.getRect(find.byType(EpisodeDragSelection));
      await gesture.moveTo(Offset(region.center.dx, region.bottom - 1));
      await tester.pump(const Duration(seconds: 3));
      expect(state.scroll.offset, greaterThan(300));
      expect(state.selected().any((number) => number > 50), isTrue);
      await gesture.up();
      final offset = state.scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(state.scroll.offset, offset);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('selection limit, cancel and disposal stop gesture work', (
    tester,
  ) async {
    final state = await mount(tester, initial: {100}, limit: 3);
    final gesture = await tester.startGesture(tester.getCenter(cell(1)));
    await gesture.moveTo(tester.getCenter(cell(5)));
    await tester.pump();
    expect(state.selected(), {1, 2, 100});
    await gesture.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(state.selected(), {1, 2, 100});
    final next = await tester.startGesture(tester.getCenter(cell(1)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox.shrink());
    await next.up();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
