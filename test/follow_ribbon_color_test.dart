import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

const _drama = Drama(
  id: 'hongguo:color-ribbon',
  source: 'hongguo',
  title: '合成封面与长标题 第四十三季',
  episodes: 120,
  vip: true,
  category: '合成分类',
);

void main() {
  setUpAll(() async {
    for (final spec in [
      ('HG_UI_FONT', 'RibbonColorCJK'),
      ('HG_UI_ICON_FONT', 'MaterialIcons'),
    ]) {
      final path = Platform.environment[spec.$1];
      if (path != null) {
        await (FontLoader(spec.$2)..addFont(
              Future.value(
                ByteData.sublistView(await File(path).readAsBytes()),
              ),
            ))
            .load();
      }
    }
  });

  final repository = FixtureRepository();
  for (final screen in [
    ('phone320', const Size(320, 640), false),
    ('phone390', const Size(390, 844), false),
    ('tv960', const Size(960, 540), true),
  ]) {
    for (final scale in [1.0, 1.5]) {
      for (final darkTheme in [false, true]) {
        for (final darkCover in [false, true]) {
          final name =
              '${screen.$1}-font$scale-${darkTheme ? 'dark' : 'light'}-theme-${darkCover ? 'dark' : 'light'}-cover';
          testWidgets(name, (tester) async {
            tester.view.physicalSize = screen.$2;
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final nodes = List.generate(3, (_) => FocusNode());
            addTearDown(() {
              for (final node in nodes) {
                node.dispose();
              }
            });
            var tapped = 0;
            final coverColor = darkCover
                ? const Color(0xFF161616)
                : const Color(0xFFF4F4F4);
            var theme = ThemeData(
              brightness: darkTheme ? Brightness.dark : Brightness.light,
              fontFamily: Platform.environment['HG_UI_FONT'] == null
                  ? null
                  : 'RibbonColorCJK',
            );
            theme = theme.copyWith(
              colorScheme: theme.colorScheme.copyWith(
                surfaceContainerHighest: coverColor,
                surfaceContainer: coverColor,
              ),
            );
            if (screen.$3) theme = televisionTheme(theme);
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                home: AppLayout(
                  television: screen.$3,
                  child: RepaintBoundary(
                    key: const ValueKey('ribbon-color-capture'),
                    child: Scaffold(
                      body: Padding(
                        padding: const EdgeInsets.all(16),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            Widget tile(int index) => DramaTile(
                              key: ValueKey('ribbon-color-$index'),
                              drama: _drama,
                              repository: repository,
                              subtitle: '第 43 季 · 第 37 集',
                              badge: index == 0
                                  ? '已追剧'
                                  : index == 1
                                  ? '已有下季'
                                  : null,
                              focusNode: nodes[index],
                              onTap: () => tapped++,
                            );
                            if (screen.$3) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var index = 0; index < 3; index++)
                                    SizedBox(
                                      width: 160,
                                      height:
                                          DramaTile.extentFor(context, 146) +
                                          14,
                                      child: tile(index),
                                    ),
                                ],
                              );
                            }
                            return GridView.builder(
                              gridDelegate: dramaGridDelegate(
                                context,
                                constraints.maxWidth,
                              ),
                              itemCount: 3,
                              itemBuilder: (_, index) => tile(index),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            Finder tile(int index) =>
                find.byKey(ValueKey('ribbon-color-$index'));
            Finder inside(int index, Finder matching) =>
                find.descendant(of: tile(index), matching: matching).first;
            final followed = tester.widget<Banner>(
              inside(0, find.byType(Banner)),
            );
            final next = tester.widget<Banner>(inside(1, find.byType(Banner)));
            expect(followed.color, const Color(0xFFE0E0E0));
            expect(followed.textStyle.color, const Color(0xFF555555));
            expect(next.color, const Color(0xFFBF245B));
            expect(next.textStyle.color, Colors.white);
            expect(followed.color, isNot(next.color));
            for (final banner in [followed, next]) {
              expect(banner.color.toARGB32() >> 24, 255);
              expect(banner.textStyle.color!.toARGB32() >> 24, 255);
              final background = banner.color.computeLuminance();
              final foreground = banner.textStyle.color!.computeLuminance();
              final ratio = foreground > background
                  ? (foreground + .05) / (background + .05)
                  : (background + .05) / (foreground + .05);
              expect(ratio, greaterThanOrEqualTo(4.5));
              expect(banner.location, BannerLocation.topStart);
              expect(banner.layoutDirection, TextDirection.ltr);
              expect(banner.textStyle.fontSize, screen.$3 ? 12 : 11);
            }
            expect(
              followed.textStyle.copyWith(color: Colors.black),
              next.textStyle.copyWith(color: Colors.black),
            );
            expect(followed.shadow, next.shadow);
            final coverRects = [
              for (var index = 0; index < 3; index++)
                tester.getRect(inside(index, find.byType(DramaCover))),
            ];
            for (var index = 0; index < 3; index++) {
              final origin = tester.getRect(tile(index)).topLeft;
              final title = tester
                  .getRect(inside(index, find.text(_drama.title)))
                  .shift(-origin);
              final subtitle = tester
                  .getRect(inside(index, find.text('第 43 季 · 第 37 集')))
                  .shift(-origin);
              final firstOrigin = tester.getRect(tile(0)).topLeft;
              expect(
                coverRects[index].shift(-origin),
                rectMoreOrLessEquals(coverRects[0].shift(-firstOrigin)),
              );
              expect(
                title,
                rectMoreOrLessEquals(
                  tester
                      .getRect(inside(0, find.text(_drama.title)))
                      .shift(-firstOrigin),
                ),
              );
              expect(
                subtitle,
                rectMoreOrLessEquals(
                  tester
                      .getRect(inside(0, find.text('第 43 季 · 第 37 集')))
                      .shift(-firstOrigin),
                ),
              );
            }
            expect(
              tester.getRect(inside(0, find.text('VIP'))).top -
                  coverRects[0].top,
              tester.getRect(inside(1, find.text('VIP'))).top -
                  coverRects[1].top,
            );
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('ribbon-color-capture')),
            );
            await tester.runAsync(() async {
              final picture = await boundary.toImage(pixelRatio: 1);
              final rgba = await picture.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final imageOrigin = tester.getTopLeft(
                find.byKey(const ValueKey('ribbon-color-capture')),
              );
              for (var index = 0; index < 2; index++) {
                final point =
                    coverRects[index].topLeft -
                    imageOrigin +
                    const Offset(3, 42);
                final offset =
                    (point.dy.floor() * picture.width + point.dx.floor()) * 4;
                final pixel = Color.fromARGB(
                  rgba!.getUint8(offset + 3),
                  rgba.getUint8(offset),
                  rgba.getUint8(offset + 1),
                  rgba.getUint8(offset + 2),
                );
                expect(pixel, index == 0 ? followed.color : next.color);
              }
              final directory =
                  Platform.environment['HG_FOLLOW_RIBBON_COLOR_CAPTURE_DIR'];
              if (directory != null) {
                await Directory(directory).create(recursive: true);
                final png = await picture.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$directory/$name.png',
                ).writeAsBytes(png!.buffer.asUint8List());
              }
              picture.dispose();
            });
            if (screen.$3) {
              nodes[0].requestFocus();
              await tester.pumpAndSettle();
              expect(nodes[0].hasPrimaryFocus, true);
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
            } else {
              await tester.tapAt(coverRects[0].topLeft + const Offset(25, 25));
            }
            expect(tapped, 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          });
        }
      }
    }
  }
}
