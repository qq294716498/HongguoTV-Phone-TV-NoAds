import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/downloads_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:duanju_app/search_input.dart';
import 'package:duanju_app/television_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show DownloadRepository;
import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  setUp(mockPlayerDevice);

  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final result = testStore(await SharedPreferences.getInstance());
    addTearDown(result.dispose);
    return result;
  }

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool physicalTv = true,
    bool tvLayout = true,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.android),
        builder: (_, child) => AppLayout(
          television: tvLayout,
          deviceTelevision: physicalTv,
          child: FocusTraversalGroup(child: child!),
        ),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> browseThenEdit(WidgetTester tester) async {
    final field = find.byType(TextField);
    final editor = tester.widget<TextField>(field);
    final nav = find
        .ancestor(of: field, matching: find.byType(Focus))
        .evaluate()
        .map((e) => (e.widget as Focus).focusNode)
        .whereType<FocusNode>()
        .firstWhere((n) => n.debugLabel == 'tv-search-navigation');
    nav.requestFocus();
    await tester.pumpAndSettle();
    expect(editor.readOnly, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(nav)));
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    nav.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    expect(tester.testTextInput.isVisible, isTrue);
    final editing = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(editing));
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(FocusManager.instance.primaryFocus, same(nav));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(nav)));
  }

  for (final tvLayout in [false, true]) {
    for (final history in [false, true]) {
      testWidgets(
        'TV saved search navigation history=$history layout=$tvLayout',
        (tester) async {
          final local = await store();
          await local.toggleFavorite(FixtureRepository.free);
          await local.saveWatch(
            WatchEntry(
              drama: FixtureRepository.free,
              episode: 1,
              position: 10,
              duration: 120,
              updatedAt: DateTime(2026),
            ),
          );
          await mount(
            tester,
            SavedLibrary(
              repository: FixtureRepository(),
              store: local,
              history: history,
              onOpen: (_) {},
              onContinue: (_) {},
            ),
            tvLayout: tvLayout,
          );
          await browseThenEdit(tester);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
    testWidgets('TV downloads search navigation layout=$tvLayout', (
      tester,
    ) async {
      final local = await store();
      final repository = DownloadRepository();
      repository.jobs = [repository.job(1, 'completed')];
      await mount(
        tester,
        DownloadsScreen(repository: repository, store: local),
        tvLayout: tvLayout,
      );
      await browseThenEdit(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'TV autocomplete retains composing and candidate arrows, then releases navigation',
    (tester) async {
      final controller = TextEditingController();
      final searches = <String>[];
      await mount(
        tester,
        Column(
          children: [
            SearchInput(
              controller: controller,
              hint: '合成搜索',
              autofocus: true,
              onSearch: searches.add,
              suggestions: (_) async => ['合成甲', '合成乙'],
            ),
            FilledButton(onPressed: () {}, child: const Text('下方内容')),
          ],
        ),
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '合',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
      await tester.enterText(find.byType(TextField), '合成');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final editing = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(editing));
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('search-suggestion-1')))
            .selected,
        isTrue,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(searches, ['合成乙']);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('physical TV standard home keeps remote browse focus', (
    tester,
  ) async {
    final local = await store();
    await local.setDisplayMode('standard');
    await tester.pumpWidget(
      DuanjuApp(
        repository: FixtureRepository(),
        store: local,
        television: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    expect(find.byType(TelevisionSearchField), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'tv-search-navigation',
    );
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('tv-search-navigation'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'TV dismissing visible IME insets restores browse mode without a back key',
    (tester) async {
      final controller = TextEditingController();
      await mount(
        tester,
        Column(
          children: [
            TelevisionSearchField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '搜索'),
            ),
            FilledButton(onPressed: () {}, child: const Text('下方内容')),
          ],
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-search-navigation',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('tv-search-navigation'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('phone and Windows keep ordinary editable search behavior', (
    tester,
  ) async {
    for (final tvLayout in [false, true]) {
      final controller = TextEditingController();
      await mount(
        tester,
        TelevisionSearchField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '搜索'),
        ),
        physicalTv: false,
        tvLayout: tvLayout,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });
}
