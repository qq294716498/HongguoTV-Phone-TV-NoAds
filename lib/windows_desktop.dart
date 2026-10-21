import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'diary_service.dart';

class WindowsDesktop extends ChangeNotifier
    with WindowListener, WidgetsBindingObserver {
  WindowsDesktop(
    this.preferences, {
    WindowManager? manager,
    MethodChannel? channel,
    this.exitProcess,
  }) : manager = manager ?? windowManager,
       channel = channel ?? const MethodChannel('duanju/desktop');

  static WindowsDesktop? current;
  final SharedPreferences preferences;
  final WindowManager manager;
  final MethodChannel channel;
  final void Function(int)? exitProcess;
  bool available = false;
  bool inTray = false;
  bool mini = false;
  bool fullscreen = false;
  bool quitting = false;
  String? error;
  Object? playbackOwner;
  VoidCallback? togglePlayback;
  Future<void> Function()? pausePlayback;
  Future<void> Function()? savePlayback;
  Future<void> Function()? flushStore;
  Future<void> Function()? detachUI;
  Future<void> Function()? restoreUI;
  Future<void>? playbackDisposal;
  Rect? _bounds;
  bool _maximized = false;
  bool _topmost = false;
  bool _previousFullscreen = false;
  bool _restoring = false;
  Future<void> _operation = Future.value();

  bool get closeToTray => preferences.getBool('windows_close_to_tray') ?? true;
  bool get keepPlayback => !quitting && (inTray || mini || _restoring);

  Future<void> initialize() async {
    await manager.waitUntilReadyToShow();
    channel.setMethodCallHandler((call) async {
      if (call.method != 'trayAction') return;
      switch (call.arguments) {
        case 'restore':
          await restore();
        case 'toggle':
          if (!quitting) togglePlayback?.call();
        case 'quit':
          await quit();
      }
    });
    available = await channel.invokeMethod<bool>('initialize') ?? false;
    manager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    await manager.setPreventClose(true);
  }

  Future<void> setCloseToTray(bool value) async {
    if (!await preferences.setBool('windows_close_to_tray', value)) {
      throw StateError('关闭窗口偏好保存失败');
    }
    notifyListeners();
  }

  Future<void> updatePlayback({
    required bool attached,
    required bool playing,
  }) async {
    if (!available || quitting) return;
    await channel.invokeMethod<void>('setPlayback', {
      'attached': attached,
      'playing': playing,
    });
  }

  Future<void> _run(Future<void> Function() action) {
    final next = _operation.then((_) async {
      if (!quitting) await action();
    });
    _operation = next.catchError((Object failure) {
      error = '窗口操作失败：$failure';
      DiaryService.add('[Windows] $error');
      notifyListeners();
    });
    return next;
  }

  @override
  void onWindowClose() {
    unawaited(requestClose().catchError((Object _) {}));
  }

  Future<void> requestClose() => _run(() async {
    if (!closeToTray || !available) {
      await _quit();
      return;
    }
    await pausePlayback?.call();
    inTray = true;
    notifyListeners();
    try {
      await manager.setSkipTaskbar(true);
      await manager.hide();
    } catch (_) {
      inTray = false;
      await manager.setSkipTaskbar(false);
      notifyListeners();
      rethrow;
    }
  });

  Future<void> restore() => _run(() async {
    _restoring = inTray;
    await manager.setSkipTaskbar(false);
    if (await manager.isMinimized()) await manager.restore();
    await manager.show();
    await manager.focus();
    inTray = false;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)
      _restoring = false;
    notifyListeners();
  });

  Future<void> _setNativeFullscreen(bool value) async {
    await manager.setFullScreen(value);
    if (value) {
      await manager.setAsFrameless();
    } else {
      await manager.setTitleBarStyle(TitleBarStyle.normal);
    }
  }

  Future<void> enterMini({double aspectRatio = 16 / 9}) => _run(() async {
    if (mini || playbackOwner == null) return;
    _previousFullscreen = await manager.isFullScreen();
    if (_previousFullscreen) await _setNativeFullscreen(false);
    _maximized = await manager.isMaximized();
    if (_maximized) await manager.unmaximize();
    _bounds = await manager.getBounds();
    _topmost = await manager.isAlwaysOnTop();
    mini = true;
    fullscreen = false;
    notifyListeners();
    try {
      await manager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await manager.setMinimumSize(const Size(360, 240));
      await manager.setAlwaysOnTop(true);
      await manager.setBounds(
        Rect.fromLTWH(
          _bounds!.left,
          _bounds!.top,
          480,
          (480 / aspectRatio).clamp(240, 600),
        ),
      );
      await manager.show();
      await manager.focus();
    } catch (_) {
      await _leaveMini();
      rethrow;
    }
  });

  Future<void> _leaveMini({bool restoreFullscreen = true}) async {
    if (!mini) return;
    await _setNativeFullscreen(false);
    await manager.setAlwaysOnTop(_topmost);
    await manager.setMinimumSize(const Size(800, 600));
    if (_bounds != null) await manager.setBounds(_bounds!);
    if (_maximized) await manager.maximize();
    if (_previousFullscreen && restoreFullscreen)
      await _setNativeFullscreen(true);
    fullscreen = _previousFullscreen && restoreFullscreen;
    mini = false;
    notifyListeners();
  }

  Future<void> leaveMini() => _run(_leaveMini);

  Future<void> setFullscreen(bool value) => _run(() async {
    await _leaveMini(restoreFullscreen: false);
    await _setNativeFullscreen(value);
    fullscreen = value;
    notifyListeners();
  });

  Future<void> detachPlayback(Object owner) async {
    if (!identical(playbackOwner, owner)) return;
    playbackOwner = null;
    togglePlayback = null;
    pausePlayback = null;
    savePlayback = null;
    await _run(() async {
      await _leaveMini(restoreFullscreen: false);
      await _setNativeFullscreen(false);
      fullscreen = false;
      notifyListeners();
    });
    if (playbackOwner == null)
      await updatePlayback(attached: false, playing: false);
  }

  Future<void> prepareForUpdate() async {
    await _operation;
    quitting = true;
    try {
      await detachUI?.call();
      await playbackDisposal;
      await flushStore?.call();
      await channel.invokeMethod<void>('dispose');
      await manager.setPreventClose(false);
    } catch (_) {
      await cancelUpdateExit();
      rethrow;
    }
  }

  Future<void> cancelUpdateExit() async {
    available = await channel.invokeMethod<bool>('initialize') ?? false;
    await manager.setPreventClose(true);
    quitting = false;
    await restoreUI?.call();
    notifyListeners();
    if (inTray && !available) await restore();
  }

  Future<void> quit() => _run(_quit);

  Future<void> finishExit() async {
    if (exitProcess case final finish?) {
      finish(0);
    } else {
      await manager.destroy();
    }
  }

  Future<void> _quit() async {
    if (quitting) return;
    quitting = true;
    notifyListeners();
    try {
      await savePlayback?.call();
      await flushStore?.call();
      await detachUI?.call();
      await playbackDisposal;
      await flushStore?.call();
      await channel.invokeMethod<void>('dispose');
      await manager.setPreventClose(false);
      await finishExit();
    } catch (failure, stack) {
      available = false;
      try {
        available = await channel.invokeMethod<bool>('initialize') ?? false;
        await manager.setPreventClose(true);
      } catch (recoveryFailure) {
        DiaryService.add('[Windows] Exit recovery failed: $recoveryFailure');
      }
      quitting = false;
      try {
        await restoreUI?.call();
      } catch (recoveryFailure) {
        DiaryService.add('[Windows] UI recovery failed: $recoveryFailure');
      }
      notifyListeners();
      Error.throwWithStackTrace(failure, stack);
    }
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen = true;
    notifyListeners();
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen = false;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    manager.removeListener(this);
    channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restoring = false;
  }
}
