import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/television_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var exits = 0;

  setUp(() {
    exits = 0;
    messenger.setMockMethodCallHandler(
      TelevisionNavigation.channel,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(TelevisionNavigation.channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<LocalStore> showApp(WidgetTester tester, {bool tv = true}) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      DuanjuApp(repository: FixtureRepository(), store: store, television: tv),
    );
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> nativeBack(WidgetTester tester) async {
    await messenger.handlePlatformMessage(
      TelevisionNavigation.channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('back')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'root system back requires explicit exit and cancel keeps focus in the app',
    (tester) async {
      await showApp(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('退出红果TV？'), findsOneWidget);
      expect(exits, 0);
      final current = FocusManager.instance.primaryFocus?.context;
      expect(current, isNotNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('退出红果TV？'), findsNothing);
      expect(exits, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-app-exit')));
      await tester.pumpAndSettle();
      expect(exits, 1);
    },
  );

  testWidgets(
    'history input exits editing first and restores remote navigation focus',
    (tester) async {
      await showApp(tester);
      final history = find.byKey(const ValueKey('tv-nav-2'));
      focusRemote(tester, history);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('history-search'));
      await tester.tap(input);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await nativeBack(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('history-search')), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv-search-navigation',
      );
      expect(exits, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('tv-search-navigation'),
      );
      await nativeBack(tester);
      expect(find.byKey(const ValueKey('history-search')), findsNothing);
      expect(find.text('退出红果TV？'), findsNothing);
      expect(exits, 0);
    },
  );

  testWidgets(
    'search dialog back closes only the dialog and repeat events cannot exit',
    (tester) async {
      await showApp(tester);
      await tester.tap(find.byKey(const ValueKey('toggle-search')));
      await tester.pumpAndSettle();
      expect(find.text('按遥控器输入剧名拼音头字母 (如: BFLC)'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('按遥控器输入剧名拼音头字母 (如: BFLC)'), findsNothing);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('退出红果TV？'), findsNothing);
      expect(exits, 0);
    },
  );

  testWidgets(
    'one native back pops one settings layer and duplicate callback is consumed',
    (tester) async {
      await showApp(tester);
      final home = tester.element(find.byKey(const ValueKey('toggle-search')));
      Navigator.of(home).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('合成设置页')),
            body: Center(
              child: FilledButton(
                autofocus: true,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('合成设置弹窗'),
                    actions: [
                      TextButton(
                        autofocus: true,
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                child: const Text('打开设置弹窗'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开设置弹窗'));
      await tester.pumpAndSettle();
      final state = tester.state<TelevisionNavigationState>(
        find.byType(TelevisionNavigation),
      );
      final first = state.handleBack();
      final duplicate = state.handleBack();
      await first;
      await duplicate;
      await tester.pumpAndSettle();
      expect(find.text('合成设置弹窗'), findsNothing);
      expect(find.text('合成设置页'), findsOneWidget);
      expect(exits, 0);
      await nativeBack(tester);
      expect(find.text('合成设置页'), findsNothing);
      expect(find.text('退出红果TV？'), findsNothing);
      expect(exits, 0);
    },
  );

  testWidgets(
    'settings text input releases focus before its route or dialog is popped',
    (tester) async {
      await showApp(tester);
      final home = tester.element(find.byKey(const ValueKey('toggle-search')));
      showDialog<void>(
        context: home,
        builder: (context) => AlertDialog(
          title: const Text('编辑设置'),
          content: const TextField(autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消编辑'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await nativeBack(tester);
      expect(find.text('编辑设置'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await nativeBack(tester);
      expect(find.text('编辑设置'), findsNothing);
      expect(exits, 0);
    },
  );

  testWidgets('phone layout does not intercept native navigation callbacks', (
    tester,
  ) async {
    await showApp(tester, tv: false);
    await nativeBack(tester);
    expect(find.text('退出红果TV？'), findsNothing);
    expect(exits, 0);
  });
  testWidgets(
    'native back can safely leave a bootstrap error screen through confirmation',
    (tester) async {
      await tester.pumpWidget(
        DuanjuApp(
          repository: FixtureRepository(),
          television: true,
          bootstrapError: '合成启动失败',
        ),
      );
      await tester.pumpAndSettle();
      await nativeBack(tester);
      expect(find.text('退出红果TV？'), findsOneWidget);
      expect(exits, 0);
      await tester.tap(find.text('继续使用'));
      await tester.pumpAndSettle();
      expect(find.text('退出红果TV？'), findsNothing);
    },
  );
}
