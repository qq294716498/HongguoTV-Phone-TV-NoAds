import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/television_navigation.dart';
import 'package:duanju_app/catalog_filters.dart';
import 'package:duanju_app/catalog_sort.dart';
import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/search_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _TypingRepository extends FixtureRepository {
  final queries = <String>[];
  final suggestionQueries = <String>[];
  int suggestionCancels = 0;
  int catalogCancels = 0;
  bool paginate = false;
  List<Drama>? catalogItems;
  final held = <String, Completer<CatalogPage>>{};

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    queries.add(query);
    if (held.containsKey(query)) return held[query]!.future;
    return CatalogPage(
      catalogItems != null &&
              catalogItems!.every((item) => item.source == source)
          ? catalogItems!
          : [
              for (var index = 0; index < 1000; index++)
                Drama(
                  id: '$source:$query:$index',
                  source: source,
                  title:
                      'Synthetic drama ${(1000 - index).toString().padLeft(4, '0')}',
                  category: 'Synthetic',
                ),
            ],
      hasMore: paginate && page < 3,
    );
  }

  @override
  Future<void> cancelCatalog() async => catalogCancels++;

  @override
  Future<List<String>> suggestions(String query) async {
    suggestionQueries.add(query);
    return [];
  }

  @override
  Future<void> cancelSuggestions() async => suggestionCancels++;
}

