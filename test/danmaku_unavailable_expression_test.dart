import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/danmaku_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_emoji_render_test.dart' show FailingEmojiBundle, finishDecoding;
import 'danmaku_fixtures.dart';
import 'danmaku_test.dart' show danmakuPlan, flushDanmaku, updateDanmaku;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const original = '[没看够]【没看够】［没看够］';
  const style = TextStyle(fontSize: 16, color: Colors.white);

  test('unavailable expression names keep every original bracket token', () {
    expect(danmakuDisplayText(original), original);
    final content = DanmakuEmojiContent.parse(original);
    final span = content.span(style, TextScaler.noScaling, null);
    expect(content.fallbackText, original);
    expect(span.toPlainText(), original);
    expect(span.children!.whereType<WidgetSpan>(), isEmpty);
    expect(span.toPlainText(), isNot(contains('\uFFFC')));
    expect(span.toPlainText(), isNot(contains('[OBJ]')));
    expect(content.measure(style, TextScaler.noScaling), greaterThan(0));
  });

  testWidgets('failed assets preserve named expressions as visible text', (
    tester,
  ) async {
    const text = '前$original[吃瓜]后';
    final bundle = FailingEmojiBundle();
    final cache = DanmakuEmojiCache(bundle: bundle);
    addTearDown(cache.dispose);
    cache.ensureLoaded([text]);
    await finishDecoding(tester, cache);
    final calls = bundle.calls;
    expect(calls, greaterThan(0));
    final content = DanmakuEmojiContent.parse(text);
    final span = content.span(style, TextScaler.noScaling, cache);
    expect(span.toPlainText(), text);
    expect(span.children!.whereType<WidgetSpan>(), isEmpty);
    expect(content.placeholders(20, cache: cache), isEmpty);
    cache.ensureLoaded([text]);
    expect(bundle.calls, calls);
    expect(cache.loading, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: DanmakuEmojiText(
          text: text,
          style: style,
          scaler: TextScaler.noScaling,
          cache: cache,
        ),
      ),
    );
    final rendered = tester.widget<Text>(
      find.descendant(
        of: find.byType(DanmakuEmojiText),
        matching: find.byType(Text),
      ),
    );
    expect(rendered.textSpan!.toPlainText(), text);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in ['mobile', 'television', 'windows']) {
    testWidgets(
      '$platform overlay retains unavailable expressions without blank images or object placeholders',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(960, 540);
        addTearDown(tester.view.reset);
        final repository = DanmakuFixtureRepository()
          ..response = (request) => DanmakuPage(
            episodeId: request.plan.danmakuId,
            startMs: 0,
            nextMs: 30000,
            items: const [
              DanmakuItem(id: 'unavailable', text: original, timeMs: 0),
            ],
          );
        final controller = DanmakuController(repository)..setPlan(danmakuPlan);
        addTearDown(controller.dispose);
        updateDanmaku(controller);
        await flushDanmaku();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'UnavailableSyntheticEmojiFont'),
            home: Scaffold(
              body: DanmakuOverlay(
                controller: controller,
                aspectRatio: 16 / 9,
                mobile: platform == 'mobile',
                television: platform == 'television',
                desktop: platform == 'windows',
              ),
            ),
          ),
        );
        final line = find.byWidgetPredicate(
          (widget) => widget is DanmakuEmojiText && widget.text == original,
        );
        expect(line, findsOneWidget);
        final rendered = tester.widget<Text>(
          find.descendant(of: line, matching: find.byType(Text)),
        );
        expect(rendered.data ?? rendered.textSpan!.toPlainText(), original);
        expect(
          find.descendant(of: line, matching: find.byType(RawImage)),
          findsNothing,
        );
        expect(tester.getSize(line).width, greaterThan(0));
        expect(controller.items.single.text, original);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
