import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/download_picker.dart';
import 'package:duanju_app/models.dart';

void main() {
  testWidgets(
    'embedded picker drags select/cancel, keeps other groups and submits exact episodes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final submitted = <DownloadSelection>[];
      final completion = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadPicker(
              embedded: true,
              detail: DramaDetail(
                const Drama(
                  id: 'hongguo:drag',
                  source: 'hongguo',
                  title: '合成选集',
                  episodes: 220,
                ),
                List.generate(
                  220,
                  (index) => Episode({
                    'id': '${index + 1}',
                    'currentEpisode': index + 1,
                  }, index + 1),
                ),
              ),
              onSubmit: (selection) {
                submitted.add(selection);
                return completion.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 220'), findsOneWidget);
      Finder cell(int number) =>
          find.byKey(ValueKey('download-episode-$number'));
      Future<void> drag(int from, int to) async {
        final gesture = await tester.startGesture(tester.getCenter(cell(from)));
        await gesture.moveTo(tester.getCenter(cell(to)));
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      await drag(1, 5);
      expect(find.text('已选 215'), findsOneWidget);
      await drag(1, 3);
      expect(find.text('已选 218'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pump();
      await drag(2, 5);
      expect(find.text('已选 4'), findsOneWidget);
      await tester.tap(find.text('51-100'));
      await tester.pumpAndSettle();
      await tester.tap(cell(51));
      await tester.pump();
      expect(find.text('加入下载 · 5 集'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('enqueue-downloads')));
      await tester.pump();
      expect(submitted.single.episodes.map((episode) => episode.number), [
        2,
        3,
        4,
        5,
        51,
      ]);
      await tester.tap(cell(52));
      await tester.pump();
      expect(find.text('已选 5'), findsOneWidget);
      completion.complete();
      await tester.pumpAndSettle();
      expect(find.text('已选 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
