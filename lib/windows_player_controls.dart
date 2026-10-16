import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_controls.dart';
import 'widgets.dart';

class WindowsPlayerControls extends StatefulWidget {
  const WindowsPlayerControls({super.key, required this.controls});
  final PlayerControls controls;

  @override
  State<WindowsPlayerControls> createState() => _WindowsPlayerControlsState();
}

class _WindowsPlayerControlsState extends State<WindowsPlayerControls> {
  final _volumeOverlay = OverlayPortalController();
  final _volumeLink = LayerLink();
  final _volumeFocus = FocusNode(debugLabel: 'windows-volume');
  final _volumeSliderFocus = FocusNode(debugLabel: 'windows-volume-slider');
  final _toolbarFocus = FocusNode(debugLabel: 'windows-player-toolbar');
  final _sidebarFocus = FocusNode(debugLabel: 'windows-sidebar-toggle');
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  Timer? _volumeCloseTimer;
  Offset? _lastMouse;
  bool _visible = true;
  bool _hoveringToolbar = false;
  bool _hoveringSidebar = false;
  bool _hoveringVolume = false;
  bool _hoveringPopup = false;
  bool _volumeDragging = false;
  bool _menuOpen = false;
  bool _keyboard = false;
  double? _seek;
  bool _lastPlaying = false;
  bool _lastBoosting = false;

  PlayerControls get c => widget.controls;
  bool get _popup => _volumeOverlay.isShowing;
  bool get _held =>
      _hoveringToolbar ||
      _hoveringSidebar ||
      _popup ||
      _menuOpen ||
      c.panelOpen ||
      _seek != null ||
      _volumeDragging ||
      c.interactions.boosting ||
      (_keyboard && (_toolbarFocus.hasFocus || _sidebarFocus.hasFocus));
  bool get _shown =>
      c.enabled && (_visible || c.player.state.buffering || _held);

  @override
  void initState() {
    super.initState();
    _visible = c.showOnPlaybackReady;
    _lastPlaying = c.player.state.playing;
    for (final stream in [
      c.player.stream.position,
      c.player.stream.duration,
      c.player.stream.buffer,
      c.player.stream.volume,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      c.player.stream.buffering.listen((_) {
        if (!mounted) return;
        setState(() {});
        _scheduleHide();
      }),
    );
    _subscriptions.add(
      c.player.stream.playing.listen((playing) {
        if (!mounted) return;
        final changed = _lastPlaying != playing;
        _lastPlaying = playing;
        if (changed) _show();
        setState(() {});
      }),
    );
    c.interactions.addListener(_interactionChanged);
    _volumeFocus.addListener(_volumeFocusChanged);
    _volumeSliderFocus.addListener(_volumeFocusChanged);
    _sidebarFocus.addListener(_show);
    FocusManager.instance.addEarlyKeyEventHandler(_earlyKey);
    _scheduleHide();
  }

  void _interactionChanged() {
    if (!mounted) return;
    if (_lastBoosting != c.interactions.boosting) {
      _lastBoosting = c.interactions.boosting;
      _show();
    }
    setState(() {});
  }

  void _volumeFocusChanged() {
    if (_volumeFocus.hasFocus || _volumeSliderFocus.hasFocus) {
      _openVolume();
    } else {
      _closeVolumeLater();
    }
  }

  KeyEventResult _earlyKey(KeyEvent event) {
    if ((_toolbarFocus.hasFocus || Focus.maybeOf(context)?.hasFocus == true) &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      _keyboard = true;
      _show();
      if (_volumeFocus.hasFocus || _volumeSliderFocus.hasFocus) _openVolume();
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(WindowsPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controls.fullscreen != c.fullscreen ||
        oldWidget.controls.enabled != c.enabled) {
      _hideTimer?.cancel();
      _volumeCloseTimer?.cancel();
      _hoveringPopup = _hoveringVolume = _volumeDragging = false;
      _seek = null;
      _visible = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _closeVolume();
        _scheduleHide();
      });
    } else if (oldWidget.controls.panelOpen != c.panelOpen ||
        oldWidget.controls.desktopActivityRevision !=
            c.desktopActivityRevision) {
      _show();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!mounted || !c.enabled || _held) return;
    _hideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_held && c.enabled && !c.player.state.buffering) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _hover(PointerHoverEvent event) {
    if (event.position == _lastMouse) return;
    _lastMouse = event.position;
    _show();
  }

