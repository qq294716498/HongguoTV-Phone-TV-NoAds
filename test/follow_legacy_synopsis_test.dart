import 'dart:convert';

import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/lan_sync_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:duanju_app/playback_launch_screen.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'fixtures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LegacyLaunchRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(
    drama.merge(
      Drama(
        id: drama.id,
        source: drama.source,
        title: drama.title,
        episodes: 4,
      ),
    ),
    [
      for (var i = 1; i <= 4; i++)
        Episode({'id': '$i', 'currentEpisode': i}, i),
    ],
  );
}

class LegacyLaunchObserver extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.add(route);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'persisted cross-season progress survives changed synopsis characters',
    (tester) async {
      const anchor = Drama(
        id: 'hongguo:old1',
        source: 'hongguo',
        title: '旧追剧 第一季',
        description: '陈昊宇在异世觉醒。',
      );
      const sequel = Drama(
        id: 'hongguo:old2',
        source: 'hongguo',
        title: '旧追剧 第二季',
        description: '林凡在异世觉醒。',
      );
      final watch = WatchEntry(
        drama: sequel,
        episode: 3,
        position: 15,
        duration: 60,
        updatedAt: DateTime.utc(2026, 10, 28),
      );
      final document = LanDocument(replica: '1' * 32);
      document.records[anchor.id] = LanRecord(
        drama: anchor,
        member: document.cell(true),
        status: document.cell({'status': 'watching', 'manual': false}),
        progress: document.cell(lanProgress(watch)),
      );
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([anchor.toJson()]),
        'history': jsonEncode([watch.toJson()]),
        'followStates': jsonEncode({
          anchor.id: FollowState.initial(anchor, null).toJson(),
        }),
        'lanRecords': jsonEncode(document.toJson()),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      expect(store.trackedSeries.map((d) => d.id), contains(anchor.id));
      await tester.runAsync(
        () => store.refreshDrama(
          anchor.merge(
            const Drama(
              id: 'hongguo:old1',
              source: 'hongguo',
              title: '旧追剧 第一季',
              episodes: 20,
            ),
          ),
        ),
      );
      expect(store.favorites.single.episodes, 20);
      expect(
        store.lanDocument.records[anchor.id]!.progress.toJson(),
        document.records[anchor.id]!.progress.toJson(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedLibrary(
              repository: FixtureRepository(),
              store: store,
              history: false,
              onOpen: (_) {},
              onContinue: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('我的追剧'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
      final observer = LegacyLaunchObserver();
      late BuildContext origin;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) {
              origin = context;
              return const Scaffold(body: Text('最近观看'));
            },
          ),
        ),
      );
      final playStore = LocalStore(store.preferences);
      addTearDown(playStore.dispose);
      final launch = openPlaybackDirectly(
        origin,
        drama: playStore.history.first.drama,
        repository: LegacyLaunchRepository(),
        store: playStore,
      );
      for (var i = 0; i < 12; i++) {
        await tester.idle();
      }
      final routes = observer.routes
          .whereType<MaterialPageRoute<void>>()
          .where((route) => route.builder(origin) is PlayerScreen)
          .toList();
      expect(routes, hasLength(1));
      final player = routes.single.builder(origin) as PlayerScreen;
      expect(player.initialIndex, 2);
      expect(player.initialPosition, 15);
      observer.navigator!.removeRoute(routes.single);
      await tester.idle();
      await launch;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      expect(restored.trackedSeries.map((d) => d.id), contains(anchor.id));
      final recovered = restored.lanDocument.records[anchor.id]!;
      expect(recovered.watch!.drama.id, sequel.id);
      expect(recovered.watch!.episode, 3);
      expect(recovered.watch!.position, 15);
      expect(
        recovered.progress.version.includes(
          document.records[anchor.id]!.progress.version,
        ),
        true,
      );
    },
  );
  testWidgets(
    'invalid saved sync data shows recoverable diagnostics without a grey page',
    (tester) async {
      const drama = Drama(id: 'hongguo:bad', source: 'hongguo', title: '保留追剧');
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([drama.toJson()]),
        'lanRecords': '{"schema":999}',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedLibrary(
              repository: FixtureRepository(),
              store: store,
              history: false,
              onOpen: (_) {},
              onContinue: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('追剧资料暂时无法读取'), findsOneWidget);
      expect(find.text('查看日记'), findsOneWidget);
      expect(store.preferences.getString('lanRecords'), '{"schema":999}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
