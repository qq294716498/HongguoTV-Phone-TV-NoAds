import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_transport_controls_test.dart' show TransportFixture;
import 'player_fixtures.dart' show mockPlayerDevice;

void main() {
  setUp(mockPlayerDevice);
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);
  final chrome = find.byKey(const ValueKey('player-chrome'));
  final volume = find.byKey(const ValueKey('windows-volume'));
  final popup = find.byKey(const ValueKey('windows-volume-popup'));

  for (final playing in [false, true]) {
    testWidgets(
      'Windows ${playing ? 'playing' : 'paused'} keeps video bright and playback controls at bottom',
      (tester) async {
        final fixture = TransportFixture()
          ..background = const Color(0xFF6BCADE);
        await fixture.mount(tester, mobile: false, size: const Size(1000, 700));
        if (playing) await fixture.player.playOrPause();
        fixture.interactions.hint('合成视频校验 · 快进至 0:44');
        await tester.pump(const Duration(milliseconds: 200));
        final bottom = tester.getRect(
          find.byKey(const ValueKey('windows-toolbar-layout')),
        );
        expect(bottom.top, greaterThan(450));
        for (final id in [
          'windows-play',
          'windows-previous',
          'windows-next',
          'player-desktop-forward',
          'windows-volume',
          'player-speed',
          'player-episodes',
          'windows-settings',
          'player-fullscreen',
          'windows-player-feedback',
        ]) {
          expect(
            bottom.contains(tester.getCenter(find.byKey(ValueKey(id)))),
            isTrue,
            reason: id,
          );
        }
        final center = const Rect.fromLTWH(300, 150, 400, 300);
        for (final button in tester.widgetList<IconButton>(
          find.byType(IconButton),
        )) {
          expect(
            center.contains(tester.getCenter(find.byWidget(button))),
            isFalse,
          );
        }
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('transport-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (final sample in [
            const Offset(250, 200),
            const Offset(500, 350),
            const Offset(750, 450),
          ]) {
            final index =
                (sample.dy.toInt() * image.width + sample.dx.toInt()) * 4;
            expect(pixels.buffer.asUint8List(index, 4), [107, 202, 222, 255]);
          }
          final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
          if (directory != null) {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File(
              '$directory/windows-bottom-controls-${playing ? 'playing' : 'paused'}.png',
            ).writeAsBytes(bytes.buffer.asUint8List());
          }
          image.dispose();
        });
        expect(tester.takeException(), isNull);
        await fixture.unmount(tester);
      },
      variant: windows,
    );
  }

  testWidgets(
    'Windows groups transport controls and hides after two idle seconds',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, mobile: false);
      expect(find.byKey(const ValueKey('windows-play')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-desktop-forward')),
        findsOneWidget,
      );
      await fixture.player.playOrPause();
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 200));
      await mouse.moveTo(const Offset(301, 200));
      await tester.pump(const Duration(milliseconds: 1900));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      await tester.sendEventToBinding(
        const PointerHoverEvent(position: Offset(301, 200)),
      );
      await fixture.player.seek(const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 0);
      final ignoring = tester.widgetList<IgnorePointer>(
        find.ancestor(of: chrome, matching: find.byType(IgnorePointer)),
      );
      expect(ignoring.any((widget) => widget.ignoring), isTrue);
      await mouse.moveTo(const Offset(302, 200));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      await fixture.player.pause();
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 4));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      await fixture.unmount(tester);
    },
    variant: windows,
  );

  testWidgets(
    'hover volume opens above icon, stays open across bridge and remembers mute volume',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, mobile: false);
      fixture.interactions.setVolume(37);
      await fixture.player.playOrPause();
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 200));
      await mouse.moveTo(tester.getCenter(volume));
      await tester.pump();
      expect(popup, findsOneWidget);
      expect(
        tester.getRect(popup).bottom,
        lessThanOrEqualTo(tester.getRect(volume).top),
      );
      await mouse.moveTo(tester.getCenter(popup));
      await tester.pump(const Duration(seconds: 3));
      expect(popup, findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      await mouse.moveTo(tester.getCenter(volume));
      await tester.tap(volume);
      await tester.pump();
      expect(fixture.player.state.volume, 0);
      await tester.tap(volume);
      await tester.pump();
      expect(fixture.player.state.volume, 37);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('windows-volume-slider')),
      );
      slider.onChanged!(81);
      await tester.pump();
      expect(fixture.player.state.volume, 81);
      await mouse.moveTo(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 250));
      expect(popup, findsNothing);
      await mouse.removePointer();
      await fixture.unmount(tester);
    },
    variant: windows,
  );

  testWidgets(
    'keyboard focus opens volume and disposal cancels held overlays',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, mobile: false);
      final focus = tester.widget<IconButton>(volume).focusNode!;
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      focus.unfocus();
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      expect(popup, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(popup, findsNothing);
      await fixture.unmount(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
    variant: windows,
  );

  for (final size in [const Size(800, 600), const Size(1280, 720)]) {
    testWidgets('desktop layout and screenshot ${size.width}', (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, mobile: false, size: size);
      final directory = Platform.environment['HG_UI_CAPTURE_DIR'];
      if (directory != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('transport-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$directory/windows-controls-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await fixture.unmount(tester);
    }, variant: windows);
  }

  testWidgets(
    'menus and seek dragging hold controls, fullscreen transition closes volume',
    (tester) async {
      final fixture = TransportFixture();
      await fixture.mount(tester, mobile: false);
      await fixture.player.playOrPause();
      await tester.pump();
      final pending = Completer<void>();
      fixture.openMenu = () => pending.future;
      fixture.rebuild(() {});
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('windows-settings')));
      await tester.pump(const Duration(seconds: 4));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      pending.complete();
      await tester.pump();
      final progress = tester.widget<Slider>(
        find.byKey(const ValueKey('player-progress')),
      );
      progress.onChangeStart!(44);
      progress.onChanged!(44);
      await fixture.player.seek(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 4));
      expect(tester.widget<AnimatedOpacity>(chrome).opacity, 1);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('player-progress')))
            .value,
        44,
      );
      progress.onChangeEnd!(44);
      await tester.pump();
      expect(fixture.player.state.position.inSeconds, 44);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 200));
      await mouse.moveTo(tester.getCenter(volume));
      await tester.pump();
      expect(popup, findsOneWidget);
      fixture.rebuild(() => fixture.fullscreenValue = false);
      await tester.pump();
      await tester.pump();
      expect(popup, findsNothing);
      await mouse.removePointer();
      await fixture.unmount(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
    variant: windows,
  );
}
