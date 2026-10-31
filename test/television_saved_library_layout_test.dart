import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class SavedTelevisionRepository extends FixtureRepository {
  final dramas = List.generate(
    30,
    (index) => Drama(
      id: 'hongguo:tv-saved-$index',
      source: 'hongguo',
      title:
          '${index == 29 ? '特选末尾' : '合成剧目${index.toString().padLeft(2, '0')}'}：长标题遥控浏览与观看记录示例 第一季',
      episodes: 120,
      vip: index == 0,
      seriesGroupId: '${10000 + index}',
    ),
  );
  final opened = <String>[];
  int followRequests = 0;
  bool failFollow = false;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    if (query.isNotEmpty) {
      followRequests++;
      if (failFollow) throw AppFailure('合成检查错误');
      return CatalogPage([], hasMore: false);
    }
    return CatalogPage([dramas.first], hasMore: false);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    opened.add(drama.id);
    return DramaDetail(
      drama,
      List.generate(
        120,
        (index) => Episode({
          'id': '${drama.id}-${index + 1}',
          'currentEpisode': index + 1,
          'vip': true,
        }, index + 1),
      ),
    );
  }
}

class SavedViewportMeasurement {
  SavedViewportMeasurement(
    this.viewport,
    this.completeRows,
    this.visibleRows,
    this.completeCards,
  );
  final Rect viewport;
  final List<double> completeRows;
  final List<double> visibleRows;
  final int completeCards;

  Map<String, Object> toJson() => {
    'viewport': {
      'left': viewport.left,
      'top': viewport.top,
      'width': viewport.width,
      'height': viewport.height,
    },
    'completeRows': completeRows.length,
    'completeCards': completeCards,
    'visibleRowsIncludingClipped': visibleRows.length,
    'completeRowTops': completeRows,
  };
}

