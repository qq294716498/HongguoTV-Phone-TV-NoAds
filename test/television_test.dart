import 'dart:io';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

class TelevisionRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(
      drama,
      List.generate(
        100,
        (index) => Episode({
          'id': '${index + 1}',
          'currentEpisode': index + 1,
          'vip': true,
        }, index + 1),
      ),
    );
  }
}

void main() {
  testWidgets('episode numbers keep contrast despite inherited black text', (
    tester,
  ) async {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: DefaultTextStyle(
              style: const TextStyle(color: Colors.black),
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    height: 56,
                    child: RemoteEpisodeButton(
                      key: const ValueKey('contrast-normal'),
                      number: 1,
                      focusNode: focus,
                      onPressed: () {},
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    height: 56,
                    child: RemoteEpisodeButton(
                      key: const ValueKey('contrast-current'),
                      number: 2,
                      current: true,
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      double contrast(Color text, Color background) {
        final a = text.computeLuminance();
        final b = background.computeLuminance();
        return (a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05));
      }

      final normal = tester.widget<Text>(find.text('1')).style!.color!;
      final current = tester.widget<Text>(find.text('2')).style!.color!;
      expect(
        contrast(normal, theme.colorScheme.surfaceContainer),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(current, theme.colorScheme.primaryContainer),
        greaterThanOrEqualTo(4.5),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(
        contrast(normal, theme.colorScheme.surfaceContainerHighest),
        greaterThanOrEqualTo(4.5),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      expect(tester.takeException(), isNull);
    }
  });

  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    if (key == LogicalKeyboardKey.goBack) {
      await tester.binding.handlePopRoute();
    } else {
      await tester.sendKeyEvent(key);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('display version fallbacks match the package release version', (
    tester,
  ) async {
    final packageVersion = RegExp(
      r'^version:\s*([^+\s]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, packageVersion);
    expect(const AppDevice().version, packageVersion);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect((await AppDevice.detect()).version, packageVersion);
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => Text(AppLayout.versionOf(context))),
      ),
    );
    expect(find.text(packageVersion!), findsOneWidget);
    await tester.pumpWidget(
      AppLayout(
        television: false,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Text(AppLayout.versionOf(context)),
          ),
        ),
      ),
    );
    expect(find.text(packageVersion), findsOneWidget);
    await tester.pumpWidget(
      AppLayout(
        television: false,
        version: '9.8.7',
        child: MaterialApp(
          home: Builder(
            builder: (context) => Text(AppLayout.versionOf(context)),
          ),
        ),
      ),
    );
    expect(find.text('9.8.7'), findsOneWidget);
  });

  testWidgets(
    'Android TV detection falls back safely when the platform channel is unavailable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        expect(call.method, 'deviceInfo');
        return {'television': true, 'version': '9.8.7'};
      });
      final detected = await AppDevice.detect();
      expect(detected.television, isTrue);
      expect(detected.version, '9.8.7');
      messenger.setMockMethodCallHandler(
        AppDevice.channel,
        (call) async => {'television': false, 'version': ''},
      );
      expect((await AppDevice.detect()).version, appVersion);
      messenger.setMockMethodCallHandler(
        AppDevice.channel,
        (call) async => throw MissingPluginException(),
      );
      final fallback = await AppDevice.detect();
      expect(fallback.television, isFalse);
      expect(fallback.version, appVersion);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'manual interface preference overrides device detection and survives restart',
    (tester) async {
      size(tester, const Size(960, 540));
      final store = await makeStore();
      final repository = FixtureRepository();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store, television: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-nav-0')), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('界面模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手机 / 电脑'));
      await tester.pumpAndSettle();
      expect(store.displayMode, 'standard');
      expect(find.byKey(const ValueKey('tv-nav-0')), findsNothing);
      expect(LocalStore(store.preferences).displayMode, 'standard');
      await store.setDisplayMode('television');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-nav-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dimensions in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets(
      'TV source choices and direct playback VIP confirmation retain remote focus at $dimensions',
      (tester) async {
        size(tester, dimensions);
        final store = await makeStore();
        final repository = TelevisionRepository();
        await tester.pumpWidget(
          DuanjuApp(repository: repository, store: store, television: true),
        );
        await tester.pumpAndSettle();
        if (SourceSite.values.length > 1) {
          final switcher = find.byKey(const ValueKey('source-switch'));
          focusRemote(tester, switcher);
          await tester.pumpAndSettle();
          await press(tester, LogicalKeyboardKey.select);
          await press(tester, LogicalKeyboardKey.arrowDown);
          await press(tester, LogicalKeyboardKey.select);
        }
        expect(
          repository.requests.last,
          SourceSite.values.length > 1 ? SourceSite.values[1].id : 'hongguo',
        );
        focusRemote(tester, find.byKey(ValueKey(FixtureRepository.free.id)));
        await tester.pumpAndSettle();
        await press(tester, LogicalKeyboardKey.select);
        expect(repository.detailCalls, 1);
        expect(find.text('这是一集 VIP 内容'), findsOneWidget);
        await press(tester, LogicalKeyboardKey.goBack);
        expect(find.text('这是一集 VIP 内容'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'remote-${FixtureRepository.free.id}',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'remote grid reaches unbuilt rows, partial last row and pagination without touch',
    (tester) async {
      size(tester, const Size(960, 540));
      var loaded = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteGrid(
              itemKeys: List.generate(59, (index) => '$index'),
              columns: 4,
              itemExtent: 100,
              autofocus: true,
              footer: Center(
                child: RemoteButton(label: '加载更多', onPressed: () => loaded++),
              ),
              itemBuilder: (_, index, node, onFocus) => RemoteEpisodeButton(
                number: index,
                focusNode: node,
                onFocus: onFocus,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-0');
      for (var index = 0; index < 3; index++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      for (var row = 0; row < 14; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-58');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(loaded, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('episode grid initially focuses an offscreen saved episode', (
    tester,
  ) async {
    size(tester, const Size(960, 540));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteGrid(
            itemKeys: List.generate(160, (index) => '$index'),
            columns: 6,
            itemExtent: 64,
            initialIndex: 131,
            autofocus: true,
            itemBuilder: (_, index, node, onFocus) => RemoteEpisodeButton(
              number: index,
              focusNode: node,
              onFocus: onFocus,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-131');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-125');
    expect(tester.takeException(), isNull);
  });
}
