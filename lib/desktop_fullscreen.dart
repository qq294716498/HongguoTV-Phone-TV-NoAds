import 'dart:async';

import 'package:window_manager/window_manager.dart';

class DesktopFullscreen with WindowListener {
  DesktopFullscreen._() {
    windowManager.addListener(this);
  }

  static final instance = DesktopFullscreen._();
  Future<void> _pending = Future<void>.value();
  Completer<void>? _transition;
  bool? _target;

  Future<void> set(bool enabled) {
    final next = _pending.catchError((Object _) {}).then((_) async {
      if (await windowManager.isFullScreen() == enabled) return;
      final transition = Completer<void>();
      _transition = transition;
      _target = enabled;
      try {
        await windowManager.setFullScreen(enabled);
        await transition.future.timeout(const Duration(seconds: 10));
      } finally {
        _transition = null;
        _target = null;
      }
    });
    _pending = next;
    return next;
  }

  void _complete(bool enabled) {
    if (_target == enabled && _transition?.isCompleted == false) {
      _transition!.complete();
    }
  }

  @override
  void onWindowEnterFullScreen() => _complete(true);

  @override
  void onWindowLeaveFullScreen() => _complete(false);
}
