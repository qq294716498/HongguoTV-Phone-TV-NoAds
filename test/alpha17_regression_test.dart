import 'dart:async';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/next_season_resolver.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:duanju_app/player_device_status.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';
import 'playback_preloader_test.dart' show PendingPreloadRepository;

const firstSeason = Drama(id: 'hongguo:s1', source: 'hongguo', title: '合成连续剧');
const secondSeason = Drama(
  id: 'hongguo:s2',
  source: 'hongguo',
  title: '合成连续剧第二季',
);

class SeasonRepository extends RouteRepository {
  List<Drama> candidates = [secondSeason];
  final dramasPlayed = <String>[];
  Completer<DramaDetail>? delayedDetail;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    requests.add(query);
    return CatalogPage(candidates);
  }

  @override
  Future<DramaDetail> detail(Drama drama) {
    if (drama.id == secondSeason.id && delayedDetail != null) {
      return delayedDetail!.future;
    }
    return super.detail(drama);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) {
    dramasPlayed.add(drama.id);
    return super.resolve(drama, episode, quality: quality);
  }
}

void main() {
  setUp(mockPlayerDevice);
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  test('emoji expressions retain raw text for lossless image fallback', () {
    final measured = <String>[];
    final flights = planDanmaku(
      [const DanmakuItem(id: 'emoji', text: '好看[偷笑][笑哭]👍[未知表情]', timeMs: 0)],
      width: 800,
      rows: 2,
      measure: (text) {
        measured.add(text);
        return 180;
      },
    );
    expect(flights.single.text, '好看[偷笑][笑哭]👍[未知表情]');
    expect(measured, ['好看[偷笑][笑哭]👍[未知表情]']);
    expect(flights.single.item.text, '好看[偷笑][笑哭]👍[未知表情]');
    final compound = '${List.filled(99, '字').join()}👩🏽‍💻尾';
    final clipped = planDanmaku(
      [DanmakuItem(id: 'long', text: compound, timeMs: 0)],
      width: 800,
      rows: 2,
      measure: (_) => 400,
    );
    expect(clipped.single.text.endsWith('👩🏽‍💻…'), isTrue);
  });

  test('next season search finds the exact consecutive season only', () async {
    final repository = SeasonRepository();
    final resolver = NextSeasonResolver(repository);
    final result = await resolver.resolve(
      firstSeason,
      knownDramas: [],
      isCurrent: () => true,
    );
    expect(result?.drama.id, secondSeason.id);
    expect(repository.requests, [firstSeason.title]);
    repository.candidates = [
      const Drama(id: 'hongguo:s3', source: 'hongguo', title: '合成连续剧第三季'),
      const Drama(id: 'other:s2', source: 'other', title: '合成连续剧第二季'),
      const Drama(id: 'hongguo:other', source: 'hongguo', title: '合成连续剧外传第二季'),
    ];
    expect(
      await resolver.resolve(
        firstSeason,
        knownDramas: [],
        isCurrent: () => true,
      ),
      isNull,
    );
  });

  test(
    'duplicate next seasons are rejected and late detail cannot start playback',
    () async {
      final repository = SeasonRepository();
      final resolver = NextSeasonResolver(repository);
      await expectLater(
        resolver.resolve(
          firstSeason,
          knownDramas: [
            secondSeason,
            const Drama(
              id: 'hongguo:duplicate',
              source: 'hongguo',
              title: '合成连续剧第2季',
            ),
          ],
          isCurrent: () => true,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            'next_season_ambiguous',
          ),
        ),
      );
      var current = true;
      repository.delayedDetail = Completer<DramaDetail>();
      final pending = resolver.resolve(
        firstSeason,
        knownDramas: [secondSeason],
        isCurrent: () => current,
      );
      final checked = expectLater(
        pending,
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            'next_season_cancelled',
          ),
        ),
      );
      current = false;
      repository.delayedDetail!.complete(
        DramaDetail(secondSeason, [
          Episode({'id': '1'}, 1),
        ]),
      );
      await checked;
    },
  );

  for (final timeout in [false, true]) {
    testWidgets(
      'in-flight preload ownership survives handoff; timeout=$timeout',
      (tester) async {
        final repository = PendingPreloadRepository();
        final preloader = PlaybackPreloader(repository);
        final episode = Episode({'id': '2'}, 2);
        preloader.prepare(firstSeason, episode, immediate: true);
        await tester.pump(const Duration(milliseconds: 1));
        final transferred = preloader.takeWhenReady(firstSeason, episode);
        preloader.clear();
        expect(repository.cancellations, 0);
        if (timeout) {
          await tester.pump(const Duration(milliseconds: 1300));
          expect(await transferred, isNull);
        }
        repository.pending.single.complete(
          const PlaybackPlan(
            url: 'https://synthetic.test/next.mp4',
            session: 'owned',
          ),
        );
        await tester.pump();
        if (timeout) {
          expect(repository.released, ['owned']);
        } else {
          expect((await transferred)?.session, 'owned');
          expect(repository.released, isEmpty);
          await repository.release('owned');
        }
        preloader.dispose();
        expect(repository.released, ['owned']);
      },
    );
  }

  testWidgets(
    'automatic next season reuses page and saves each season separately',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final repository = SeasonRepository();
      final platform = ScriptedPlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            detail: await repository.detail(firstSeason),
            initialIndex: 1,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: platform),
            videoBuilder: (controls) =>
                ColoredBox(color: Colors.black, child: controls),
          ),
        ),
      );
      await frames(tester);
      platform.finishEpisode();
      await frames(tester);
      expect(repository.dramasPlayed, [firstSeason.id, secondSeason.id]);
      expect(repository.requestedEpisodes, [2, 1]);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('next-season-notice')), findsOneWidget);
      expect(store.watched(firstSeason.id)?.episode, 2);
      expect(store.watched(firstSeason.id)?.position, 120);
      await platform.seek(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 6));
      await frames(tester);
      expect(store.watched(secondSeason.id)?.episode, 1);
      expect(store.watched(secondSeason.id)?.position, 12);
      expect(find.byKey(const ValueKey('next-season-notice')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await frames(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      store.dispose();
    },
  );

  testWidgets('battery refresh stops when hidden and ignores stale replies', (
    tester,
  ) async {
    var calls = 0;
    final late = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method != 'batteryStatus') return null;
      calls++;
      if (calls == 2) return late.future;
      return {'percent': 73, 'charging': true};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    Widget status(bool visible) => MaterialApp(
      home: Scaffold(body: PlayerDeviceStatus(visible: visible)),
    );
    await tester.pumpWidget(status(true));
    await tester.pump();
    expect(find.text('73%'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-current-time')), findsOneWidget);
    for (var i = 0; i < 150 && calls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, 2);
    await tester.pumpWidget(status(false));
    late.complete({'percent': 1, 'charging': false});
    await tester.pump();
    final stopped = calls;
    await tester.pump(const Duration(minutes: 1));
    expect(calls, stopped);
    expect(find.text('73%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