  void _openVolume() {
    if (!c.enabled || !mounted) return;
    _volumeCloseTimer?.cancel();
    if (!_popup) _volumeOverlay.show();
    _show();
  }

  void _closeVolume() {
    if (_popup) _volumeOverlay.hide();
  }

  void _closeVolumeLater() {
    _volumeCloseTimer?.cancel();
    _volumeCloseTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted ||
          _hoveringVolume ||
          _hoveringPopup ||
          _volumeDragging ||
          (_keyboard && (_volumeFocus.hasFocus || _volumeSliderFocus.hasFocus)))
        return;
      _closeVolume();
      if (!_keyboard) c.onFocusSurface();
      _scheduleHide();
    });
  }

  Future<void> _panel(Future<void> Function() open) async {
    _hideTimer?.cancel();
    _closeVolume();
    setState(() {
      _menuOpen = true;
      _visible = true;
    });
    c.interactions.cancel();
    try {
      await open();
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        c.onFocusSurface();
        _show();
      }
    }
  }

  void _action(VoidCallback action) {
    action();
    if (!_keyboard) c.onFocusSurface();
    _show();
  }

  Widget _button(
    String id,
    String tooltip,
    IconData icon,
    VoidCallback? action, {
    bool selected = false,
    FocusNode? focus,
  }) => IconButton(
    key: ValueKey(id),
    focusNode: focus,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 34, height: 32),
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    padding: EdgeInsets.zero,
    onPressed: c.enabled && action != null ? () => _action(action) : null,
    color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
    disabledColor: Colors.white30,
    icon: Icon(
      icon,
      size: 21,
      shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
    ),
  );

  Widget _volume() => OverlayPortal(
    key: const ValueKey('windows-volume-portal'),
    controller: _volumeOverlay,
    overlayChildBuilder: (_) => CompositedTransformFollower(
      link: _volumeLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topCenter,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(-33, -202),
      child: Align(
        alignment: Alignment.topLeft,
        widthFactor: 1,
        heightFactor: 1,
        child: MouseRegion(
          onEnter: (_) {
            _hoveringPopup = true;
            _volumeCloseTimer?.cancel();
          },
          onExit: (_) {
            _hoveringPopup = false;
            _closeVolumeLater();
          },
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              key: const ValueKey('windows-volume-popup'),
              elevation: 8,
              color: const Color(0xF21C2028),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 66,
                height: 196,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Text(
                      '${c.player.state.volume.clamp(0, 100).round()}%',
                      key: const ValueKey('windows-volume-percent'),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: Slider(
                          value: c.player.state.volume.clamp(0, 100),
                          max: 100,
                          divisions: 100,
                          key: const ValueKey('windows-volume-slider'),
                          focusNode: _volumeSliderFocus,
                          semanticFormatterCallback: (value) =>
                              '音量 ${value.round()}%',
                          onChangeStart: (_) {
                            _volumeDragging = true;
                            _hideTimer?.cancel();
                          },
                          onChanged: (value) {
                            c.interactions.setVolume(value);
                            _show();
                          },
                          onChangeEnd: (_) {
                            _volumeDragging = false;
                            _closeVolumeLater();
                            _show();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    child: CompositedTransformTarget(
      link: _volumeLink,
      child: MouseRegion(
        onEnter: (_) {
          _hoveringVolume = true;
          _openVolume();
        },
        onExit: (_) {
          _hoveringVolume = false;
          _closeVolumeLater();
        },
        child: _button(
          'windows-volume',
          c.player.state.volume == 0 ? '恢复音量 (M)' : '静音 (M)',
          c.player.state.volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          c.interactions.toggleMute,
          focus: _volumeFocus,
        ),
      ),
    ),
  );

  Widget _progress() {
    final state = c.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position = state.position.inMilliseconds / 1000;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              formatPosition(_seek ?? position),
              key: const ValueKey('windows-position'),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                secondaryActiveTrackColor: Colors.white38,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 4.5,
                ),
              ),
              child: Slider(
                key: const ValueKey('player-progress'),
                value: (_seek ?? position).clamp(
                  0,
                  duration > 0 ? duration : 1,
                ),
                max: duration > 0 ? duration : 1,
                secondaryTrackValue: (state.buffer.inMilliseconds / 1000).clamp(
                  0,
                  duration > 0 ? duration : 1,
                ),
                semanticFormatterCallback: formatPosition,
                onChangeStart: c.enabled && duration > 0
                    ? (value) {
                        c.interactions.cancel();
                        setState(() => _seek = value);
                        _hideTimer?.cancel();
                      }
                    : null,
                onChanged: c.enabled && duration > 0
                    ? (value) => setState(() => _seek = value)
                    : null,
                onChangeEnd: (value) async {
                  try {
                    if (c.enabled && duration > 0)
                      await (c.onSeek ?? c.player.seek)(
                        Duration(milliseconds: (value * 1000).round()),
                      );
                  } finally {
                    if (mounted) {
                      setState(() => _seek = null);
                      _show();
                    }
                  }
                },
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              formatPosition(duration),
              key: const ValueKey('windows-duration'),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() => Focus(
    focusNode: _toolbarFocus,
    onFocusChange: (_) {
      if (mounted) {
        _show();
        _closeVolumeLater();
      }
    },
    child: MouseRegion(
      onEnter: (_) {
        _hoveringToolbar = true;
        _show();
      },
      onExit: (_) {
        _hoveringToolbar = false;
        _scheduleHide();
      },
      child: DecoratedBox(
        key: const ValueKey('windows-toolbar-background'),
        decoration: BoxDecoration(
          color: const Color(0x66151820),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: Colors.white70,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
              shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _progress(),
                if (c.interactions.feedback.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      c.interactions.feedback,
                      key: const ValueKey('windows-player-feedback'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 3,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _button(
                          'windows-previous',
                          '上一集',
                          Icons.skip_previous_rounded,
                          c.onPrevious,
                        ),
                        _button(
                          'windows-play',
                          c.player.state.playing ? '暂停 (空格)' : '播放 (空格)',
                          c.player.state.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          c.onTogglePlayback,
                        ),
                        TextButton(
                          key: const ValueKey('player-desktop-forward'),
                          onPressed:
                              c.enabled &&
                                  c.player.state.duration > Duration.zero
                              ? () => _action(c.onForward)
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(42, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: const Tooltip(
                            message: '快进15秒',
                            child: Text('+15s'),
                          ),
                        ),
                        _button(
                          'windows-next',
                          '下一集',
                          Icons.skip_next_rounded,
                          c.onNext,
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.showDanmaku) ...[
                          _button(
                            'windows-danmaku-toggle',
                            c.danmakuEnabled ? '关闭弹幕' : '开启弹幕',
                            Icons.subtitles_rounded,
                            c.onDanmaku == null
                                ? null
                                : () => _panel(c.onDanmaku!),
                            selected: c.danmakuEnabled,
                          ),
                        ],
                        TextButton(
                          key: const ValueKey('player-speed'),
                          onPressed: c.enabled ? () => _panel(c.onSpeed) : null,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(44, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: Tooltip(
                            message: '播放倍速',
                            child: Text('${c.speed}x'),
                          ),
                        ),
                        _button(
                          'player-episodes',
                          '选集 / 查看全季',
                          Icons.grid_view_rounded,
                          () => _panel(c.onEpisodes),
                        ),
                        _volume(),
                        if (c.onPush != null)
                          _button(
                            'windows-lan-push',
                            '推送到局域网设备',
                            Icons.cast_rounded,
                            () => _panel(c.onPush!),
                          ),
                        _button(
                          'windows-settings',
                          '播放设置',
                          Icons.tune_rounded,
                          () => _panel(c.onSettings ?? c.onQuality),
                        ),
                        if (c.onMini != null)
                          _button(
                            'windows-mini-control',
                            c.desktopMini ? '返回原窗口' : '迷你窗（置顶）',
                            c.desktopMini
                                ? Icons.open_in_full_rounded
                                : Icons.picture_in_picture_alt_rounded,
                            () => _panel(c.onMini!),
                          ),
                        _button(
                          'player-fullscreen',
                          c.fullscreen ? '退出全屏 (F11)' : '全屏 (F11)',
                          c.fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          c.onFullscreen,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final visible = _shown;
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          _keyboard = true;
          _show();
          if (_popup && event.logicalKey == LogicalKeyboardKey.escape) {
            _closeVolume();
            c.onFocusSurface();
            _scheduleHide();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        onPointerDown: (_) {
          _keyboard = false;
          _show();
        },
        child: MouseRegion(
          onHover: _hover,
          onEnter: (_) => _show(),
          onExit: (_) {
            _scheduleHide();
          },
          cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  key: const ValueKey('player-gesture-surface'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _action(c.onTogglePlayback),
                  onDoubleTap: () => _action(c.onFullscreen),
                ),
                if (c.player.state.buffering && c.enabled)
                  const IgnorePointer(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                IgnorePointer(
                  key: const ValueKey('windows-player-chrome-layer'),
                  ignoring: !visible,
                  child: ExcludeFocus(
                    excluding: !visible,
                    child: AnimatedOpacity(
                      key: const ValueKey('player-chrome'),
                      opacity: visible ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Stack(
                        children: [
                          if (c.fullscreen || c.desktopMini)
                            Positioned(
                              top: 12,
                              left: 12,
                              right: 12,
                              child: Row(
                                children: [
                                  _button(
                                    'windows-back',
                                    '返回',
                                    Icons.arrow_back_rounded,
                                    c.onBack,
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${c.title} · ${c.episodeLabel}',
                                      key: const ValueKey(
                                        'windows-player-title',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Positioned(
                            key: const ValueKey('windows-toolbar-layout'),
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: _toolbar(),
                          ),
                          if (c.onSidebar != null)
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: MouseRegion(
                                  onEnter: (_) {
                                    _hoveringSidebar = true;
                                    _show();
                                  },
                                  onExit: (_) {
                                    _hoveringSidebar = false;
                                    _scheduleHide();
                                  },
                                  child: Material(
                                    color: const Color(0x66151820),
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(8),
                                    ),
                                    child: SizedBox(
                                      width: 28,
                                      height: 52,
                                      child: IconButton(
                                        key: const ValueKey(
                                          'windows-episode-toggle',
                                        ),
                                        focusNode: _sidebarFocus,
                                        tooltip: c.episodesTooltip ?? '打开选集',
                                        padding: EdgeInsets.zero,
                                        icon: Icon(
                                          c.desktopEpisodesExpanded == true
                                              ? Icons.chevron_right_rounded
                                              : Icons.chevron_left_rounded,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                        onPressed: () => _panel(c.onSidebar!),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _volumeCloseTimer?.cancel();
    c.interactions.removeListener(_interactionChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _volumeFocus.dispose();
    _volumeSliderFocus.dispose();
    _toolbarFocus.dispose();
    _sidebarFocus.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_earlyKey);
    super.dispose();
  }
}
