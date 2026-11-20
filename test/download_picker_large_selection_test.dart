import 'package:duanju_app/download_picker.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'download picker selects and submits more than 500 episodes at once',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const count = 600;
      var submitted = <Episode>[];
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadPicker(
            detail: DramaDetail(
              const Drama(id: 'hongguo:large', source: 'hongguo', title: '长剧集'),
              List.generate(
                count,
                (index) => Episode({
                  'id': '${index + 1}',
                  'currentEpisode': index + 1,
                }, index + 1),
              ),
            ),
            onSubmit: (selection) async {
              submitted = selection.episodes;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 $count'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 $count'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('enqueue-downloads')));
      await tester.pumpAndSettle();
      expect(submitted, hasLength(count));
      expect(submitted.first.number, 1);
      expect(submitted.last.number, count);
    },
  );
}
