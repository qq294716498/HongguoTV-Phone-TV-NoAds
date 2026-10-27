import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

class InlineRankingRepository extends FixtureRepository {
  String? board;
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'hongguo-comic', source: 'hongguo', name: '漫剧榜'),
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热播榜'),
  ];
  @override
  Future<RankingPage> rankings(
    String id, {
    int page = 1,
    bool force = false,
  }) async {
    board = id;
    return const RankingPage(
      items: [
        RankingItem(
          1,
          Drama(
            id: 'hongguo:rank-fixture',
            source: 'hongguo',
            title: '合成榜单剧',
            category: '漫剧',
          ),
          metric: '123万热度',
        ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'desktop inline rankings keep source order, switch layouts and return to catalog',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setSource('hongguo');
      final repository = InlineRankingRepository();
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-hongguo-comic')));
      await tester.pumpAndSettle();
      expect(repository.board, 'hongguo-comic');
      expect(find.text('123万热度'), findsOneWidget);
      expect(tester.widget<DramaTile>(find.byType(DramaTile).first).rank, 1);
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      expect(find.byType(DramaTile), findsNothing);
      expect(
        find.byKey(const ValueKey('rank-1-hongguo:rank-fixture')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('category-')));
      await tester.pumpAndSettle();
      expect(find.text('合成榜单剧'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
