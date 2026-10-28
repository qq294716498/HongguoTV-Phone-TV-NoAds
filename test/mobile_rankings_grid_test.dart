import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

class MobileRankingRepository extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热播榜'),
  ];
  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage(
    items: [
      for (var i = 1; i <= 6; i++)
        RankingItem(
          i,
          Drama(id: 'hongguo:grid$i', source: 'hongguo', title: '合成榜单剧$i'),
          metric: '123万热度',
        ),
    ],
  );
}

void main() {
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets(
      'standalone mobile ranking defaults to three posters at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: RankingsScreen(
              repository: MobileRankingRepository(),
              store: store,
              initialGroup: 'hongguo',
            ),
          ),
        );
        await tester.pumpAndSettle();
        Rect card(int n) =>
            tester.getRect(find.byKey(ValueKey('rank-$n-hongguo:grid$n')));
        expect(find.byType(DramaTile), findsNWidgets(6));
        expect(card(1).top, card(2).top);
        expect(card(2).top, card(3).top);
        expect(card(4).top, greaterThan(card(1).bottom));
        expect(card(3).right, lessThanOrEqualTo(width));
        await tester.tap(find.byTooltip('列表视图'));
        await tester.pumpAndSettle();
        expect(find.byType(DramaTile), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
