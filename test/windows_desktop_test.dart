import 'dart:async';

import 'package:duanju_app/windows_desktop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DesktopHarness {
  final calls = <MethodCall>[];
  bool visible = true, topmost = false, fullscreen = false, maximized = false;
  bool trayAvailable = true;
  Map<String, double> bounds = {
    'x': 100,
    'y': 80,
    'width': 1200,
    'height': 720,
  };
  final original = {'x': 100.0, 'y': 80.0, 'width': 1200.0, 'height': 720.0};
  late WindowsDesktop desktop;
  Future<void> initialize() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          calls.add(call);
          switch (call.method) {
            case 'isMinimized':
              return false;
            case 'isFullScreen':
              return fullscreen;
            case 'isMaximized':
              return maximized;
            case 'isAlwaysOnTop':
              return topmost;
            case 'getBounds':
              return bounds;
            case 'setBounds':
              bounds = {
                for (final name in original.keys)
                  name: (call.arguments[name] as num).toDouble(),
              };
            case 'setAlwaysOnTop':
              topmost = call.arguments['isAlwaysOnTop'];
            case 'setFullScreen':
              fullscreen = call.arguments['isFullScreen'];
            case 'maximize':
              maximized = true;
            case 'unmaximize':
              maximized = false;
            case 'hide':
              visible = false;
            case 'show':
              visible = true;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('duanju/desktop'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'initialize') return trayAvailable;
          return null;
        });
    SharedPreferences.setMockInitialValues({});
    desktop = WindowsDesktop(await SharedPreferences.getInstance());
    await desktop.initialize();
  }

  Future<void> action(String action) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'duanju/desktop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('trayAction', action),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  void dispose() => desktop.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'close hides only, native menu restores, toggles and saves before actual destruction',
    () async {
      final harness = DesktopHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      var playing = true, saved = false, flushed = false;
      harness.desktop.togglePlayback = () => playing = !playing;
      harness.desktop.savePlayback = () async {
        saved = true;
      };
      harness.desktop.flushStore = () async {
        expect(saved, true);
        flushed = true;
      };
      await harness.desktop.requestClose();
      expect(harness.visible, false);
      expect(playing, true);
      expect(harness.desktop.keepPlayback, true);
      expect(harness.calls.where((call) => call.method == 'destroy'), isEmpty);
      await harness.action('toggle');
      expect(playing, false);
      await harness.action('restore');
      expect(harness.visible, true);
      expect(harness.desktop.inTray, false);
      await harness.action('quit');
      expect(saved && flushed, true);
      expect(harness.calls.last.method, 'destroy');
      expect(harness.calls[harness.calls.length - 3].method, 'dispose');
    },
  );
  test(
    'direct close preference and tray failure both exit without hiding',
    () async {
      for (final missing in [false, true]) {
        final harness = DesktopHarness()..trayAvailable = !missing;
        await harness.initialize();
        if (!missing) await harness.desktop.setCloseToTray(false);
        await harness.desktop.requestClose();
        expect(harness.visible, true);
        expect(harness.calls.last.method, 'destroy');
        harness.dispose();
      }
    },
  );
  test(
    'mini reuses playback, restores bounds, topmost, maximization and fullscreen repeatedly',
    () async {
      final harness = DesktopHarness();
      await harness.initialize();
      addTearDown(harness.dispose);
      final owner = Object();
      harness.desktop.playbackOwner = owner;
      for (final maximized in [false, true]) {
        for (final fullscreen in [false, true]) {
          harness.maximized = maximized;
          harness.fullscreen = fullscreen;
          for (var repeat = 0; repeat < 3; repeat++) {
            await harness.desktop.enterMini();
            expect(harness.desktop.playbackOwner, same(owner));
            expect(harness.topmost, true);
            expect(harness.fullscreen, false);
            expect(harness.bounds['width'], 480);
            await harness.desktop.leaveMini();
            expect(harness.bounds, harness.original);
            expect(harness.topmost, false);
            expect(harness.maximized, maximized);
            expect(harness.fullscreen, fullscreen);
          }
        }
      }
      await harness.desktop.enterMini();
      await harness.desktop.setFullscreen(true);
      expect(harness.desktop.mini, false);
      expect(harness.fullscreen, true);
      expect(harness.topmost, false);
    },
  );
  test('update bypasses close-to-tray and queued window actions', () async {
    final harness = DesktopHarness();
    await harness.initialize();
    addTearDown(harness.dispose);
    await harness.desktop.requestClose();
    await harness.desktop.prepareForUpdate();
    await harness.desktop.requestClose();
    await harness.desktop.restore();
    expect(harness.desktop.quitting, true);
    expect(harness.calls.last.method, 'setPreventClose');
    expect(harness.calls.last.arguments, {'isPreventClose': false});
    expect(harness.calls.where((call) => call.method == 'show'), isEmpty);
    await harness.desktop.cancelUpdateExit();
    expect(harness.desktop.quitting, false);
    expect(harness.calls.last.arguments, {'isPreventClose': true});
    await harness.action('restore');
    expect(harness.visible, true);
  });
}
