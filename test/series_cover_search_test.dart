import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/episode_browser.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/search_input.dart';
import 'package:duanju_app/series_browser_screen.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class CoverSeriesRepository extends FixtureRepository {
  CoverSeriesRepository({int seasons = 5, this.longTitle = false}) {
    dramas = [
      for (var season = 1; season <= seasons; season++)
        Drama(
          id: 'hongguo:cover-season-$season',
          source: 'hongguo',
          seriesGroupId: 'cover-series',
          title:
              '${longTitle ? '合成故事 Synthetic Adventures 与非常长的标题用于验证大字体边界' : '合成故事 Synthetic Adventures'} 第$season季',
          episodes: season == 1 ? 60 : 10 + season,
        ),
    ];
  }

  final bool longTitle;
  late final List<Drama> dramas;
  final catalogQueries = <(String, int, bool)>[];
  final detailed = <String>[];
  final suggestionQueries = <String>[];
  int catalogCancels = 0;
  int suggestionCancels = 0;

  DramaDetail makeDetail(Drama drama) => DramaDetail(drama, [
    for (var number = 1; number <= drama.episodes; number++)
      Episode({'id': '${drama.id}:$number', 'currentEpisode': number}, number),
  ]);

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    catalogQueries.add((query, page, force));
    return CatalogPage([
      ...dramas,
      const Drama(
        id: 'hongguo:unrelated-cover-season-2',
        source: 'hongguo',
        seriesGroupId: 'another-series',
        title: '另一个故事 第2季',
        episodes: 80,
      ),
      const Drama(
        id: 'huangdou:copy-cover-season-2',
        source: 'huangdou',
        seriesGroupId: 'cover-series',
        title: '合成故事 Synthetic Adventures 第2季',
        episodes: 80,
      ),
    ]);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailed.add(drama.id);
    return makeDetail(drama);
  }

  @override
  Future<List<String>> suggestions(String query) async {
    suggestionQueries.add(query);
    return const [];
  }

  @override
  Future<void> cancelCatalog() async => catalogCancels++;

  @override
  Future<void> cancelSuggestions() async => suggestionCancels++;

  List<Object> get traffic => [
    List.of(catalogQueries),
    List.of(detailed),
    List.of(suggestionQueries),
    catalogCancels,
    suggestionCancels,
  ];
}

