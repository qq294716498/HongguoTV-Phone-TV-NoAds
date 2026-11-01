import 'dart:async';

import 'package:duanju_app/search_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _InputHarness {
  _InputHarness([TextEditingController? controller])
    : controller = controller ?? TextEditingController() {
    controllers.add(this.controller);
  }

  TextEditingController controller;
  final controllers = <TextEditingController>[];
  final requests = <String>[];
  final pending = <Completer<List<String>>>[];
  final searches = <String>[];
  final changes = <String>[];
  int cancels = 0;
  bool enabled = true;
  Future<List<String>> Function(String)? provider;
  late VoidCallback rebuild;

  Future<List<String>> suggest(String query) {
    requests.add(query);
    final request = Completer<List<String>>();
    pending.add(request);
    return request.future;
  }

  Widget get widget => MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (_, setState) {
          rebuild = () => setState(() {});
          return SearchInput(
            controller: controller,
            hint: 'Synthetic search',
            suggestions: enabled ? provider ?? suggest : null,
            onCancel: () => cancels++,
            onSearch: searches.add,
            onChanged: changes.add,
          );
        },
      ),
    ),
  );

  void complete(int index, List<String> result) =>
      pending[index].complete(result);

  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}

Future<_InputHarness> _mount(
  WidgetTester tester, {
  TextEditingController? controller,
}) async {
  final harness = _InputHarness(controller);
  await tester.pumpWidget(harness.widget);
  return harness;
}

Future<void> _unmount(
  WidgetTester tester,
  _InputHarness harness, {
  bool dispose = true,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  if (dispose) harness.dispose();
}

void main() {
  testWidgets('Chinese composition stays untouched and commits once', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    for (final text in ['n', 'ni', '你']) {
      final value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.controller.value, value);
      expect(harness.requests, isEmpty);
    }
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.requests, ['你']);
    expect(harness.changes, ['n', 'ni', '你', '你']);
    harness.controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(harness.requests, ['你']);
    expect(harness.cancels, 0);
    harness.complete(0, ['你好']);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsOneWidget);
    await _unmount(tester, harness);
  });

  testWidgets(
    'English edits cancel only issued requests and reject late results',
    (tester) async {
      final harness = await _mount(tester);
      for (final text in ['a', 'ab', 'abc', 'ab']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 260));
      expect(harness.requests, ['ab']);
      expect(harness.cancels, 0);
      await tester.enterText(find.byType(TextField), 'abcd');
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.requests, ['ab', 'abcd']);
      expect(harness.cancels, 1);
      harness.complete(0, ['obsolete']);
      harness.complete(1, ['current']);
      await tester.pumpAndSettle();
      expect(find.text('obsolete'), findsNothing);
      expect(find.text('current'), findsOneWidget);
      await _unmount(tester, harness);
      expect(harness.cancels, 1);
    },
  );

  testWidgets('clear retires one active request and cannot show its reply', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(harness.controller.text, isEmpty);
    expect(harness.cancels, 1);
    expect(harness.changes, ['old', '']);
    harness.complete(0, ['old reply']);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
    await _unmount(tester, harness);
    expect(harness.cancels, 1);
  });

  testWidgets(
    'IME submit during debounce searches once without backend cancel',
    (tester) async {
      final harness = await _mount(tester);
      await tester.enterText(find.byType(TextField), 'manual');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 500));
      expect(harness.searches, ['manual']);
      expect(harness.requests, isEmpty);
      expect(harness.cancels, 0);
      expect(harness.controller.text, 'manual');
      await _unmount(tester, harness);
    },
  );

  testWidgets('keyboard selection submits the chosen suggestion exactly once', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.enterText(find.byType(TextField), 'key');
    await tester.pump(const Duration(milliseconds: 300));
    harness.complete(0, ['first', 'second']);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.searches, ['second']);
    expect(harness.controller.text, 'second');
    expect(harness.requests, ['key']);
    expect(harness.cancels, 0);
    await _unmount(tester, harness);
  });

  testWidgets('focus loss retires debounce and refocus restores suggestions', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.enterText(find.byType(TextField), 'resume');
    await tester.pump(const Duration(milliseconds: 100));
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.requests, isEmpty);
    expect(harness.cancels, 0);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.requests, ['resume']);
    await _unmount(tester, harness, dispose: false);
    expect(harness.cancels, 1);
    final restored = await _mount(tester, controller: harness.controller);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));
    expect(restored.requests, ['resume']);
    harness.complete(0, ['obsolete route']);
    restored.complete(0, ['restored route']);
    await tester.pumpAndSettle();
    expect(find.text('obsolete route'), findsNothing);
    expect(find.text('restored route'), findsOneWidget);
    await _unmount(tester, restored);
  });

  testWidgets(
    'controller replacement detaches old input and pending suggestions',
    (tester) async {
      final harness = await _mount(tester);
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 300));
      final original = harness.controller;
      final replacement = TextEditingController(text: 'second');
      harness.controllers.add(replacement);
      harness.controller = replacement;
      harness.rebuild();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.requests, ['first', 'second']);
      expect(harness.cancels, 1);
      original.text = 'ghost';
      harness.complete(0, ['obsolete controller']);
      harness.complete(1, ['replacement controller']);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        replacement,
      );
      expect(harness.changes, ['first']);
      expect(find.text('obsolete controller'), findsNothing);
      expect(find.text('replacement controller'), findsOneWidget);
      expect(harness.requests, ['first', 'second']);
      await _unmount(tester, harness);
    },
  );

  testWidgets('provider change retires old results and starts a fresh cache', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.enterText(find.byType(TextField), 'same');
    await tester.pump(const Duration(milliseconds: 300));
    harness.complete(0, ['old provider']);
    await tester.pumpAndSettle();
    expect(find.text('old provider'), findsOneWidget);
    harness.provider = (_) async => ['new provider'];
    harness.rebuild();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('old provider'), findsNothing);
    expect(find.text('new provider'), findsOneWidget);
    harness.enabled = false;
    harness.rebuild();
    await tester.pumpAndSettle();
    expect(harness.controller.text, 'same');
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
    expect(harness.cancels, 0);
    await _unmount(tester, harness);
  });

  testWidgets(
    'unfocused programmatic edits update clear button without queries',
    (tester) async {
      final harness = await _mount(tester);
      harness.controller.text = 'external';
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byTooltip('清空搜索'), findsOneWidget);
      expect(harness.requests, isEmpty);
      expect(harness.changes, isEmpty);
      harness.controller.clear();
      await tester.pump();
      expect(find.byTooltip('清空搜索'), findsNothing);
      expect(harness.cancels, 0);
      await _unmount(tester, harness);
    },
  );
  testWidgets(
    'parent rebuild keeps an identical provider request and cached results',
    (tester) async {
      final harness = await _mount(tester);
      await tester.enterText(find.byType(TextField), 'stable');
      await tester.pump(const Duration(milliseconds: 300));
      harness.rebuild();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.requests, ['stable']);
      expect(harness.cancels, 0);
      harness.complete(0, ['stable result']);
      await tester.pumpAndSettle();
      harness.rebuild();
      await tester.pumpAndSettle();
      expect(find.text('stable result'), findsOneWidget);
      expect(harness.requests, ['stable']);
      expect(harness.cancels, 0);
      await _unmount(tester, harness);
    },
  );
}
