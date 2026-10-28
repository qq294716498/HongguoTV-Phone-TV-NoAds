import 'package:duanju_app/drama_actions.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/series_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

const anchor = Drama(
  id: 'hongguo:action2',
  source: 'hongguo',
  title: '觉醒伪神：神明弃我我自为神2',
  description: '陈昊宇在异世觉醒。',
);
const sequel = Drama(
  id: 'hongguo:action3',
  source: 'hongguo',
  title: '觉醒伪神：神明弃我我自为神3',
  description: '陈昊宇获得神秘力量。',
);

class OtherSeasonsRepository extends FixtureRepository {
  final queries = <String>[];
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    queries.add(query);
    return CatalogPage([anchor, sequel], hasMore: false);
  }
}

void main() {
  testWidgets(
    'drama overflow searches other seasons without adding a favorite',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final repository = OtherSeasonsRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: DramaActionButton(
                drama: anchor,
                onPressed: () => showDramaActions(
                  context,
                  drama: anchor,
                  store: store,
                  repository: repository,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('drama-actions-hongguo:action2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索其他季'));
      await tester.pumpAndSettle();
      expect(find.byType(SeriesBrowserScreen), findsOneWidget);
      expect(repository.queries, isNotEmpty);
      expect(
        find.byKey(const ValueKey('all-season-hongguo:action3')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('all-season-hongguo:action3')),
      );
      await tester.pumpAndSettle();
      expect(find.text(sequel.title), findsWidgets);
      expect(store.favorites, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
