import 'package:duanju_app/download_picker.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'phone download shows all episodes continuously at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final count = scale == 1 ? 220 : 1000;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DownloadPicker(
              detail: DramaDetail(
                const Drama(
                  id: 'hongguo:continuous',
                  source: 'hongguo',
                  title: '合成剧集',
                ),
                List.generate(
                  count,
                  (index) => Episode({
                    'id': '${index + 1}',
                    'currentEpisode': index + 1,
                    'vip': scale == 2,
                  }, index + 1),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('episode-range')), findsNothing);
        expect(find.text('51-100'), findsNothing);
        expect(find.byTooltip('下一组选集'), findsNothing);
        final first = find.byKey(const ValueKey('download-episode-1'));
        if (scale == 1) {
          final size = tester.getSize(first);
          expect(size.height, lessThanOrEqualTo(40));
          expect(size.width, lessThanOrEqualTo(65));
          expect(find.text('已选 220'), findsOneWidget);
        }
        final last = find.byKey(ValueKey('download-episode-$count'));
        await tester.scrollUntilVisible(
          last,
          350,
          maxScrolls: 200,
          scrollable: find
              .descendant(
                of: find.byType(DownloadPicker),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
