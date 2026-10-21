import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app_layout.dart';
import 'widgets.dart';

enum SwipeAction { none, brightness, volume, seek, episode }

class GestureHudState {
  const GestureHudState({this.type = SwipeAction.none, this.value = 0.0});
  final SwipeAction type;
  final double value; // 0.0 ~ 1.0
}

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.onSeek,
    this.onEpisodeSwipe,
    this.canNavigateEpisode,
    this.captureEpisodeFrame,
    this.initialUnmutedVolume = 100,
    this.onVolumeChanged,
  }) {
    _unmutedVolume = initialUnmutedVolume.clamp(1.0, 100.0);
    _playing = player.stream.playing.listen((playing) {
      if (!playing) cancel();
    });
    AppDevice.getBrightness()
        .then((val) {
          if (!_disposed) {
            _brightness = val;
            notifyListeners();
          }
        })
        .catchError((_) {});
  }

  final Player player;
  final double initialUnmutedVolume;
  final void Function(double, double)? onVolumeChanged;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function(int)? onEpisodeSwipe;
  final bool Function(int)? canNavigateEpisode;
  final Future<Uint8List?> Function()? captureEpisodeFrame;
  static const episodeTransitionDuration = Duration(milliseconds: 220);
  late final StreamSubscription<bool> _playing;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  VelocityTracker? _velocityTracker;
  double _episodePeakDrag = 0;
  double _swipeThreshold = 70;
  bool _swipeEnabled = false;
  bool _fullscreen = false;
  bool _adjustmentGestureAllowed = false;
  double _startX = 0;
  double _episodeDrag = 0;
  bool _episodeDragging = false;
  int _episodeCommit = 0;
  bool _episodeNavigationInFlight = false;
  bool _episodeAnimationComplete = false;
  int _episodeSwipeSequence = 0;
  Timer? _episodeTimer;
  Uint8List? _episodeFrameBytes;
  int _episodeFrameSequence = 0;
  int _volumeGeneration = 0;
  Future<void> _volumeRead = Future<void>.value();
  bool _volumeReadable = true;
  double? _pendingVolumeDelta;
  bool _writingVolume = false;

  double get episodeDrag => _episodeDrag;
  bool get episodeDragging => _episodeDragging;
  int get episodeCommit => _episodeCommit;
  bool get episodeSwipeBusy => _episodeCommit != 0;
  bool get episodeNavigationPending => _episodeNavigationInFlight;
  int get episodeSwipeSequence => _episodeSwipeSequence;
  Uint8List? get episodeFrameBytes => _episodeFrameBytes;
  bool canSwipeEpisode(int direction) =>
      canNavigateEpisode?.call(direction) ?? true;

  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  DateTime _ignoreTapUntil = DateTime(2000);
  SwipeAction _swipeAction = SwipeAction.none;
  GestureHudState _hudState = const GestureHudState();
  double _brightness = 0.5;
  double _initialBrightness = 0.5;
  double _initialVolume = 100;
  double _boostRate = 2;
  Duration _seekOrigin = Duration.zero;
  Duration? _seekTarget;
  double _viewWidth = 0.0;
  double _viewHeight = 0.0;
  Timer? _hudTimer;

  GestureHudState get hudState => _hudState;
  double get brightness => _brightness;
  bool get isBrightnessActive => _hudState.type == SwipeAction.brightness;

  void setBrightnessDirect(double value) {
    if (_disposed) return;
    _brightness = value.clamp(0.01, 1.0);
    AppDevice.setBrightness(_brightness);
    _showHud(SwipeAction.brightness, _brightness);
  }

  void dismissBrightnessHud() {
    _scheduleDismissHud();
  }

  String get feedback => _feedback;
  bool get boosting => _boosting;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void hint(String message, {bool persistent = false}) {
    if (_disposed) return;
    _hintTimer?.cancel();
    if (_feedback != message) {
      _feedback = message;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint(
          _boosting ? '${_boostRate.toStringAsFixed(0)} 倍速 · 松开恢复' : '',
          persistent: true,
        );
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 400), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _clearEpisodeFrame();
      _boosting = true;
      _held = true;
      _boostRate = math.max(baseSpeed(), keyboard ? 3 : 2);
      unawaited(_setRate(_boostRate));
      hint('${_boostRate.toStringAsFixed(0)} 倍速 · 松开恢复', persistent: true);
    });
  }

  void _endHold({bool tap = false, bool silent = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      if (!silent) {
        hint(_swipeEnabled && !wasKeyboard ? '' : '恢复 ${baseSpeed()} 倍速');
      }
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel() {
    if (_disposed) return;
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    if (!_episodeNavigationInFlight) {
      _episodeTimer?.cancel();
      _episodeDrag = 0;
      _episodeDragging = false;
      _episodeCommit = 0;
      _clearEpisodeFrame();
    }
    _pendingVolumeDelta = null;
    _volumeGeneration++;
    _pointer = null;
    _origin = null;
    _velocityTracker = null;
    _episodePeakDrag = 0;
    _seekTarget = null;
    _swipeAction = SwipeAction.none;
    _hudTimer?.cancel();
    _hudState = const GestureHudState();
    _endHold(silent: true);
    hint('');
    notifyListeners();
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    bool fullscreen = false,
    EdgeInsets reservedInsets = EdgeInsets.zero,
    double width = 0.0,
    required double height,
  }) {
    if (_disposed) return;
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel();
      return;
    }
    if (!available() || episodeSwipeBusy || event.buttons != kPrimaryButton) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _episodePeakDrag = 0;
    _startX = event.localPosition.dx;
    _fullscreen = fullscreen;
    final start = event.localPosition;
    _adjustmentGestureAllowed =
        start.dx >= math.max(32, reservedInsets.left + 12) &&
        start.dx <= width - math.max(32, reservedInsets.right + 12) &&
        start.dy >= math.max(24, reservedInsets.top + 12) &&
        start.dy <= height - math.max(24, reservedInsets.bottom + 12);
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _swipeThreshold = math.max(30, math.min(80, height * .08));
    _viewWidth = width;
    _viewHeight = height;
    _moved = _held = false;
    _swipeAction = SwipeAction.none;
    _initialBrightness = _brightness;
    _initialVolume = player.state.volume;
    _seekOrigin = player.state.position;
    _seekTarget = null;
    _clearEpisodeFrame();
    if (_swipeEnabled && !_fullscreen && captureEpisodeFrame != null) {
      unawaited(_captureEpisodeFrame(event.pointer));
    }
    final volumeTicket = ++_volumeGeneration;
    _volumeReadable = true;
    if (_swipeEnabled &&
        fullscreen &&
        _adjustmentGestureAllowed &&
        _startX >= width * .5 &&
        defaultTargetPlatform == TargetPlatform.android) {
      _volumeRead = AppDevice.getMediaVolume()
          .then((value) {
            if (!_disposed && volumeTicket == _volumeGeneration) {
              _initialVolume = value * 100;
            }
          })
          .catchError((Object _) {
            if (volumeTicket == _volumeGeneration) _volumeReadable = false;
          });
    } else {
      _volumeRead = Future<void>.value();
    }
    if (_swipeEnabled &&
        fullscreen &&
        _adjustmentGestureAllowed &&
        _startX < width * .5) {
      AppDevice.getBrightness().then((value) {
        if (_pointer == event.pointer && _swipeAction == SwipeAction.none) {
          _initialBrightness = _brightness = value;
        }
      });
    }
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_disposed) return;
    if (_pointer != event.pointer || _origin == null) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final diff = event.position - _origin!;
    if (diff.distance > 18) {
      _moved = true;
      _endHold();
    }
    if (!_swipeEnabled || !_moved || _held || _viewHeight <= 0) return;
    if (_swipeAction == SwipeAction.none) {
      final verticalSlop = _fullscreen ? 28 : 18;
      if (diff.dy.abs() >= verticalSlop &&
          diff.dy.abs() > diff.dx.abs() * 1.5) {
        if (_fullscreen && !_adjustmentGestureAllowed) return;
        _swipeAction = !_fullscreen
            ? SwipeAction.episode
            : _startX < _viewWidth * .5
            ? SwipeAction.brightness
            : SwipeAction.volume;
      } else if (diff.dx.abs() >= 28 &&
          diff.dx.abs() > diff.dy.abs() * 1.5 &&
          player.state.duration > Duration.zero) {
        _swipeAction = SwipeAction.seek;
        _clearEpisodeFrame();
      }
    }
    final dy = -diff.dy;
    final deltaRatio = dy / (_viewHeight * 0.6);

    if (_swipeAction == SwipeAction.episode) {
      _episodeDragging = true;
      if (_episodePeakDrag.sign != diff.dy.sign ||
          diff.dy.abs() > _episodePeakDrag.abs()) {
        _episodePeakDrag = diff.dy;
      }
      final direction = diff.dy < 0 ? 1 : -1;
      _episodeDrag = canSwipeEpisode(direction)
          ? diff.dy.clamp(-_viewHeight, _viewHeight)
          : (diff.dy * .22).clamp(-72.0, 72.0);
      notifyListeners();
    } else if (_swipeAction == SwipeAction.brightness) {
      _brightness = (_initialBrightness + deltaRatio).clamp(0.01, 1.0);
      AppDevice.setBrightness(_brightness);
      _showHud(SwipeAction.brightness, _brightness);
    } else if (_swipeAction == SwipeAction.volume) {
      _pendingVolumeDelta = deltaRatio;
      if (!_writingVolume) unawaited(_writeVolume());
    } else if (_swipeAction == SwipeAction.seek && _viewWidth > 0) {
      final range = math.min(120000, player.state.duration.inMilliseconds);
      final target = (_seekOrigin.inMilliseconds + diff.dx / _viewWidth * range)
          .round()
          .clamp(0, player.state.duration.inMilliseconds);
      _seekTarget = Duration(milliseconds: target);
      _showHud(SwipeAction.seek, target / 1000);
    }
  }

  void pointerUp(PointerUpEvent event) {
    if (_disposed) return;
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    final delta = event.position - _origin!;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final velocity =
        _velocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
    final vertical = delta.dy.abs() > delta.dx.abs() * 1.5;
    final fling =
        delta.dy.abs() >= 20 &&
        velocity.dy.abs() >= 650 &&
        velocity.dy.abs() > velocity.dx.abs() * 1.5 &&
        velocity.dy.sign == delta.dy.sign;
    final reversed =
        _episodePeakDrag.sign == delta.dy.sign &&
        _episodePeakDrag.abs() - delta.dy.abs() >= 24;
    final isVertical =
        vertical && !reversed && (delta.dy.abs() >= _swipeThreshold || fling);
    int? episodeDirection;

    if (_swipeAction == SwipeAction.episode &&
        _swipeEnabled &&
        !_held &&
        _moved &&
        isVertical &&
        available()) {
      final direction = delta.dy < 0 ? 1 : -1;
      if (canSwipeEpisode(direction)) {
        episodeDirection = direction;
      } else {
        hint(direction < 0 ? '已经是第一集' : '已经是最后一集');
      }
    } else if (_swipeAction == SwipeAction.seek &&
        _seekTarget != null &&
        available()) {
      unawaited((onSeek ?? player.seek)(_seekTarget!));
      _scheduleDismissHud();
    } else if (_swipeAction == SwipeAction.brightness ||
        _swipeAction == SwipeAction.volume) {
      _scheduleDismissHud();
    }

    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 250));
    }
    _episodeDragging = false;
    _pointer = null;
    _origin = null;
    _velocityTracker = null;
    _episodePeakDrag = 0;
    _seekTarget = null;
    _endHold();
    if (episodeDirection != null && onEpisodeSwipe != null) {
      _beginEpisodeSwipe(episodeDirection);
    } else {
      _episodeDrag = 0;
      _clearEpisodeFrame();
      if (episodeDirection != null) hint(onEpisode(episodeDirection));
      notifyListeners();
    }
  }

  Future<void> _captureEpisodeFrame(int pointer) async {
    final sequence = _episodeFrameSequence;
    try {
      final bytes = await captureEpisodeFrame!().timeout(
        const Duration(milliseconds: 180),
      );
      if (_disposed ||
          sequence != _episodeFrameSequence ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.lengthInBytes > 4 * 1024 * 1024 ||
          (_pointer != pointer &&
              (_episodeCommit == 0 || _episodeAnimationComplete))) {
        return;
      }
      _episodeFrameBytes = Uint8List.fromList(bytes).asUnmodifiableView();
      notifyListeners();
    } catch (_) {}
  }

  void _clearEpisodeFrame() {
    _episodeFrameSequence++;
    _episodeFrameBytes = null;
  }

  void _beginEpisodeSwipe(int direction) {
    _episodeCommit = direction;
    _episodeNavigationInFlight = true;
    _episodeAnimationComplete = false;
    final sequence = ++_episodeSwipeSequence;
    _episodeTimer?.cancel();
    _episodeTimer = Timer(episodeTransitionDuration, () {
      if (_disposed || sequence != _episodeSwipeSequence) return;
      _episodeAnimationComplete = true;
      _clearEpisodeFrame();
      _finishEpisodeSwipe();
      notifyListeners();
    });
    notifyListeners();
    unawaited(_navigateEpisode(direction, sequence));
  }

  Future<void> _navigateEpisode(int direction, int sequence) async {
    try {
      if (_disposed || sequence != _episodeSwipeSequence || !available()) {
        return;
      }
      await onEpisodeSwipe!(direction);
    } catch (_) {
      if (!_disposed && sequence == _episodeSwipeSequence) {
        hint('切换失败，请重试');
      }
    } finally {
      if (!_disposed && sequence == _episodeSwipeSequence) {
        _episodeNavigationInFlight = false;
        _finishEpisodeSwipe();
        notifyListeners();
      }
    }
  }

  void _finishEpisodeSwipe() {
    if (_episodeNavigationInFlight || !_episodeAnimationComplete) return;
    _episodeTimer?.cancel();
    _episodeTimer = null;
    _episodeDrag = 0;
    _episodeDragging = false;
    _episodeCommit = 0;
    if (!_disposed) notifyListeners();
  }

  Future<void> _writeVolume() async {
    _writingVolume = true;
    try {
      while (!_disposed && _pendingVolumeDelta != null) {
        final delta = _pendingVolumeDelta!;
        _pendingVolumeDelta = null;
        final ticket = _volumeGeneration;
        await _volumeRead;
        if (_disposed || ticket != _volumeGeneration) continue;
        if (!_volumeReadable) {
          hint('无法读取系统音量，请使用设备音量键');
          continue;
        }
        final target = (_initialVolume / 100 + delta).clamp(0.0, 1.0);
        try {
          double actual;
          if (defaultTargetPlatform == TargetPlatform.android) {
            actual = await AppDevice.setMediaVolume(target);
            if (ticket != _volumeGeneration || _disposed) continue;
            await player.setVolume(100);
          } else {
            await player.setVolume(target * 100);
            actual = target;
          }
          if (!_disposed && ticket == _volumeGeneration) {
            _showHud(SwipeAction.volume, actual);
            if (_pointer == null) _scheduleDismissHud();
          }
        } catch (_) {
          if (!_disposed && ticket == _volumeGeneration) {
            hint('系统音量未能调整，请使用设备音量键');
          }
        }
      }
    } finally {
      _writingVolume = false;
    }
  }

  void pointerCancel(PointerCancelEvent event) {
    if (_disposed) return;
    _pointers.remove(event.pointer);
    cancel();
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void _showHud(SwipeAction action, double value) {
    if (_disposed) return;
    _hudTimer?.cancel();
    _hudState = GestureHudState(type: action, value: value);
    notifyListeners();
  }

  void _scheduleDismissHud() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1000), () {
      if (_disposed) return;
      _hudState = const GestureHudState();
      notifyListeners();
    });
  }

  void seek(int seconds) {
    if (!available() || player.state.duration <= Duration.zero) return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('${seconds > 0 ? '快进至' : '后退至'} ${formatPosition(target / 1000)}');
  }

  void setVolume(double value) {
    if (!available()) return;
    final volume = value.clamp(0.0, 100.0);
    if (volume > 0) _unmutedVolume = volume;
    unawaited(player.setVolume(volume));
    onVolumeChanged?.call(volume, _unmutedVolume);
  }

  void changeVolume(double delta) {
    if (!available()) return;
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    setVolume(volume);
    hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
  }

  void toggleMute() {
    if (!available()) return;
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    setVolume(target);
    hint(target == 0 ? '已静音' : '音量 ${target.round()}%');
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    _clearEpisodeFrame();
    _episodeTimer?.cancel();
    _pendingVolumeDelta = null;
    _volumeGeneration++;
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    _hudTimer?.cancel();
    AppDevice.resetBrightness(); // 离开播放器时自动恢复手机/平板系统默认亮度
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
