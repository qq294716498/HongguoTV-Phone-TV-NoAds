import 'dart:async';

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_launch_screen.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class SlowMetadataStore extends LocalStore {
  SlowMetadataStore(super.preferences);
  final saved = Completer<void>();
  @override
  Future<void> refreshDrama(Drama drama) => saved.future;
}

class PendingDetailRepository extends FixtureRepository {
  final pending = <Completer<DramaDetail>>[];

  @override
  Future<DramaDetail> detail(Drama drama) {
    detailCalls++;
    final request = Completer<DramaDetail>();
    pending.add(request);
    return request.future;
  }

  void complete(int index) => pending[index].complete(
    DramaDetail(FixtureRepository.free, [
      Episode({'id': '1', 'currentEpisode': 1}, 1),
    ]),
  );
}

class LaunchObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  late LocalStore store;
  late PendingDetailRepository repository;
  late LaunchObserver observer;
  late BuildContext origin;
  final launches = <Future<void>>[];

  Future<void> mount(WidgetTester tester, {bool slowSave = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = slowSave ? SlowMetadataStore(prefs) : LocalStore(prefs);
    repository = PendingDetailRepository();
    observer = LaunchObserver();
    launches.clear();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            origin = context;
            return Scaffold(
              body: TextButton(onPressed: () {}, child: const Text('合成选剧入口')),
            );
          },
        ),
      ),
    );
  }

  void launch() => launches.add(
    openPlaybackDirectly(
      origin,
      drama: FixtureRepository.free,
      repository: repository,
      store: store,
    ),
  );

  Future<List<MaterialPageRoute<void>>> players(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.idle();
    }
    return observer.pushed
        .whereType<MaterialPageRoute<void>>()
        .where((route) => route.builder(origin) is PlayerScreen)
        .toList();
  }

  Future<void> clean(WidgetTester tester) async {
    for (final route in observer.pushed.reversed) {
      if (route.isActive &&
          route is MaterialPageRoute<void> &&
          route.builder(origin) is PlayerScreen) {
        observer.navigator!.removeRoute(route);
      }
    }
    await tester.idle();
    await Future.wait(launches);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    expect(tester.takeException(), isNull);
  }

  testWidgets('metadata persistence does not block entering the player', (
    tester,
  ) async {
    await mount(tester, slowSave: true);
    launch();
    repository.complete(0);
    expect(await players(tester), hasLength(1));
    (store as SlowMetadataStore).saved.complete();
    await clean(tester);
  });

  testWidgets('slow detail requests accept one launch and push one player', (
    tester,
  ) async {
    await mount(tester);
    launch();
    launch();
    launch();
    expect(repository.detailCalls, 1);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('playback-launch-loading')),
      findsOneWidget,
    );
    repository.complete(0);
    final routes = await players(tester);
    expect(routes, hasLength(1));
    launch();
    expect(repository.detailCalls, 1);
    await clean(tester);
  });

  testWidgets(
    'cancelling allows a new choice and discards the late old response',
    (tester) async {
      await mount(tester);
      launch();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 250));
      launch();
      await tester.pump();
      expect(repository.detailCalls, 2);
      repository.complete(0);
      expect(await players(tester), isEmpty);
      expect(
        find.byKey(const ValueKey('playback-launch-loading')),
        findsOneWidget,
      );
      launch();
      expect(repository.detailCalls, 2);
      repository.complete(1);
      expect(await players(tester), hasLength(1));
      await clean(tester);
    },
  );

  testWidgets(
    'failed requests dismiss loading, report the error and permit retry',
    (tester) async {
      await mount(tester);
      launch();
      await tester.pump();
      repository.pending[0].completeError(AppFailure('合成网络错误'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('playback-launch-loading')),
        findsNothing,
      );
      expect(find.text('合成网络错误'), findsOneWidget);
      expect(await players(tester), isEmpty);
      launch();
      expect(repository.detailCalls, 2);
      repository.complete(1);
      expect(await players(tester), hasLength(1));
      await clean(tester);
    },
  );
}
