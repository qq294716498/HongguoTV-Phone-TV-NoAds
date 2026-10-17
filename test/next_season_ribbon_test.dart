import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(
    id: 'hongguo:ribbon',
    source: 'hongguo',
    title: '合成故事 第三季',
    episodes: 80,
  );
  final repository = FixtureRepository();
  for (final spec in [
    ('phone', const Size(320, 640), 132.0, false),
    ('phone-wide', const Size(390, 844), 170.0, false),
    ('windows-mini', const Size(480, 360), 132.0, false),
    ('windows', const Size(1280, 800), 180.0, false),
    ('tv', const Size(960, 540), 150.0, true),
    ('tv-wide', const Size(1280, 720), 180.0, true),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        '${spec.$1} ${dark ? 'dark' : 'light'} ribbon keeps layout, contrast, clicks and focus',
        (tester) async {
          tester.view.physicalSize = spec.$2;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final node = FocusNode();
          addTearDown(node.dispose);
          var tapped = 0;
          var theme = ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          );
          final font = Platform.environment['HG_UI_FONT'];
          if (font != null) {
            await tester.runAsync(() async {
              final data = await File(font).readAsBytes();
              await (FontLoader(
                'RibbonCJK',
              )..addFont(Future.value(ByteData.sublistView(data)))).load();
            });
            theme = theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'RibbonCJK'),
            );
          }
          Widget page(bool ribbon) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: AppLayout(
              television: spec.$4,
              child: Scaffold(
                body: Center(
                  child: Builder(
                    builder: (context) => RepaintBoundary(
                      key: const ValueKey('ribbon-capture'),
                      child: SizedBox(
                        width: spec.$3,
                        height:
                            DramaTile.extentFor(
                              context,
                              spec.$3 - (spec.$4 ? 14 : 0),
                            ) +
                            (spec.$4 ? 14 : 0),
                        child: DramaTile(
                          drama: drama,
                          repository: repository,
                          onTap: () => tapped++,
                          focusNode: node,
                          badge: ribbon ? '已有下季' : null,
                          badgeRibbon: ribbon,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpWidget(page(false));
          await tester.pumpAndSettle();
          final title = tester.getRect(find.text(drama.title));
          final cover = tester.getRect(find.byType(DramaCover));
          await tester.pumpWidget(page(true));
          await tester.pumpAndSettle();
          expect(tester.getRect(find.text(drama.title)), title);
          expect(tester.getRect(find.byType(DramaCover)), cover);
          expect(title.top, greaterThan(cover.bottom));
          final banner = tester.widget<Banner>(find.byType(Banner));
          expect(banner.message, '已有下季');
          expect(banner.location, BannerLocation.topStart);
          expect(banner.layoutDirection, TextDirection.ltr);
          expect(banner.textStyle.color, Colors.white);
          expect(
            1.05 / (banner.color.computeLuminance() + .05),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            find.ancestor(
              of: find.byType(Banner),
              matching: find.byType(IgnorePointer),
            ),
            findsWidgets,
          );
          await tester.tapAt(cover.topLeft + const Offset(25, 25));
          expect(tapped, 1);
          if (spec.$4) {
            node.requestFocus();
            await tester.pumpAndSettle();
            expect(node.hasFocus, true);
            final target = tester.getRect(find.byType(RemoteTarget));
            expect(cover.left - target.left, greaterThanOrEqualTo(7));
            expect(cover.top - target.top, greaterThanOrEqualTo(7));
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            expect(tapped, 2);
          }
          final directory = Platform.environment['HG_RIBBON_CAPTURE_DIR'];
          if (directory != null && dark) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('ribbon-capture')),
            );
            await tester.runAsync(() async {
              final picture = await boundary.toImage(pixelRatio: 2);
              final data = (await picture.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File(
                '$directory/${spec.$1}.png',
              ).writeAsBytes(data.buffer.asUint8List());
              picture.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
