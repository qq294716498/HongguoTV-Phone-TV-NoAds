import 'package:duanju_app/app_origin.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fixtures.dart';
import 'player_fixtures.dart' show mockPlayerDevice;

class _NoticeStorage extends InMemorySharedPreferencesStore {
  _NoticeStorage() : super.withData({});
  bool fail = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (fail && key.endsWith(originNoticeAcknowledgedKey)) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  setUp(mockPlayerDevice);
  for (final mode in ['phone', 'tv', 'windows']) {
    testWidgets(
      '$mode first launch persists one global acknowledgement across versions and profiles',
      (tester) async {
        tester.view.physicalSize = mode == 'phone'
            ? const Size(390, 700)
            : const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final store = testStore(preferences);
        addTearDown(store.dispose);
        Widget app(String version) => DuanjuApp(
          repository: FixtureRepository(),
          store: store,
          television: mode == 'tv',
          version: version,
          requireOriginNotice: true,
        );
        await tester.pumpWidget(app('0.1.14'));
        await tester.pumpAndSettle();
        expect(find.text(projectFreeNotice), findsOneWidget);
        expect(find.byType(HomeScreen), findsNothing);
        expect(find.text(projectRepositoryUrl), findsOneWidget);
        final acknowledge = find.byKey(
          const ValueKey('acknowledge-project-origin'),
        );
        expect(
          tester.getRect(acknowledge).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height),
        );
        if (mode == 'tv') {
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(acknowledge);
        }
        await tester.pumpAndSettle();
        expect(preferences.getBool(originNoticeAcknowledgedKey), true);
        expect(find.byType(HomeScreen), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await store.saveProfile(
          id: store.profile.id,
          name: store.profile.name,
          sources: store.profile.sources,
          download: true,
          pin: '123456',
        );
        await store.saveProfile(
          name: '第二用户',
          sources: const ['hongguo'],
          download: true,
        );
        await store.switchProfile(store.profiles.last.id);
        await tester.pumpWidget(app('0.9.0'));
        await tester.pumpAndSettle();
        expect(find.text(projectFreeNotice), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await store.flushPendingWrites();
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          MaterialApp(
            home: FirstLaunchNotice(
              preferences: await SharedPreferences.getInstance(),
              child: const Text('home'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(projectFreeNotice), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        mode == 'windows' ? TargetPlatform.windows : TargetPlatform.android,
      ),
    );
  }
  testWidgets(
    'failed storage keeps notice and can retry without a cached acknowledgement',
    (tester) async {
      SharedPreferences.resetStatic();
      final storage = _NoticeStorage();
      SharedPreferencesStorePlatform.instance = storage;
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        MaterialApp(
          home: FirstLaunchNotice(
            preferences: preferences,
            child: const Text('home'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('acknowledge-project-origin')),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认状态保存失败，请重试'), findsOneWidget);
      expect(preferences.getBool(originNoticeAcknowledgedKey), isNot(true));
      storage.fail = false;
      await tester.tap(
        find.byKey(const ValueKey('acknowledge-project-origin')),
      );
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'about retains licenses and upstream while showing bundled public GitHub avatar',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: appName,
                  children: const [ProjectOrigin()],
                ),
                child: const Text('about'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('about'));
      await tester.pumpAndSettle();
      expect(find.text(projectFreeNotice), findsOneWidget);
      expect(find.text('维护仓库 · qq294716498'), findsOneWidget);
      expect(find.textContaining('zhoufuweigg/guoapp'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      final licenses = MaterialLocalizations.of(
        tester.element(find.byType(AboutDialog)),
      ).viewLicensesButtonLabel;
      expect(find.text(licenses), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('missing browser copies the exact repository link', (
    tester,
  ) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      AppDevice.channel,
      (_) async => throw MissingPluginException(),
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: ProjectOrigin())),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-project-repository')));
    await tester.pumpAndSettle();
    expect(copied, projectRepositoryUrl);
    expect(find.text('无法打开浏览器，仓库链接已复制'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
