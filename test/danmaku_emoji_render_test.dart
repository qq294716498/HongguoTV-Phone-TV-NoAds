import 'dart:async';
import 'dart:io';

import 'package:duanju_app/danmaku_emoji_assets.dart';
import 'package:duanju_app/danmaku_emoji_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_description_test.dart' show capture;
import 'windows_episode_sidebar_test.dart' show sidebarTheme;

class HoldingEmojiBundle extends CachingAssetBundle {
  final pending = Completer<ByteData>();
  int calls = 0;
  @override
  Future<ByteData> load(String key) {
    calls++;
    return pending.future;
  }
}

class FailingEmojiBundle extends CachingAssetBundle {
  int calls = 0;
  @override
  Future<ByteData> load(String key) async {
    calls++;
    throw StateError('Synthetic unavailable asset');
  }
}

Future<void> finishDecoding(
  WidgetTester tester,
  DanmakuEmojiCache cache,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (cache.loading && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(cache.loading, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = TextStyle(fontSize: 14, color: Colors.white);
  const scaler = TextScaler.noScaling;

  test(
    'only supported graphemes become images and ordinary text stays intact',
    () {
      final content = DanmakuEmojiContent.parse(
        '爽 怒 撇嘴 [未知] 😆😠😒 👩🏽‍💻 ♥ 3',
      );
      expect(content.parts.where((part) => part.asset != null), hasLength(3));
      expect(
        content.parts.map((part) => part.text).join(),
        '爽 怒 撇嘴 [未知] 😆😠😒 👩🏽‍💻 ♥ 3',
      );
      expect(DanmakuEmojiContent.parse('普通[未知]文字').hasImages, isFalse);
      expect(DanmakuEmojiContent.parse('👩🏽‍💻').parts.single.text, '👩🏽‍💻');
    },
  );

  testWidgets(
    'named aliases and compound expressions retain originals until every image is ready',
    (tester) async {
      final cache = DanmakuEmojiCache();
      addTearDown(cache.dispose);
      const text = '中文EN[笑][敬礼][什么][哭][戳手手][吃瓜][未收录][马上有福]end';
      final content = DanmakuEmojiContent.parse(text);
      if (Platform.environment['HG_UI_CAPTURE_DIR'] != null) {
        tester.view.physicalSize = const Size(1100, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('description-capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: await sidebarTheme(tester),
              home: Scaffold(
                body: Center(
                  child: AnimatedBuilder(
                    animation: cache,
                    builder: (context, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DanmakuEmojiText(
                          text: text,
                          style: Theme.of(context).textTheme.titleLarge!
                              .copyWith(fontSize: 24, color: Colors.white),
                          scaler: scaler,
                          cache: cache,
                        ),
                        const SizedBox(height: 20),
                        DanmakuEmojiText(
                          text: '力拔山兮气盖世\uFFFC',
                          style: Theme.of(context).textTheme.titleLarge!
                              .copyWith(fontSize: 24, color: Colors.white),
                          scaler: scaler,
                          cache: cache,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await capture(tester, 'danmaku-loading-fallback');
      }
      expect(content.parts.map((part) => part.text).join(), text);
      expect(content.span(style, scaler, cache).toPlainText(), text);
      expect(
        content.span(style, scaler, cache).children!.whereType<WidgetSpan>(),
        isEmpty,
      );
      cache.ensureLoaded([text]);
      await finishDecoding(tester, cache);
      expect(
        content.span(style, scaler, cache).children!.whereType<WidgetSpan>(),
        hasLength(7),
      );
      expect(
        content.span(style, scaler, cache).toPlainText(),
        contains('[未收录][马上有福]end'),
      );
      expect(
        content.parts.firstWhere((p) => p.text == '[戳手手]').glyphs,
        hasLength(2),
      );
      if (Platform.environment['HG_UI_CAPTURE_DIR'] != null) {
        await tester.pump();
        await capture(tester, 'danmaku-bundled-images');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'failed named assets keep the full mixed comment and explicit raw object fallback',
    (tester) async {
      final bundle = FailingEmojiBundle();
      final cache = DanmakuEmojiCache(bundle: bundle);
      addTearDown(cache.dispose);
      const text = '力拔EN[笑][敬礼][什么][哭][戳手手][吃瓜][未知][马上有福]\uFFFC';
      cache.ensureLoaded([text]);
      await finishDecoding(tester, cache);
      final content = DanmakuEmojiContent.parse(text);
      expect(content.parts.map((p) => p.text).join(), text);
      expect(
        content.span(style, scaler, cache).toPlainText(),
        '力拔EN[笑][敬礼][什么][哭][戳手手][吃瓜][未知][马上有福][OBJ]',
      );
      expect(
        content.span(style, scaler, cache).children!.whereType<WidgetSpan>(),
        isEmpty,
      );
      final calls = bundle.calls;
      cache.ensureLoaded([text]);
      expect(bundle.calls, calls);
      expect(cache.loading, isFalse);
    },
  );

  testWidgets(
    'eating-melon aliases share one bundled image and preserve every original token before load',
    (tester) async {
      final cache = DanmakuEmojiCache();
      addTearDown(cache.dispose);
      const text = '吃瓜EN[吃瓜][吃瓜群众]【吃瓜】［吃瓜］[西瓜][吃瓜未知]';
      final content = DanmakuEmojiContent.parse(text);
      expect(content.parts.map((part) => part.text).join(), text);
      expect(content.span(style, scaler, cache).toPlainText(), text);
      expect(content.parts.expand((part) => part.assets).toSet(), {
        '1f349.png',
      });
      cache.ensureLoaded([text]);
      await finishDecoding(tester, cache);
      expect(cache.imageCount, 1);
      expect(
        content.span(style, scaler, cache).children!.whereType<WidgetSpan>(),
        hasLength(5),
      );
      expect(
        content.span(style, scaler, cache).toPlainText(),
        startsWith('吃瓜EN'),
      );
      expect(
        content.span(style, scaler, cache).toPlainText(),
        endsWith('[吃瓜未知]'),
      );
    },
  );

  testWidgets(
    'all image decodes are bounded to 64px and the 145-asset inventory',
    (tester) async {
      final cache = DanmakuEmojiCache();
      addTearDown(cache.dispose);
      final text = DanmakuEmojiAssets.paths.keys.join();
      cache.ensureLoaded([text, text, '[未知]']);
      await finishDecoding(tester, cache);
      expect(cache.imageCount, 145);
      expect(cache.decodedBytes, lessThanOrEqualTo(145 * 64 * 64 * 4));
      for (final glyph in DanmakuEmojiAssets.paths.keys) {
        final image = cache.imageFor(glyph)!;
        expect(image.width, lessThanOrEqualTo(64));
        expect(image.height, lessThanOrEqualTo(64));
      }
      cache.ensureLoaded([text]);
      expect(cache.loading, isFalse);
      expect(cache.imageCount, 145);
    },
  );

  testWidgets(
    'first frame has a visible text fallback, then bundled inline images with cache-aware width',
    (tester) async {
      final bundle = HoldingEmojiBundle();
      final cache = DanmakuEmojiCache(bundle: bundle);
      addTearDown(cache.dispose);
      const text = '爽文 😆😠😒 [未知] ♥ 3';
      cache.ensureLoaded([text]);
      final before = DanmakuEmojiContent.parse(text).measure(style, scaler);
      Widget render() => MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: cache,
              builder: (context, _) => DanmakuEmojiText(
                text: text,
                style: style,
                scaler: scaler,
                cache: cache,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(render());
      final fallback = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == text),
      );
      expect(fallback.textSpan!.toPlainText(), contains('[大笑]'));
      expect(fallback.textSpan!.toPlainText(), isNot(contains('\uFFFC')));
      expect(find.byType(RawImage), findsNothing);
      await tester.runAsync(() async {
        bundle.pending.complete(
          await rootBundle.load('${DanmakuEmojiAssets.directory}1f606.png'),
        );
      });
      await finishDecoding(tester, cache);
      await tester.pump();
      expect(find.byType(RawImage), findsNWidgets(3));
      final after = DanmakuEmojiContent.parse(
        text,
      ).measure(style, scaler, cache: cache);
      expect(before, greaterThan(0));
      expect(after, greaterThan(0));
      expect(
        tester.getSize(find.byType(DanmakuEmojiText)).width,
        closeTo(after, .1),
      );
      final richText = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.semanticsLabel == text,
        ),
      );
      expect(richText.textSpan!.toPlainText(), contains('[未知] ♥ 3'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing or corrupt assets keep fallback text without repeated loads',
    (tester) async {
      final bundle = FailingEmojiBundle();
      final cache = DanmakuEmojiCache(bundle: bundle);
      addTearDown(cache.dispose);
      cache.ensureLoaded(['😆😆😆']);
      await finishDecoding(tester, cache);
      cache.ensureLoaded(['😆']);
      expect(bundle.calls, 1);
      expect(cache.imageCount, 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuEmojiText(
              text: '😆 [未知] 爽',
              style: style,
              scaler: scaler,
              cache: cache,
            ),
          ),
        ),
      );
      final fallback = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.semanticsLabel == '😆 [未知] 爽',
        ),
      );
      expect(fallback.textSpan!.toPlainText(), '[大笑] [未知] 爽');
      expect(
        (fallback.textSpan! as TextSpan).children!.whereType<WidgetSpan>(),
        isEmpty,
      );
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'decode concurrency is bounded and disposal ignores late asset responses',
    (tester) async {
      final bundle = HoldingEmojiBundle();
      final cache = DanmakuEmojiCache(bundle: bundle);
      var notifications = 0;
      cache.addListener(() => notifications++);
      cache.ensureLoaded([DanmakuEmojiAssets.paths.keys.join()]);
      expect(bundle.calls, DanmakuEmojiCache.maxConcurrentDecodes);
      cache.dispose();
      await tester.runAsync(() async {
        bundle.pending.complete(
          await rootBundle.load('${DanmakuEmojiAssets.directory}1f606.png'),
        );
      });
      await finishDecoding(tester, cache);
      expect(cache.imageCount, 0);
      expect(cache.decodedBytes, 0);
      expect(notifications, 0);
      cache.ensureLoaded(['😆']);
      expect(bundle.calls, DanmakuEmojiCache.maxConcurrentDecodes);
    },
  );
}