Future<LocalStore> _mountHome(
  WidgetTester tester,
  _TypingRepository repository, {
  String source = 'hongguo',
  bool openSearch = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(await gatePreferences());
  final store = testStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  await unlockGate(store);
  await store.setSource(source);
  await store.setCatalogView(const CatalogView(sort: CatalogSort.name));
  await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
  await tester.pumpAndSettle();
  if (openSearch) {
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
  }
  return store;
}

const _localItems = [
  Drama(
    id: 'huangdou:local-first',
    source: 'huangdou',
    title: 'Synthetic drama 0001',
  ),
  Drama(
    id: 'huangdou:local-match',
    source: 'huangdou',
    title: 'Synthetic drama 0999',
  ),
];

class _CountedDrama extends Drama {
  _CountedDrama(int index)
    : super(
        id: 'hongguo:count-$index',
        source: 'hongguo',
        title: 'Synthetic ${(1000 - index).toString().padLeft(4, '0')}',
      );
  static int reads = 0;
  @override
  String get title {
    reads++;
    return super.title;
  }
}

void main() {
  testWidgets('opening search and keyboard insets reuse the sorted catalog', (
    tester,
  ) async {
    _CountedDrama.reads = 0;
    final repository = _TypingRepository()
      ..catalogItems = List.generate(1000, _CountedDrama.new);
    await _mountHome(tester, repository, openSearch: false);
    final initialReads = _CountedDrama.reads;
    expect(initialReads, greaterThan(1000));
    final requests = repository.queries.length;
    _CountedDrama.reads = 0;
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    for (final inset in [100.0, 200.0, 300.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
    }
    expect(find.byType(SearchInput), findsOneWidget);
    expect(repository.queries.length, requests);
    expect(_CountedDrama.reads, lessThan(500));
    debugPrint(
      'search-open-metrics initialTitleReads=$initialReads openAndKeyboardTitleReads=${_CountedDrama.reads} extraRequests=${repository.queries.length - requests}',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing sort invalidates the visible catalog cache', (
    tester,
  ) async {
    final repository = _TypingRepository()
      ..catalogItems = List.generate(20, _CountedDrama.new);
    final store = await _mountHome(tester, repository, openSearch: false);
    _CountedDrama.reads = 0;
    await store.setCatalogView(const CatalogView(sort: CatalogSort.season));
    await tester.pumpAndSettle();
    expect(_CountedDrama.reads, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ten rapid keys keep a sorted 1000-item home catalog idle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setCatalogView(const CatalogView(sort: CatalogSort.name));
    final repository = _TypingRepository();
    await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    var homeBuilds = 0, filterBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, once) {
      previous?.call(element, once);
      if (element.widget is HomeScreen) homeBuilds++;
      if (element.widget is CatalogFilters) filterBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    repository.suggestionCancels = 0;
    const text = 'abcdefghij';
    for (var length = 1; length <= text.length; length++) {
      await tester.enterText(find.byType(TextField), text.substring(0, length));
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = previous;
    debugPrint(
      'typing-metrics keys=10 items=1000 homeBuilds=$homeBuilds '
      'filterBuilds=$filterBuilds suggestionCancels=${repository.suggestionCancels}',
    );
    expect(homeBuilds, 0);
    expect(filterBuilds, 0);
    expect(repository.suggestionCancels, 0);
    expect(repository.queries, ['']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('debouncing without a running suggestion never cancels backend', (
    tester,
  ) async {
    final controller = TextEditingController();
    final queries = <String>[];
    var cancels = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            controller: controller,
            hint: 'Search',
            suggestions: (query) async {
              queries.add(query);
              return [];
            },
            onCancel: () => cancels++,
            onSearch: (_) {},
          ),
        ),
      ),
    );
    for (final text in ['a', 'ab', 'abc', 'ab', 'a', '']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 40));
    }
    debugPrint(
      'suggestion-metrics requests=${queries.length} cancels=$cancels',
    );
    expect(queries, isEmpty);
    expect(cancels, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('same-text IME commit displays suggestions after composing', (
    tester,
  ) async {
    final controller = TextEditingController();
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            controller: controller,
            hint: 'Search',
            suggestions: (query) async {
              queries.add(query);
              return ['合成结果'];
            },
            onSearch: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(queries, isEmpty);
    expect(controller.value.composing, const TextRange(start: 0, end: 2));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(queries, ['中文']);
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('editing invalidates an online search before its late response', (
    tester,
  ) async {
    final repository = _TypingRepository();
    await _mountHome(tester, repository);
    repository.held['old'] = Completer<CatalogPage>();
    repository.held['new'] = Completer<CatalogPage>();
    await tester.enterText(find.byType(TextField), 'old');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 50));
    final beforeCancel = repository.catalogCancels;
    await tester.enterText(find.byType(TextField), 'n');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 20));
    expect(repository.catalogCancels - beforeCancel, 1);
    repository.held['old']!.complete(
      CatalogPage([
        const Drama(
          id: 'hongguo:old-result',
          source: 'hongguo',
          title: 'obsolete search result',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('obsolete search result'), findsNothing);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 50));
    repository.held['new']!.complete(
      CatalogPage([
        const Drama(
          id: 'hongguo:new-result',
          source: 'hongguo',
          title: 'accepted new result',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('accepted new result'), findsOneWidget);
    expect(find.text('obsolete search result'), findsNothing);
    expect(repository.queries, ['', 'old', 'new']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'scrolling cannot submit an uncommitted draft as a catalog page',
    (tester) async {
      final repository = _TypingRepository()..paginate = true;
      await _mountHome(tester, repository);
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.pump(const Duration(milliseconds: 50));
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.queries, ['']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'local filtering waits for composition and clears on source change',
    (tester) async {
      final repository = _TypingRepository()..catalogItems = _localItems;
      final store = await _mountHome(tester, repository, source: 'huangdou');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '999',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await store.setHideVip(true);
      await tester.pump();
      expect(find.text('Synthetic drama 0001'), findsOneWidget);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '999',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump(const Duration(milliseconds: 179));
      expect(find.text('Synthetic drama 0001'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic drama 0999'), findsOneWidget);
      expect(find.text('Synthetic drama 0001'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<SourceGroup>, '红果'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.text('Synthetic drama 0001'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    skip: !allSourcesEnabled,
  );
  testWidgets('TV back clears a submitted local filter and rebuilds results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      TelevisionNavigation.channel,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        TelevisionNavigation.channel,
        null,
      ),
    );
    SharedPreferences.setMockInitialValues(await gatePreferences());
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await unlockGate(store);
    await store.setSource('huangdou');
    await store.setCatalogView(const CatalogView(sort: CatalogSort.name));
    final repository = _TypingRepository()..catalogItems = _localItems;
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: store, television: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    for (var index = 0; index < 3; index++) {
      await tester.tap(find.byKey(const ValueKey('tv-key-9')));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(RemoteButton, '搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic drama 0999'), findsOneWidget);
    expect(find.text('Synthetic drama 0001'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Synthetic drama 0001'), findsOneWidget);
    expect(find.text('Synthetic drama 0999'), findsOneWidget);
    expect(find.text('退出红果TV？'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, skip: !allSourcesEnabled);
}
