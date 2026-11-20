import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, flushDanmaku, updateDanmaku;

void main() {
  test('弹幕字号与数量偏好默认小号正常，并能持久化与回退', () {
    const defaults = PlaybackPreferences();
    expect(defaults.danmakuFontSize, DanmakuFontSize.small);
    expect(defaults.danmakuDensity, DanmakuDensity.normal);

    final tuned = defaults.copyWith(
      danmakuFontSize: DanmakuFontSize.large,
      danmakuDensity: DanmakuDensity.sparse,
    );
    final restored = PlaybackPreferences.fromJson(tuned.toJson());
    expect(restored.danmakuFontSize, DanmakuFontSize.large);
    expect(restored.danmakuDensity, DanmakuDensity.sparse);

    final legacy = tuned.toJson()
      ..remove('danmakuFontSize')
      ..remove('danmakuDensity');
    final fallback = PlaybackPreferences.fromJson(legacy);
    expect(fallback.danmakuFontSize, DanmakuFontSize.small);
    expect(fallback.danmakuDensity, DanmakuDensity.normal);
  });

  test('弹幕字号按端换算，档位依次放大', () {
    double tv(DanmakuFontSize size) =>
        danmakuFontSizeFor(size, mobile: false, television: true, width: 960);
    expect(tv(DanmakuFontSize.small), 14);
    expect(tv(DanmakuFontSize.medium), closeTo(17.92, .001));
    expect(tv(DanmakuFontSize.large), closeTo(22.68, .001));
    expect(
      danmakuFontSizeFor(
        DanmakuFontSize.small,
        mobile: true,
        television: false,
        width: 400,
      ),
      16,
    );
    expect(
      danmakuRowLimit(DanmakuDensity.normal, mobile: false, television: true),
      4,
    );
    expect(
      danmakuRowLimit(DanmakuDensity.sparse, mobile: false, television: true),
      2,
    );
    expect(danmakuRowLimit(DanmakuDensity.normal, mobile: true), 5);
  });

  testWidgets('TV 正常模式铺满四轨，少量模式只留两轨，大号字更大', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 540);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final repository = DanmakuFixtureRepository()
      ..response = (request) => DanmakuPage(
        episodeId: request.plan.danmakuId,
        startMs: 0,
        nextMs: 30000,
        items: List.generate(
          6,
          (index) =>
              DanmakuItem(id: 'size-$index', text: '字号弹幕 $index', timeMs: 0),
        ),
      );
    final controller = DanmakuController(repository)..setPlan(danmakuPlan);
    addTearDown(controller.dispose);
    updateDanmaku(controller);
    await flushDanmaku();

    Future<void> render({
      required DanmakuDensity density,
      DanmakuFontSize fontSize = DanmakuFontSize.small,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DanmakuOverlay(
            controller: controller,
            aspectRatio: 16 / 9,
            television: true,
            fontSize: fontSize,
            density: density,
          ),
        ),
      ),
    );
    Finder flights() => find.byWidgetPredicate(
      (widget) =>
          widget is Positioned &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('danmaku-item-'),
    );

    await render(density: DanmakuDensity.normal);
    await tester.pump();
    expect(flights(), findsNWidgets(4));
    expect(tester.widget<Text>(find.text('字号弹幕 0')).style!.fontSize, 14);

    await render(
      density: DanmakuDensity.sparse,
      fontSize: DanmakuFontSize.large,
    );
    await tester.pump();
    expect(flights(), findsNWidgets(2));
    expect(
      tester.widget<Text>(find.text('字号弹幕 0')).style!.fontSize,
      closeTo(22.68, .01),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