void main() {
  final geometry = <Map<String, Object>>[];
  final originalImageSetting = DramaCover.imagesDisabled;

  setUpAll(() async {
    DramaCover.imagesDisabled = true;
    for (final entry in [
      ('HG_UI_FONT', 'Roboto'),
      ('HG_UI_ICON_FONT', 'MaterialIcons'),
    ]) {
      final path = Platform.environment[entry.$1];
      if (path == null) continue;
      await (FontLoader(entry.$2)..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          ))
          .load();
    }
  });

  tearDownAll(() async {
    DramaCover.imagesDisabled = originalImageSetting;
    final output = Platform.environment['HG_SERIES_GEOMETRY'];
    if (output != null) {
      await File(output).parent.create(recursive: true);
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(geometry));
    }
  });

  Future<LocalStore> local() async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setSource('hongguo');
    return store;
  }

  void viewport(WidgetTester tester, Size size, {double scale = 1}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  ThemeData validationTheme(bool television) {
    final base = ThemeData.dark();
    final theme = television ? televisionTheme(base) : base;
    if (Platform.environment['HG_UI_FONT'] == null) return theme;
    final textButtons = theme.textButtonTheme.style;
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Roboto'),
      textButtonTheme: TextButtonThemeData(
        style: textButtons?.copyWith(
          textStyle: WidgetStateProperty.resolveWith(
            (states) =>
                (textButtons.textStyle?.resolve(states) ?? const TextStyle())
                    .copyWith(fontFamily: 'Roboto'),
          ),
        ),
      ),
    );
  }

  Future<void> mount(
    WidgetTester tester,
    CoverSeriesRepository repository,
    LocalStore store, {
    bool television = false,
    int anchorIndex = 0,
    void Function(SeriesEpisodeSelection?)? onResult,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('series-cover-capture'),
        child: MaterialApp(
          theme: validationTheme(television),
          builder: (_, child) => AppLayout(
            television: television,
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
              },
              child: FocusTraversalGroup(child: child!),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                child: const Text('打开全季测试'),
                onPressed: () async {
                  final selection = await Navigator.of(context)
                      .push<SeriesEpisodeSelection>(
                        MaterialPageRoute(
                          builder: (_) => SeriesBrowserScreen(
                            anchor: repository.dramas[anchorIndex],
                            repository: repository,
                            store: store,
                            initialDetail: repository.makeDetail(
                              repository.dramas[anchorIndex],
                            ),
                            currentEpisode: 2,
                          ),
                        ),
                      );
                  onResult?.call(selection);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开全季测试'));
    await tester.pumpAndSettle();
  }

  Finder card(int season) =>
      find.byKey(ValueKey('all-season-hongguo:cover-season-$season'));

  Finder cover(int season) =>
      find.byKey(ValueKey('all-season-cover-hongguo:cover-season-$season'));

  Finder input() => find.descendant(
    of: find.byKey(const ValueKey('all-seasons-search')),
    matching: find.byType(TextField),
  );

  Finder details(int season) =>
      find.byKey(ValueKey('all-season-episodes-hongguo:cover-season-$season'));

  Future<void> type(
    WidgetTester tester,
    String value, {
    Duration wait = const Duration(milliseconds: 180),
  }) async {
    await tester.enterText(input(), value);
    await tester.pump(wait);
  }

  void expectNoRemoteTraffic(
    CoverSeriesRepository repository,
    List<Object> initial,
  ) => expect(repository.traffic, initial);

  bool fullyVisible(Rect rect, Rect viewport) =>
      rect.width > 0 &&
      rect.height > 0 &&
      rect.left >= viewport.left - .5 &&
      rect.right <= viewport.right + .5 &&
      rect.top >= viewport.top - .5 &&
      rect.bottom <= viewport.bottom + .5;

  bool remoteFocused(WidgetTester tester, Finder item) {
    final detector = find.descendant(
      of: item,
      matching: find.byType(FocusableActionDetector),
    );
    if (detector.evaluate().isEmpty) return false;
    final container = find.descendant(
      of: detector.first,
      matching: find.byType(AnimatedContainer),
    );
    return container.evaluate().isNotEmpty &&
        Focus.of(tester.element(container.first)).hasFocus;
  }

  bool focusedWithin(Finder finder) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null || finder.evaluate().isEmpty) return false;
    final target = finder.evaluate().single;
    var found = identical(focusContext, target);
    focusContext.visitAncestorElements((element) {
      found = found || identical(element, target);
      return !found;
    });
    return found;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (output == null) return;
    await tester.runAsync(() async {
      await Directory(output).create(recursive: true);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('series-cover-capture')),
      );
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'all-season cards retain covers, season labels and local selection',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = CoverSeriesRepository();
      final store = await local();
      await mount(tester, repository, store);
      expect(find.byType(SearchInput), findsOneWidget);
      expect(
        tester.widget<TextField>(input()).decoration!.hintText,
        '搜索本系列标题或季号',
      );
      expect(cover(1), findsOneWidget);
      expect(
        find.descendant(of: card(1), matching: find.text('第 1 季')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(1), matching: find.text('共 60 集')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('all-season-hongguo:unrelated-cover-season-2'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('all-season-huangdou:copy-cover-season-2')),
        findsNothing,
      );
      expect(details(1), findsOneWidget);
      expect(find.byKey(const ValueKey('all-seasons-refresh')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final spec in [
    ('2', 2),
    ('第2季', 2),
    ('第二季', 2),
    ('4', 4),
    ('第4季', 4),
    ('第四季', 4),
    ('合成故事 Synthetic Adventures 第1季', 1),
    ('合成故事 Synthetic Adventures 第四季', 4),
  ]) {
    testWidgets(
      'local season filter recognizes ${spec.$1} without catalog work',
      (tester) async {
        viewport(tester, const Size(390, 844));
        final repository = CoverSeriesRepository(seasons: 40);
        final store = await local();
        await mount(tester, repository, store);
        final traffic = repository.traffic;
        await type(tester, spec.$1);
        expect(card(spec.$2), findsOneWidget);
        expect(card(spec.$2 == 1 ? 2 : 1), findsNothing);
        expect(card(spec.$2 + 10), findsNothing);
        expect(card(40), findsNothing);
        expect(details(1), findsOneWidget);
        expectNoRemoteTraffic(repository, traffic);
      },
    );
  }

  for (final query in ['第二季', 'missing']) {
    testWidgets('IME composing $query stays intact until same-text commit', (
      tester,
    ) async {
      viewport(tester, const Size(390, 844));
      final repository = CoverSeriesRepository();
      final store = await local();
      await mount(tester, repository, store);
      final traffic = repository.traffic;
      await tester.tap(input());
      await tester.showKeyboard(input());
      final composing = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
        composing: TextRange(start: 0, end: query.length),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TextField>(input()).controller!.value, composing);
      expect(card(1), findsOneWidget);
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump(const Duration(milliseconds: 179));
      expect(card(1), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(card(1), findsNothing);
      if (query == '第二季') {
        expect(card(2), findsOneWidget);
      } else {
        expect(find.text('本系列中未找到匹配的季'), findsOneWidget);
      }
      expect(details(1), findsOneWidget);
      expectNoRemoteTraffic(repository, traffic);
    });
  }

  testWidgets(
    'rapid typing, deletion and clearing only apply the latest query',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = CoverSeriesRepository();
      final store = await local();
      await mount(tester, repository, store);
      final traffic = repository.traffic;
      await type(tester, '2', wait: const Duration(milliseconds: 100));
      await type(tester, '3', wait: const Duration(milliseconds: 100));
      expect(card(1), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 80));
      expect(card(2), findsNothing);
      expect(card(3), findsOneWidget);
      await type(tester, '30');
      expect(find.text('本系列中未找到匹配的季'), findsOneWidget);
      await type(tester, '3');
      expect(card(3), findsOneWidget);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
      expect(card(1), findsOneWidget);
      expect(find.text('本系列中未找到匹配的季'), findsNothing);
      await type(tester, '2', wait: const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(card(1), findsOneWidget);
      expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
      expectNoRemoteTraffic(repository, traffic);
    },
  );

  testWidgets('explicit submit applies immediately and accepts a title query', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final repository = CoverSeriesRepository();
    final store = await local();
    await mount(tester, repository, store);
    final traffic = repository.traffic;
    await type(tester, '第3季', wait: Duration.zero);
    expect(card(1), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(card(3), findsOneWidget);
    expect(card(1), findsNothing);
    await type(tester, 'synthetic adventures');
    expect(card(1), findsOneWidget);
    expect(find.text('本系列中未找到匹配的季'), findsNothing);
    expectNoRemoteTraffic(repository, traffic);
  });

  testWidgets(
    'filtering preserves selected detail, current episode and watch history',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = CoverSeriesRepository();
      final store = await local();
      await store.saveWatch(
        WatchEntry(
          drama: repository.dramas[2],
          episode: 4,
          position: 15,
          duration: 60,
          updatedAt: DateTime.utc(2026, 11, 1),
        ),
      );
      SeriesEpisodeSelection? selection;
      await mount(
        tester,
        repository,
        store,
        onResult: (value) => selection = value,
      );
      await tester.ensureVisible(card(3));
      await tester.tap(card(3));
      await tester.pumpAndSettle();
      expect(details(3), findsOneWidget);
      expect(tester.widget<RemoteTarget>(card(3)).selected, true);
      final fourth = find.byKey(const ValueKey('all-season-episode-4'));
      expect(tester.widget<RemoteEpisodeButton>(fourth).current, true);
      final traffic = repository.traffic;
      await type(tester, '1');
      expect(card(3), findsNothing);
      expect(card(1), findsOneWidget);
      expect(find.text('当前选集：第 3 季'), findsOneWidget);
      expect(details(3), findsOneWidget);
      expect(tester.widget<RemoteEpisodeButton>(fourth).current, true);
      expect(store.watched(repository.dramas[2].id)!.position, 15);
      expectNoRemoteTraffic(repository, traffic);
      await tester.tap(fourth);
      await tester.pumpAndSettle();
      expect(selection!.detail.drama.id, repository.dramas[2].id);
      expect(selection!.index, 3);
    },
  );

  testWidgets(
    'a large season set builds covers lazily and remains locally searchable',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = CoverSeriesRepository(seasons: 200);
      final store = await local();
      await mount(tester, repository, store);
      final initialCovers = find.byType(DramaCover).evaluate().length;
      expect(initialCovers, greaterThan(0));
      expect(initialCovers, lessThan(20));
      expect(cover(200), findsNothing);
      final traffic = repository.traffic;
      await type(tester, '200');
      expect(cover(200), findsOneWidget);
      expect(card(1), findsNothing);
      expect(details(1), findsOneWidget);
      expectNoRemoteTraffic(repository, traffic);
    },
  );

  testWidgets(
    'TV arrows reach offscreen seasons and return from episodes to the active card',
    (tester) async {
      viewport(tester, const Size(960, 540));
      final repository = CoverSeriesRepository(seasons: 40);
      final store = await local();
      await mount(tester, repository, store, television: true);
      focusRemote(tester, card(1));
      await tester.pumpAndSettle();
      for (var step = 0; step < 12; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      expect(card(13), findsOneWidget);
      expect(remoteFocused(tester, card(13)), true);
      final screen = Offset.zero & tester.view.physicalSize;
      expect(fullyVisible(tester.getRect(card(13)), screen), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(details(13), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        focusedWithin(details(13)),
        true,
        reason: 'Down enters the episode controls',
      );
      bool episodeFocused() => tester
          .widgetList<RemoteEpisodeButton>(find.byType(RemoteEpisodeButton))
          .any((button) => button.focusNode?.hasFocus ?? false);
      if (!episodeFocused()) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        episodeFocused(),
        true,
        reason: 'episode controls provide a Down path to episode buttons',
      );
      for (var step = 0; step < 3 && !remoteFocused(tester, card(13)); step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(remoteFocused(tester, card(13)), true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV large-text split layout links season cards and episode controls',
    (tester) async {
      viewport(tester, const Size(960, 540), scale: 1.5);
      final repository = CoverSeriesRepository(seasons: 40, longTitle: true);
      final store = await local();
      await mount(tester, repository, store, television: true);
      final traffic = repository.traffic;
      focusRemote(tester, card(1));
      await tester.pumpAndSettle();
      for (var step = 0; step < 3 && !focusedWithin(details(1)); step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        focusedWithin(details(1)),
        true,
        reason: 'Down links the season column to episode controls',
      );
      for (var step = 0; step < 3; step++) {
        if (FocusManager.instance.primaryFocus?.debugLabel?.startsWith(
              'series-season-',
            ) ??
            false) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('series-season-'),
      );
      expect(details(1), findsOneWidget);
      expect(tester.widget<RemoteTarget>(card(1)).selected, true);
      expectNoRemoteTraffic(repository, traffic);
      expect(tester.takeException(), isNull);
    },
  );

  for (final television in [false, true]) {
    testWidgets(
      'initial selected season is visible beyond the first viewport (TV $television)',
      (tester) async {
        viewport(
          tester,
          television ? const Size(960, 540) : const Size(390, 844),
        );
        final repository = CoverSeriesRepository(seasons: 40);
        final store = await local();
        await mount(
          tester,
          repository,
          store,
          television: television,
          anchorIndex: 12,
        );
        expect(card(13), findsOneWidget);
        expect(tester.widget<RemoteTarget>(card(13)).selected, true);
        if (television) {
          expect(
            remoteFocused(tester, card(13)),
            true,
            reason:
                'actual initial focus: ${FocusManager.instance.primaryFocus?.debugLabel} ${FocusManager.instance.primaryFocus?.context?.widget}',
          );
        }
        expect(details(13), findsOneWidget);
        expect(
          fullyVisible(
            tester.getRect(card(13)),
            Offset.zero & tester.view.physicalSize,
          ),
          true,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('TV back finishes editing before leaving the series page', (
    tester,
  ) async {
    viewport(tester, const Size(960, 540));
    final repository = CoverSeriesRepository();
    final store = await local();
    await mount(tester, repository, store, television: true);
    await tester.tap(input());
    await tester.pump();
    expect(tester.widget<TextField>(input()).readOnly, false);
    await type(tester, '第2季');
    expect(card(2), findsOneWidget);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeriesBrowserScreen), findsOneWidget);
    expect(tester.widget<TextField>(input()).readOnly, true);
    expect(tester.widget<TextField>(input()).controller!.text, '第2季');
    expect(
      FocusManager.instance.primaryFocus!.debugLabel,
      'tv-search-navigation',
    );
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeriesBrowserScreen), findsNothing);
    expect(find.text('打开全季测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final spec in [
    (const Size(320, 640), 280.0, 1.0),
    (const Size(390, 844), 320.0, 1.0),
    (const Size(844, 390), 250.0, 1.0),
    (const Size(320, 640), 280.0, 1.5),
    (const Size(844, 390), 250.0, 1.5),
  ]) {
    testWidgets(
      'mobile keyboard keeps series input usable at ${spec.$1} scale ${spec.$3}',
      (tester) async {
        viewport(tester, spec.$1, scale: spec.$3);
        final repository = CoverSeriesRepository(longTitle: true);
        final store = await local();
        await mount(tester, repository, store);
        final traffic = repository.traffic;
        await tester.tap(input());
        tester.view.viewInsets = FakeViewPadding(bottom: spec.$2);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'keyboard opening');
        expect(input().hitTestable(), findsOneWidget);
        await type(tester, '2');
        expect(
          tester.takeException(),
          isNull,
          reason: 'filtering while editing',
        );
        await capture(
          tester,
          'series-cover-keyboard-${spec.$1.width.toInt()}-${spec.$1.height.toInt()}-${spec.$3}',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'search submission');
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        expect(card(2), findsOneWidget);
        expect(details(1), findsOneWidget);
        expect(tester.widget<EpisodeBrowser>(details(1)).currentNumber, 2);
        expectNoRemoteTraffic(repository, traffic);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final spec in [
    ('phone320', const Size(320, 640), false, 1.0, TargetPlatform.android),
    (
      'phone320-large',
      const Size(320, 640),
      false,
      1.5,
      TargetPlatform.android,
    ),
    (
      'phone390-large',
      const Size(390, 844),
      false,
      1.3,
      TargetPlatform.android,
    ),
    (
      'phone-landscape',
      const Size(844, 390),
      false,
      1.0,
      TargetPlatform.android,
    ),
    (
      'phone-landscape-large',
      const Size(844, 390),
      false,
      1.5,
      TargetPlatform.android,
    ),
    ('tv720-large', const Size(960, 540), true, 1.5, TargetPlatform.android),
    ('tv1080', const Size(1280, 720), true, 1.0, TargetPlatform.android),
    (
      'desktop-large',
      const Size(1280, 720),
      false,
      1.3,
      TargetPlatform.windows,
    ),
  ]) {
    testWidgets(
      'cover search leaves readable cards and usable episodes at ${spec.$1}',
      (tester) async {
        viewport(tester, spec.$2, scale: spec.$4);
        final repository = CoverSeriesRepository(longTitle: true);
        final store = await local();
        await mount(tester, repository, store, television: spec.$3);
        final screen = Offset.zero & spec.$2;
        final coverRect = tester.getRect(cover(1));
        final seasonRect = tester.getRect(
          find.descendant(of: card(1), matching: find.text('第 1 季')),
        );
        final countRect = tester.getRect(
          find.descendant(of: card(1), matching: find.text('共 60 集')),
        );
        expect(
          fullyVisible(coverRect, screen),
          true,
          reason: 'complete season cover',
        );
        expect(coverRect.width, greaterThanOrEqualTo(64));
        expect(coverRect.height, greaterThanOrEqualTo(64));
        expect(
          fullyVisible(seasonRect, screen),
          true,
          reason: 'season label visible',
        );
        expect(
          fullyVisible(countRect, screen),
          true,
          reason: 'episode count visible',
        );
        final episodeArea = tester
            .getRect(find.byType(EpisodeBrowser))
            .intersect(screen);
        final fullEpisodes = find.byType(RemoteEpisodeButton).evaluate().where((
          element,
        ) {
          final rect = tester.getRect(find.byWidget(element.widget));
          return fullyVisible(rect, episodeArea);
        }).toList();
        expect(
          fullEpisodes,
          isNotEmpty,
          reason: 'at least one complete episode target',
        );
        final firstEpisodeRect = tester.getRect(
          find.byWidget(fullEpisodes.first.widget),
        );
        expect(firstEpisodeRect.width, greaterThanOrEqualTo(44));
        expect(firstEpisodeRect.height, greaterThanOrEqualTo(44));
        expect(
          find.byKey(const ValueKey('all-seasons-refresh')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        geometry.add({
          'name': spec.$1,
          'width': spec.$2.width,
          'height': spec.$2.height,
          'television': spec.$3,
          'textScale': spec.$4,
          'cover': [
            coverRect.left,
            coverRect.top,
            coverRect.width,
            coverRect.height,
          ],
          'season': [
            seasonRect.left,
            seasonRect.top,
            seasonRect.width,
            seasonRect.height,
          ],
          'episodesArea': [
            episodeArea.left,
            episodeArea.top,
            episodeArea.width,
            episodeArea.height,
          ],
          'completeEpisodeButtons': fullEpisodes.length,
        });
        await capture(tester, 'series-cover-${spec.$1}');
      },
      variant: TargetPlatformVariant.only(spec.$5),
    );
  }
}