void main() {
  final baseline = Platform.environment['HG_TV_BASELINE'] == 'true';

  setUpAll(() async {
    final font = Platform.environment['HG_UI_FONT'];
    if (font != null) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())),
          ))
          .load();
    }
    final icons = Platform.environment['HG_UI_ICON_FONT'];
    if (icons != null) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await File(icons).readAsBytes())),
          ))
          .load();
    }
  });

  void viewport(WidgetTester tester, Size logical, double scale) {
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<LocalStore> local(SavedTelevisionRepository repository) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setThemeMode('dark');
    for (final drama in repository.dramas) {
      await store.toggleFavorite(drama);
    }
    await store.saveWatch(
      WatchEntry(
        drama: repository.dramas.first,
        episode: 37,
        position: 79,
        duration: 180,
        updatedAt: DateTime.utc(2026, 10, 31),
      ),
    );
    final first = repository.dramas.first;
    await store.applySeasonCheck(
      followed: first,
      anchor: first,
      resolvedAnchor: first,
      next: Drama(
        id: '${first.id}-next',
        source: first.source,
        title: first.title.replaceFirst('第一季', '第二季'),
        episodes: 120,
        seriesGroupId: first.seriesGroupId,
      ),
      complete: true,
      isCurrent: () => true,
    );
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    LocalStore store,
    SavedTelevisionRepository repository, {
    bool television = true,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('saved-capture'),
        child: DuanjuApp(
          repository: repository,
          store: store,
          television: television,
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (television) {
      focusRemote(tester, find.byKey(const ValueKey('tv-nav-1')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    } else {
      await tester.tap(find.byIcon(Icons.bookmark_border_rounded).first);
    }
    await tester.pumpAndSettle();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pumpAndSettle();
    expect(find.byType(SavedLibrary), findsOneWidget);
  }

  Finder savedGrid() => find.descendant(
    of: find.byType(SavedLibrary),
    matching: find.byType(RemoteGrid),
  );

  SavedViewportMeasurement measure(
    WidgetTester tester,
    SavedTelevisionRepository repository,
  ) {
    final grid = tester.getRect(savedGrid());
    final screen = Offset.zero & tester.view.physicalSize;
    final viewport = grid.intersect(screen);
    final full = <double>{};
    var completeCards = 0;
    final visible = <double>{};
    for (final drama in repository.dramas) {
      final finder = find.byKey(ValueKey('saved-${drama.id}'));
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      if (!rect.overlaps(viewport)) continue;
      final y = (rect.top * 10).round() / 10;
      visible.add(y);
      if (rect.top >= viewport.top - .5 &&
          rect.bottom <= viewport.bottom + .5 &&
          rect.left >= viewport.left - .5 &&
          rect.right <= viewport.right + .5) {
        full.add(y);
        completeCards++;
      }
    }
    return SavedViewportMeasurement(
      viewport,
      full.toList()..sort(),
      visible.toList()..sort(),
      completeCards,
    );
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('saved-capture')),
    );
    await tester.runAsync(() async {
      await Directory(directory).create(recursive: true);
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  FocusNode searchNavigation(WidgetTester tester) => find
      .ancestor(
        of: find.descendant(
          of: find.byKey(const ValueKey('favorites-search')),
          matching: find.byType(TextField),
        ),
        matching: find.byType(Focus),
      )
      .evaluate()
      .map((element) => (element.widget as Focus).focusNode)
      .whereType<FocusNode>()
      .firstWhere((node) => node.debugLabel == 'tv-search-navigation');

  bool remoteHasFocus(WidgetTester tester, Finder finder) {
    if (finder.evaluate().isEmpty) return false;
    final detector = find
        .descendant(of: finder, matching: find.byType(FocusableActionDetector))
        .first;
    final container = find
        .descendant(of: detector, matching: find.byType(AnimatedContainer))
        .first;
    return Focus.of(tester.element(container)).hasFocus;
  }

  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(1920, 1080),
  ]) {
    for (final scale in [1.0, 1.3, 1.5]) {
      testWidgets('TV saved complete rows at $size scale $scale', (
        tester,
      ) async {
        viewport(tester, size, scale);
        final repository = SavedTelevisionRepository();
        final store = await local(repository);
        await mount(tester, store, repository);
        final result = measure(tester, repository);
        debugPrint(
          'TV_SAVED_GEOMETRY ${jsonEncode({'logicalWidth': size.width, 'logicalHeight': size.height, 'textScale': scale, 'baseline': baseline, ...result.toJson()})}',
        );
        await capture(
          tester,
          '${baseline ? 'before' : 'after'}-${size.width.toInt()}x${size.height.toInt()}-scale-$scale',
        );
        if (!baseline) {
          final minimum = size.width >= 1280 && scale == 1 ? 3 : 2;
          expect(result.completeRows.length, greaterThanOrEqualTo(minimum));
          final title = find.descendant(
            of: find.byKey(ValueKey('saved-${repository.dramas.first.id}')),
            matching: find.text(repository.dramas.first.title),
          );
          final text = tester.widget<Text>(title);
          final effectiveFont =
              text.style?.fontSize ??
              DefaultTextStyle.of(tester.element(title)).style.fontSize!;
          expect(effectiveFont, greaterThanOrEqualTo(17));
          final card = find.byKey(
            ValueKey('saved-${repository.dramas.first.id}'),
          );
          final cover = find.descendant(
            of: card,
            matching: find.byType(DramaCover),
          );
          expect(
            find.descendant(of: cover, matching: find.text('VIP')),
            findsNothing,
          );
          expect(
            find.descendant(of: cover, matching: find.text('共 120 集')),
            findsNothing,
          );
          final metadata = find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (widget) => widget is Text && widget.textSpan != null,
            ),
          );
          expect(metadata, findsOneWidget);
          final contents = tester
              .widget<Text>(metadata)
              .textSpan!
              .toPlainText();
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: metadata, matching: find.byType(RichText)),
          );
          final count = RegExp(r'共\s*120\s*集').firstMatch(contents);
          expect(count, isNotNull);
          expect(
            tester.getRect(metadata).left,
            greaterThan(tester.getRect(cover).right),
          );
          expect(
            tester.getRect(metadata).right,
            lessThanOrEqualTo(tester.getRect(card).right),
          );
          for (final token in ['已有下季', 'VIP', count!.group(0)!]) {
            expect(contents, contains(token));
            if (Platform.environment['HG_UI_FONT'] == null) continue;
            final start = contents.indexOf(token);
            for (var offset = start; offset < start + token.length; offset++) {
              if (contents[offset] == ' ') continue;
              final boxes = paragraph.getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1),
              );
              expect(boxes, isNotEmpty, reason: '$token must remain visible');
              expect(
                boxes.every(
                  (box) =>
                      box.left >= -.5 && box.right <= paragraph.size.width + .5,
                ),
                isTrue,
              );
            }
          }
        }
        expect(store.trackedSeries, hasLength(repository.dramas.length));
        expect(store.watched(repository.dramas.first.id)!.episode, 37);
        expect(store.watched(repository.dramas.first.id)!.position, 79);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 40));
      });
    }
  }

  testWidgets(
    'TV saved arrows scroll, menu restores focus and back reaches discover',
    (tester) async {
      viewport(tester, const Size(960, 540), 1);
      final repository = SavedTelevisionRepository();
      final store = await local(repository);
      await mount(tester, store, repository);
      final first = repository.dramas.first;
      focusRemote(tester, find.byKey(ValueKey('saved-${first.id}')));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(find.text('取消追剧'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('取消追剧'), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-${first.id}',
      );
      await press(tester, LogicalKeyboardKey.arrowRight);
      final grid = tester.widget<RemoteGrid>(savedGrid());
      var index = 1;
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-${grid.itemKeys[index]}',
      );
      final steps = ((repository.dramas.length - 2) ~/ grid.columns).clamp(
        1,
        4,
      );
      for (var row = 0; row < steps; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        index += grid.columns;
      }
      final last = tester.getRect(
        find.byKey(ValueKey('saved-${grid.itemKeys[index]}')),
      );
      final viewportRect = tester.getRect(savedGrid());
      expect(last.top, greaterThanOrEqualTo(viewportRect.top - .5));
      expect(last.bottom, lessThanOrEqualTo(viewportRect.bottom + .5));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-${grid.itemKeys[index]}',
      );
      for (var row = 0; row < steps; row++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'remote-${first.id}',
      );
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        [0, 1, 2, 3].any(
          (index) =>
              remoteHasFocus(tester, find.byKey(ValueKey('tv-nav-$index'))),
        ),
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SavedLibrary), findsNothing);
      expect(store.watched(first.id)!.position, 79);
      expect(store.trackedSeries, hasLength(repository.dramas.length));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
    },
  );

  testWidgets(
    'TV saved search returns to navigation and preserves the full library',
    (tester) async {
      viewport(tester, const Size(960, 540), 1.3);
      final repository = SavedTelevisionRepository();
      final store = await local(repository);
      await mount(tester, store, repository);
      searchNavigation(tester).requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
      final field = find.descendant(
        of: find.byKey(const ValueKey('favorites-search')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).readOnly, isFalse);
      await tester.enterText(field, '特选末尾');
      await tester.pumpAndSettle();
      expect(tester.widget<RemoteGrid>(savedGrid()).itemKeys, [
        repository.dramas.last.id,
      ]);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SavedLibrary), findsOneWidget);
      expect(tester.widget<TextField>(field).readOnly, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RemoteGrid>(savedGrid()).itemKeys,
        hasLength(repository.dramas.length),
      );
      expect(store.trackedSeries, hasLength(repository.dramas.length));
      expect(store.watched(repository.dramas.first.id)!.position, 79);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
    },
  );

  testWidgets(
    'TV saved failed checks retry and continue preserves the watched episode',
    (tester) async {
      viewport(tester, const Size(960, 540), 1);
      final repository = SavedTelevisionRepository()..failFollow = true;
      final store = await local(repository);
      await mount(tester, store, repository);
      final requests = repository.followRequests;
      expect(requests, greaterThan(0));
      expect(find.textContaining('未完成'), findsOneWidget);
      repository.failFollow = false;
      await tester.tap(find.byKey(const ValueKey('follow-check-updates')));
      await tester.pumpAndSettle();
      expect(repository.followRequests, greaterThan(requests));
      expect(find.textContaining('未完成'), findsNothing);
      focusRemote(tester, find.byKey(const ValueKey('continue-watching')));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
      expect(repository.opened.last, repository.dramas.first.id);
      expect(find.text('这是一集 VIP 内容'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SavedLibrary), findsOneWidget);
      expect(store.watched(repository.dramas.first.id)!.episode, 37);
      expect(store.watched(repository.dramas.first.id)!.position, 79);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
    },
  );

  testWidgets('TV history retains its existing portrait cards', (tester) async {
    viewport(tester, const Size(960, 540), 1);
    final repository = SavedTelevisionRepository();
    final store = await local(repository);
    await mount(tester, store, repository);
    await tester.tap(find.byKey(const ValueKey('tv-nav-2')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SavedLibrary>(find.byType(SavedLibrary)).history,
      isTrue,
    );
    final card = find.byKey(ValueKey('saved-${repository.dramas.first.id}'));
    expect(tester.widget(card), isA<DramaTile>());
    final cover = find.descendant(of: card, matching: find.byType(AspectRatio));
    expect(
      tester.widget<AspectRatio>(cover.first).aspectRatio,
      closeTo(2 / 3, .001),
    );
    expect(store.watched(repository.dramas.first.id)!.episode, 37);
    expect(store.watched(repository.dramas.first.id)!.position, 79);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 40));
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('standard saved cards retain portrait layout at $size', (
      tester,
    ) async {
      viewport(tester, size, 1);
      final repository = SavedTelevisionRepository();
      final store = await local(repository);
      await mount(tester, store, repository, television: false);
      expect(savedGrid(), findsNothing);
      final card = find.byKey(ValueKey('saved-${repository.dramas.first.id}'));
      expect(tester.widget(card), isA<DramaTile>());
      final cover = find.descendant(
        of: card,
        matching: find.byType(AspectRatio),
      );
      expect(
        tester.widget<AspectRatio>(cover.first).aspectRatio,
        closeTo(2 / 3, .001),
      );
      expect(find.byKey(const ValueKey('continue-watching')), findsOneWidget);
      expect(store.watched(repository.dramas.first.id)!.position, 79);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
    });
  }
}
