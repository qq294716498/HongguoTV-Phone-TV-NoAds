import 'dart:async';

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/downloads_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/widgets.dart';
import 'package:duanju_app/television_saved_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interface_fixtures.dart';
import 'fixtures.dart';

void main() {
  Future<LocalStore> localStore({bool unlockSources = false}) async {
    SharedPreferences.setMockInitialValues(
      unlockSources ? await gatePreferences() : {},
    );
    final store = testStore(await SharedPreferences.getInstance());
    if (unlockSources) await unlockGate(store);
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester, Size size, [double scale = 1]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets(
    'refresh rotates during a request and stops after success or failure',
    (tester) async {
      viewport(tester, const Size(430, 844));
      final repository = InterfaceRepository();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: await localStore()),
      );
      await tester.pumpAndSettle();
      final refresh = find.byKey(const ValueKey('catalog-refresh'));
      final rotation = find.descendant(
        of: refresh,
        matching: find.byType(RotationTransition),
      );
      final button = find.descendant(
        of: refresh,
        matching: find.byType(IconButton),
      );
      for (final fails in [false, true]) {
        final pending = Completer<CatalogPage>();
        repository.pendingCatalog = pending;
        final requests = repository.requests.length;
        await tester.tap(refresh);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final firstAngle = tester
            .widget<RotationTransition>(rotation)
            .turns
            .value;
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester.widget<RotationTransition>(rotation).turns.value,
          isNot(firstAngle),
        );
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(find.text('短标题'), findsOneWidget);
        await tester.tap(refresh);
        expect(repository.requests.length, requests + 1);
        repository.pendingCatalog = null;
        if (fails) {
          pending.completeError(AppFailure('合成更新失败'));
        } else {
          pending.complete(CatalogPage(repository.dramas('hongguo')));
        }
        await tester.pumpAndSettle();
        expect(tester.widget<RotationTransition>(rotation).turns.value, 0);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        expect(find.text('短标题'), findsOneWidget);
        if (fails) {
          expect(find.text('暂时无法加载'), findsNothing);
          final requests = repository.requests.length;
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(repository.requests.length, requests + 1);
          expect(find.text('短标题'), findsOneWidget);
          expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only Huangdou exposes and applies the persistent VIP filter', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final repository = InterfaceRepository();
    final store = await localStore(unlockSources: true);
    await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    Future<void> select(String name) async {
      if (SourceGroup.fromSources(SourceSite.values).length <= 1) return;
      await tester.tap(find.byKey(const ValueKey('source-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    for (final group in SourceGroup.fromSources(SourceSite.values)) {
      await select(group.name);
      if (group.id == 'huangdou') {
        expect(find.text('会员合成剧'), findsNothing);
        await tester.tap(find.byTooltip('VIP：隐藏'));
        await tester.pumpAndSettle();
        expect(find.text('会员合成剧'), findsOneWidget);
      } else {
        expect(find.byTooltip('VIP：隐藏'), findsNothing);
        expect(find.byTooltip('VIP：显示'), findsNothing);
        expect(find.text('会员合成剧'), findsWidgets);
      }
    }
    if (!allSourcesEnabled) {
      for (final source in SourceSite.knownValues.skip(1)) {
        expect(find.widgetWithText(ChoiceChip, source.name), findsNothing);
      }
      return;
    }
    await select('黄豆');
    expect(find.byTooltip('VIP：显示'), findsOneWidget);
    await tester.tap(find.byTooltip('VIP：显示'));
    await tester.pumpAndSettle();
    expect(store.hideVip, isTrue);
    await select('红果');
    expect(find.text('会员合成剧'), findsOneWidget);
    expect(find.textContaining('VIP：'), findsNothing);
  });

  for (final layout in [
    (const Size(390, 844), 1.0, false),
    (const Size(320, 844), 2.0, false),
    (const Size(1280, 800), 1.0, false),
    (const Size(960, 540), 1.0, true),
  ]) {
    testWidgets('posters align while TV follows use compact cards at $layout', (
      tester,
    ) async {
      viewport(tester, layout.$1, layout.$2);
      final repository = InterfaceRepository();
      final store = await localStore();
      for (final drama in repository.dramas('hongguo')) {
        await store.toggleFavorite(drama);
        await store.saveWatch(
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 15,
            duration: 60,
            updatedAt: DateTime.now(),
          ),
        );
      }
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store, television: layout.$3),
      );
      await tester.pumpAndSettle();
      Size? catalogSize;
      Size? catalogTileSize;
      for (var tab = 0; tab < 3; tab++) {
        if (tab > 0) {
          final destination = layout.$3
              ? find.byKey(ValueKey('tv-nav-$tab'))
              : layout.$1.width < 840
              ? find.byKey(ValueKey('bottom-nav-$tab'))
              : find.descendant(
                  of: find.byType(NavigationRail),
                  matching: find.text(tab == 1 ? '追剧' : '最近观看'),
                );
          await tester.tap(destination);
          await tester.pumpAndSettle();
        }
        final covers = find.byType(DramaCover);
        final compact = layout.$3 && tab == 1;
        final tiles = find.byType(compact ? TelevisionSavedTile : DramaTile);
        expect(covers, findsNWidgets(3));
        expect(tiles, findsNWidgets(3));
        final first = tester.getRect(covers.first);
        catalogSize ??= first.size;
        catalogTileSize ??= tester.getSize(tiles.first);
        if (compact) {
          expect(first.width, lessThan(catalogSize.width));
          expect(first.height, lessThan(catalogSize.height));
          expect(
            tester.getSize(tiles.first).height,
            lessThan(catalogTileSize.height),
          );
        } else {
          expect(first.width, closeTo(catalogSize.width, .01));
          expect(first.height, closeTo(catalogSize.height, .01));
        }
        for (var index = 0; index < 3; index++) {
          final rect = tester.getRect(covers.at(index));
          expect(rect.width / rect.height, closeTo(2 / 3, .001));
          expect(rect.width, closeTo(first.width, .01));
          expect(rect.bottom, closeTo(first.bottom, .01));
          expect(
            tester.getSize(tiles.at(index)).height,
            tester.getSize(tiles.first).height,
          );
        }
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final layout in [
    (const Size(360, 760), 1.0),
    (const Size(320, 844), 2.0),
    (const Size(1280, 800), 1.0),
  ]) {
    testWidgets(
      'download title actions fit and control the whole queue despite filtering at $layout',
      (tester) async {
        viewport(tester, layout.$1, layout.$2);
        final repository = InterfaceRepository();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: DownloadsScreen(
              repository: repository,
              store: await localStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final menu = find.byKey(const ValueKey('download-queue-actions'));
        final filters = find.byTooltip('筛选下载合集');
        final local = find.byKey(const ValueKey('download-local-media'));
        final search = find.byType(TextField);
        expect(
          tester.getCenter(menu).dy,
          closeTo(tester.getCenter(find.text('下载合集')).dy, .01),
        );
        expect(tester.getRect(menu).left, greaterThan(layout.$1.width / 2));
        for (final action in [menu, filters, local]) {
          expect(
            tester.getRect(action).bottom,
            lessThan(tester.getRect(search).top),
          );
          expect(
            tester.getRect(action).right,
            lessThanOrEqualTo(layout.$1.width),
          );
          expect(tester.getRect(action).left, greaterThanOrEqualTo(0));
        }
        await tester.tap(find.text('短标题'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            ValueKey(
              '${layout.$1.width < 600 ? 'download-episode' : 'download-task'}-task-0',
            ),
          ),
          findsOneWidget,
        );
        await tester.tap(filters);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ChoiceChip, '全部任务'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, '已下载'));
        await tester.tap(find.text('应用'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            ValueKey(
              '${layout.$1.width < 600 ? 'download-episode' : 'download-task'}-task-0',
            ),
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            ValueKey(
              '${layout.$1.width < 600 ? 'download-episode' : 'download-task'}-task-2',
            ),
          ),
          findsOneWidget,
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部暂停'));
        await tester.pumpAndSettle();
        expect(repository.commands, ['pause:task-0']);
        expect(repository.jobs.where((job) => job.active), isEmpty);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部继续'));
        await tester.pumpAndSettle();
        expect(repository.commands, [
          'pause:task-0',
          'resume:task-0',
          'resume:task-1',
        ]);
        expect(repository.jobs.where((job) => job.active).length, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
