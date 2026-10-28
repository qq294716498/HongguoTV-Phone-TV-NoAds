import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/desktop_fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fullscreen requests wait for native completion before reversing',
    () async {
      var fullscreen = false;
      final requests = <bool>[];
      const channel = MethodChannel('window_manager');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'isFullScreen') return fullscreen;
            if (call.method == 'setFullScreen') {
              fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
              requests.add(fullscreen);
            }
            return null;
          });
      final controller = DesktopFullscreen.instance;
      var entered = false;
      final enter = controller.set(true).then((_) => entered = true);
      final leave = controller.set(false);
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true]);
      expect(entered, false);
      controller.onWindowEnterFullScreen();
      await enter;
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true, false]);
      controller.onWindowLeaveFullScreen();
      await leave;
      await controller.set(false);
      expect(requests, [true, false]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
}
