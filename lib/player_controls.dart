import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'lan_controller.dart';
import 'player_choice_menu.dart';
import 'playback_preferences.dart';
import 'windows_player_controls.dart';
import 'player_device_status.dart';
import 'player_interactions.dart';
import 'widgets.dart';
import 'video_enhancement.dart';

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    required this.onFullscreen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.title,
    this.episodeLabel = '',
    required this.onTogglePlayback,
    required this.onForward,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onQuality,
    required this.speed,
    required this.qualityLabel,
    required this.onFocusSurface,
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.danmakuStatus = '',
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.onSeek,
    this.onDanmaku,
    this.onSettings,
    this.onDanmakuSettings,
    this.desktopEpisodesExpanded,
    this.episodesTooltip,
    this.onSidebar,
    this.onMini,
    this.desktopMini = false,
    this.desktopActivityRevision = 0,
    this.onRetryDanmaku,
    this.onPush,
    this.onPictureInPicture,
    this.enhancement,
    this.portraitFooter,
    this.quietEpisodeChange,
    this.onSelectSpeed,
    this.onSelectQuality,
    this.qualities = const [],
    this.selectedQuality = 0,
  });

  final ValueChanged<double>? onSelectSpeed;
  final ValueChanged<int>? onSelectQuality;
  final List<int> qualities;
  final int selectedQuality;
  final Player player;
  final Future<void> Function()? onMini;
  final bool desktopMini;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final bool Function()? quietEpisodeChange;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String title;
  final String episodeLabel;
  final VoidCallback onTogglePlayback;
  final VoidCallback onForward;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSpeed;
  final Future<void> Function() onQuality;
  final double speed;
  final String qualityLabel;
  final VoidCallback onFocusSurface;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final String danmakuStatus;
  final bool swipeEnabled;
  final bool panelOpen;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function()? onDanmaku;
  final Future<void> Function()? onSettings;
  final Future<void> Function()? onDanmakuSettings;
  final bool? desktopEpisodesExpanded;
  final String? episodesTooltip;
  final Future<void> Function()? onSidebar;
  final int desktopActivityRevision;
  final Future<void> Function()? onRetryDanmaku;
  final Future<void> Function()? onPush;
  final Future<void> Function()? onPictureInPicture;
  final VideoEnhancementController? enhancement;
  final Widget? portraitFooter;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  bool _visible = true;
  bool _suppressAutoPlaybackStart = false;
  bool _lastPlaying = false;
  double? _seekValue;
  Offset? _doubleTapPosition;
  bool _locked = false;
  bool _choiceMenuOpen = false;

  @override
  void initState() {
    super.initState();
    _visible = widget.showOnPlaybackReady;
    _suppressAutoPlaybackStart = !widget.showOnPlaybackReady;
    _lastPlaying = widget.player.state.playing;
    for (final stream in [
      widget.player.stream.position,
      widget.player.stream.duration,
      widget.player.stream.buffer,
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.volume,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      widget.player.stream.playing.listen((playing) {
        final wasPlaying = _lastPlaying;
        _lastPlaying = playing;
        if (!mounted || !widget.enabled) return;
        if (widget.quietEpisodeChange?.call() ?? false) {
          if (_visible) setState(() => _visible = false);
          return;
        }
        if (!playing) {
          _show();
        } else if (!wasPlaying) {
          if (_suppressAutoPlaybackStart) {
            _suppressAutoPlaybackStart = false;
            _scheduleHide();
          } else {
            _show();
          }
        }
      }),
    );
    widget.interactions.addListener(_interactionChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      _seekValue = null;
      if (widget.showOnPlaybackReady) {
        _suppressAutoPlaybackStart = false;
      } else if (widget.enabled && !oldWidget.enabled) {
        _suppressAutoPlaybackStart = !widget.player.state.playing;
      } else if (!widget.enabled && oldWidget.enabled) {
        _suppressAutoPlaybackStart = true;
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        if (widget.showOnPlaybackReady) {
          _visible = true;
        } else {
          _visible = false;
        }
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      _scheduleHide();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    if (widget.interactions.boosting && _visible) {
      setState(() => _visible = false);
    }
    _scheduleHide();
  }

  void _choiceOpen(bool open) {
    _choiceMenuOpen = open;
    if (open) widget.interactions.cancel();
    _show();
  }

  Widget _speedChoice() => widget.onSelectSpeed == null
      ? _toolText(
          key: const ValueKey('player-speed'),
          tooltip: '倍速',
          label: '${widget.speed}x',
          width: 50,
          onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
        )
      : PlayerChoiceMenu<double>(
          buttonKey: const ValueKey('player-speed'),
          tooltip: '倍速',
          label: '${widget.speed}x',
          width: 50,
          values: playbackSpeeds.reversed.toList(),
          selected: widget.speed,
          format: (value) => '${value}x',
          enabled: widget.enabled,
          onSelected: widget.onSelectSpeed!,
          onOpenChanged: _choiceOpen,
        );

  Widget _qualityChoice() => widget.onSelectQuality == null
      ? _toolText(
          key: const ValueKey('player-quality'),
          tooltip: '清晰度',
          label: widget.qualityLabel,
          width: 52,
          onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
        )
      : PlayerChoiceMenu<int>(
          buttonKey: const ValueKey('player-quality'),
          tooltip: '清晰度',
          label: widget.qualityLabel,
          width: 72,
          values: [...widget.qualities, 0],
          selected: widget.selectedQuality,
          format: (value) => value == 0 ? '自动' : '${value}P',
          enabled: widget.enabled,
          onSelected: widget.onSelectQuality!,
          onOpenChanged: _choiceOpen,
        );

  void _scheduleHide() {
    _hideTimer?.cancel();
    if ((defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS) &&
        !widget.swipeEnabled)
      return;
    if (!widget.enabled ||
        widget.panelOpen ||
        _choiceMenuOpen ||
        !widget.player.state.playing ||
        _seekValue != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          widget.enabled &&
          !widget.panelOpen &&
          !_choiceMenuOpen &&
          widget.player.state.playing &&
          !widget.player.state.buffering &&
          !widget.interactions.boosting &&
          _seekValue == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  bool get _controlsVisible {
    final state = widget.player.state;
    return !_locked &&
        widget.enabled &&
        !(widget.quietEpisodeChange?.call() ?? false) &&
        (_visible ||
            (!_suppressAutoPlaybackStart &&
                (!state.playing || state.buffering)) ||
            widget.panelOpen);
  }

  void _tap() {
    if (widget.interactions.suppressTap) return;
    widget.onFocusSurface();
    if (_locked) return;
    if (widget.swipeEnabled && !widget.fullscreen && widget.enabled) {
      if (_controlsVisible) widget.onTogglePlayback();
      _show();
      return;
    }
    setState(() => _visible = !_visible);
    _scheduleHide();
  }

  void _toggleLock() {
    widget.interactions.cancel();
    setState(() {
      _locked = !_locked;
      _visible = !_locked;
    });
    _scheduleHide();
  }

  Future<void> _panel(Future<void> Function() open) async {
    _hideTimer?.cancel();
    widget.interactions.cancel();
    await open();
    _show();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.interactions.removeListener(_interactionChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if ((defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS) &&
        !widget.swipeEnabled) {
      return WindowsPlayerControls(controls: widget);
    }
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position = state.position.inMilliseconds / 1000;
    final buffered = state.buffer.inMilliseconds / 1000;
    final quiet = widget.quietEpisodeChange?.call() ?? false;
    final visible = _controlsVisible;
    return MouseRegion(
      onHover: (_) => _show(),
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('player-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (_locked) return;
                widget.onFocusSurface();
                widget.interactions.pointerDown(
                  event,
                  swipeEnabled: widget.swipeEnabled,
                  fullscreen: widget.fullscreen,
                  reservedInsets: MediaQuery.viewPaddingOf(context),
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                );
              },
              onPointerMove: _locked ? null : widget.interactions.pointerMove,
              onPointerUp: _locked ? null : widget.interactions.pointerUp,
              onPointerCancel: widget.interactions.pointerCancel,
              child: RawGestureDetector(
                gestures: widget.swipeEnabled && widget.enabled && !_locked
                    ? <Type, GestureRecognizerFactory>{
                        LongPressGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                              LongPressGestureRecognizer
                            >(
                              () => LongPressGestureRecognizer(
                                duration: const Duration(milliseconds: 400),
                                supportedDevices: const {
                                  PointerDeviceKind.touch,
                                },
                              ),
                              (recognizer) {
                                recognizer.onLongPress = () {};
                              },
                            ),
                      }
                    : const <Type, GestureRecognizerFactory>{},
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _tap,
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: () {
                    if (_locked ||
                        !widget.enabled ||
                        widget.interactions.suppressTap) {
                      return;
                    }
                    final x =
                        _doubleTapPosition?.dx ?? constraints.maxWidth / 2;
                    if (widget.swipeEnabled && x < constraints.maxWidth * .3) {
                      widget.interactions.seek(-15);
                    } else if (widget.swipeEnabled &&
                        x > constraints.maxWidth * .7) {
                      widget.interactions.seek(15);
                    } else {
                      widget.onTogglePlayback();
                    }
                    _show();
                  },
                ),
              ),
            ),
            if (state.buffering && widget.enabled && !quiet)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: AnimatedOpacity(
                  key: const ValueKey('player-chrome'),
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xAA000000),
                                Colors.transparent,
                                Color(0xE6000000),
                              ],
                              stops: [0, .45, 1],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          _topChromeInset(),
                          8,
                          _bottomChromeInset(),
                        ),
                        child: Stack(
                          children: [
                            if (widget.fullscreen || widget.swipeEnabled)
                              _topBar(visible: visible),
                            if (!state.buffering &&
                                widget.enabled &&
                                (!widget.swipeEnabled || !state.playing) &&
                                constraints.maxHeight >=
                                    (widget.swipeEnabled ? 168 : 220))
                              _centerPlayback(
                                state.playing,
                                showSkip: !widget.swipeEnabled,
                              ),
                            _sideDanmakuControl(),
                            _bottomControls(
                              constraints: constraints,
                              volume: state.volume,
                              duration: duration,
                              position: position,
                              buffered: buffered,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _gestureFeedback(),
            if (_locked)
              Positioned(
                top: _topChromeInset(),
                right: 12,
                child: _overlayIconButton(
                  tooltip: '解锁屏幕',
                  icon: Icons.lock_rounded,
                  onPressed: _toggleLock,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topBar({required bool visible}) {
    final compact = widget.swipeEnabled && !widget.fullscreen;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: compact ? 8 : 0),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: widget.fullscreen ? '退出全屏' : '返回',
              onPressed: widget.fullscreen
                  ? widget.onFullscreen
                  : widget.onBack,
              icon: widget.fullscreen
                  ? Icons.arrow_back_rounded
                  : Icons.arrow_back_ios_new_rounded,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      key: const ValueKey('player-header-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 16 : 20,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(
                            color: Colors.black,
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                    if (widget.episodeLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.episodeLabel,
                        key: const ValueKey('player-header-episode'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 14 : 17,
                          fontWeight: FontWeight.w700,
                          shadows: const [
                            Shadow(
                              color: Colors.black,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.swipeEnabled && widget.fullscreen)
              PlayerDeviceStatus(visible: visible),
            if (widget.swipeEnabled && widget.showDanmaku) _danmakuTool(),
            if (widget.swipeEnabled)
              _overlayIconButton(
                tooltip: '锁定屏幕',
                onPressed: widget.enabled ? _toggleLock : null,
                icon: Icons.lock_open_rounded,
              ),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(22),
      ),
      child: IconButton(
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    ),
  );

  Widget _centerPlayback(bool playing, {required bool showSkip}) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSkip) ...[
          IconButton(
            tooltip: '上一集',
            onPressed: widget.onPrevious,
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          const SizedBox(width: 12),
        ],
        IconButton.filledTonal(
          tooltip: playing ? '暂停播放' : '开始播放',
          iconSize: 38,
          onPressed: () {
            widget.onTogglePlayback();
            _show();
          },
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        if (showSkip) ...[
          const SizedBox(width: 12),
          IconButton(
            tooltip: '下一集',
            onPressed: widget.onNext,
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ],
    ),
  );

  Widget _sideDanmakuControl() {
    if (!widget.showDanmaku || widget.swipeEnabled) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(right: widget.swipeEnabled ? 0 : 4),
        child: _danmakuTool(),
      ),
    );
  }

  Widget _bottomControls({
    required BoxConstraints constraints,
    required double volume,
    required double duration,
    required double position,
    required double buffered,
  }) {
    final width = constraints.maxWidth;
    final fullscreen = widget.fullscreen;
    final mobile = widget.swipeEnabled;
    final showEpisodes = fullscreen;
    final showSpeedQuality =
        mobile || fullscreen && width >= 720 || !fullscreen && width >= 560;
    final showPush =
        widget.onPush != null &&
        (mobile || fullscreen && width >= 860 || !fullscreen && width >= 680);
    final showCompare = fullscreen && width >= 820;
    final showVolume = !widget.swipeEnabled && width >= 360;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mobile)
            _mobileControlRow(fullscreen: fullscreen)
          else
            _desktopControlRow(
              fullscreen: fullscreen,
              showEpisodes: showEpisodes,
              showSpeedQuality: showSpeedQuality,
              showPush: showPush,
              showCompare: showCompare,
              showVolume: showVolume,
              volume: volume,
            ),
          _progressRow(
            duration: duration,
            position: position,
            buffered: buffered,
          ),
          if (widget.portraitFooter != null) widget.portraitFooter!,
        ],
      ),
    );
  }

  double _topChromeInset() {
    if (widget.fullscreen) {
      final top = MediaQuery.paddingOf(context).top;
      if (top <= 0) return 16;
      return (top + 16).clamp(40.0, 80.0);
    }
    if (widget.swipeEnabled) {
      return 10;
    }
    return 0;
  }

  double _bottomChromeInset() {
    if (widget.fullscreen) {
      return (MediaQuery.viewPaddingOf(context).bottom + 24).clamp(64.0, 104.0);
    }
    return 0;
  }

  Widget _progressRow({
    required double duration,
    required double position,
    required double buffered,
  }) {
    final timeStyle = TextStyle(
      fontSize: 12,
      color: Colors.white.withValues(alpha: .82),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: 43,
              child: Text(
                formatPosition(_seekValue ?? position),
                style: timeStyle,
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('player-progress'),
                  value: (_seekValue ?? position).clamp(
                    0,
                    duration > 0 ? duration : 1,
                  ),
                  max: duration > 0 ? duration : 1,
                  secondaryTrackValue: buffered.clamp(
                    0,
                    duration > 0 ? duration : 1,
                  ),
                  semanticFormatterCallback: formatPosition,
                  onChangeStart: widget.enabled && duration > 0
                      ? (_) {
                          widget.interactions.cancel();
                          _hideTimer?.cancel();
                        }
                      : null,
                  onChanged: !widget.enabled || duration <= 0
                      ? null
                      : (value) {
                          _hideTimer?.cancel();
                          setState(() => _seekValue = value);
                        },
                  onChangeEnd: (value) {
                    if (widget.enabled && duration > 0) {
                      (widget.onSeek ?? widget.player.seek)(
                        Duration(milliseconds: (value * 1000).round()),
                      );
                    }
                    setState(() => _seekValue = null);
                    _show();
                  },
                ),
              ),
            ),
            SizedBox(
              width: 43,
              child: Text(formatPosition(duration), style: timeStyle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: Icon(icon, size: 22),
  );

  Widget _toolText({
    required Key key,
    required String tooltip,
    required String label,
    required VoidCallback? onPressed,
    double width = 52,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    visualWidth: width,
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    ),
  );

  Widget _toolButton({
    required Key key,
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
    double visualWidth = 36,
    VoidCallback? onLongPress,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = selected
        ? scheme.primary
        : Colors.white.withValues(alpha: enabled ? .92 : .36);
    final background = selected
        ? scheme.primary.withValues(alpha: .20)
        : Colors.black.withValues(alpha: .22);
    final border = selected
        ? scheme.primary.withValues(alpha: .62)
        : Colors.white.withValues(alpha: .08);
    final targetWidth = visualWidth < 40 ? 48.0 : visualWidth + 8;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        hint: onLongPress == null ? null : '长按打开弹幕设置',
        onLongPress: onLongPress,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          onLongPress: onLongPress,
          child: SizedBox(
            width: targetWidth,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: visualWidth,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: border),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 22),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13.5,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolGroup(List<Widget> children) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);

  Widget _lanPushTool(Key key) {
    final link = LanController.current;
    if (link == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) => _toolButton(
        key: key,
        tooltip: link.connection == null
            ? '推送'
            : '推送到 ${link.connection!.peer.name}',
        onPressed: widget.enabled ? () => _panel(widget.onPush!) : null,
        child: link.pushing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                link.connection == null
                    ? Icons.cast_rounded
                    : Icons.cast_connected_rounded,
                size: 22,
              ),
      ),
    );
  }

  Widget _clusteredToolRow(List<Widget> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    if (tools.length <= 5) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [_toolGroup(tools)],
      );
    }
    final leftCount = tools.length ~/ 2;
    return Row(
      children: [
        _toolGroup(tools.take(leftCount).toList()),
        const Spacer(),
        _toolGroup(tools.skip(leftCount).toList()),
      ],
    );
  }

  Widget _danmakuTool() => _toolButton(
    key: const ValueKey('player-danmaku-toggle'),
    tooltip: widget.danmakuStatus.isEmpty
        ? (widget.danmakuEnabled ? '关闭弹幕' : '打开弹幕')
        : widget.danmakuStatus,
    visualWidth: 36,
    selected: widget.danmakuEnabled,
    onPressed: widget.enabled
        ? () => _panel(widget.onRetryDanmaku ?? widget.onDanmaku!)
        : null,
    onLongPress: widget.enabled && !_locked && widget.onDanmakuSettings != null
        ? () => _panel(widget.onDanmakuSettings!)
        : null,
    child: widget.onRetryDanmaku != null
        ? const Icon(Icons.refresh_rounded, size: 21)
        : Text(
            '弹',
            style: TextStyle(
              fontSize: 14,
              height: 1,
              fontWeight: FontWeight.w800,
              color: widget.danmakuEnabled
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white.withValues(alpha: .86),
            ),
          ),
  );

  Widget _desktopControlRow({
    required bool fullscreen,
    required bool showEpisodes,
    required bool showSpeedQuality,
    required bool showPush,
    required bool showCompare,
    required bool showVolume,
    required double volume,
  }) {
    final tools = [
      _toolText(
        key: const ValueKey('player-desktop-forward'),
        tooltip: '快进15秒',
        label: '+15s',
        width: 42,
        onPressed:
            widget.enabled && widget.player.state.duration > Duration.zero
            ? () {
                widget.onForward();
                _show();
              }
            : null,
      ),
      if (showSpeedQuality) ...[_speedChoice(), _qualityChoice()],
      if (showPush) _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (showEpisodes)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (showCompare) _enhancementCompareButton(),
      if (showVolume)
        _toolIcon(
          key: const ValueKey('player-volume'),
          tooltip: '音量',
          icon: volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          onPressed: widget.enabled
              ? () => _panel(() => _openVolume(volume))
              : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
      _toolIcon(
        key: const ValueKey('player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '旋转与全屏',
        icon: fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        onPressed: widget.onFullscreen,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Widget _mobileControlRow({required bool fullscreen}) {
    final tools = [
      _toolIcon(
        key: const ValueKey('player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '全屏播放',
        icon: fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        onPressed: widget.onFullscreen,
      ),
      _toolIcon(
        key: const ValueKey('player-mobile-play'),
        tooltip: widget.player.state.playing ? '暂停播放' : '开始播放',
        icon: widget.player.state.playing
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        onPressed: widget.enabled
            ? () {
                widget.onTogglePlayback();
                _show();
              }
            : null,
      ),
      AbsorbPointer(
        absorbing:
            !widget.enabled || widget.player.state.duration <= Duration.zero,
        child: _toolText(
          key: const ValueKey('player-mobile-forward'),
          tooltip: '快进15秒',
          label: '+15s',
          width: 36,
          onPressed:
              widget.enabled && widget.player.state.duration > Duration.zero
              ? () {
                  widget.onForward();
                  _show();
                }
              : null,
        ),
      ),
      if (fullscreen)
        _toolIcon(
          key: const ValueKey('player-mobile-next'),
          tooltip: '下一集',
          icon: Icons.skip_next_rounded,
          onPressed: widget.enabled && widget.onNext != null
              ? () {
                  widget.onNext!();
                  _show();
                }
              : null,
        ),
      _speedChoice(),
      _qualityChoice(),
      if (widget.onPush != null)
        _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (fullscreen)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
    ];
    final transportCount = fullscreen ? 4 : 3;
    final transport = _toolGroup(tools.take(transportCount).toList());
    final options = _toolGroup(tools.skip(transportCount).toList());
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < tools.length * 48 + 12) {
            return Column(
              children: [
                Align(alignment: Alignment.centerLeft, child: transport),
                Align(alignment: Alignment.centerRight, child: options),
              ],
            );
          }
          return Row(children: [transport, const Spacer(), options]);
        },
      ),
    );
  }

  Future<void> _openVolume(double initialVolume) async {
    var volume = initialVolume.clamp(0.0, 100.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setState) => SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: widget.swipeEnabled ? 12 : 20,
                    bottom: widget.fullscreen ? 88 : 74,
                  ),
                  child: Material(
                    color: Colors.black.withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 62,
                      height: 192,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: volume == 0 ? '恢复音量' : '静音',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              final next = volume == 0 ? 100.0 : 0.0;
                              setState(() => volume = next);
                              unawaited(widget.player.setVolume(next));
                            },
                            icon: Icon(
                              volume == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  value: volume,
                                  max: 100,
                                  divisions: 20,
                                  onChanged: (value) {
                                    setState(() => volume = value);
                                    unawaited(widget.player.setVolume(value));
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: Center(
                              child: Text(
                                '${volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(.04, .08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
              child: child,
            ),
          ),
    );
  }

  Widget _enhancementCompareButton() {
    final enhancement = widget.enhancement;
    if (enhancement == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: enhancement,
      builder: (_, _) {
        if (!enhancement.canCompare) return const SizedBox.shrink();
        return _toolIcon(
          key: const ValueKey('player-enhancement-compare'),
          tooltip: enhancement.comparing ? '原画对比中，点击恢复增强' : '原画对比',
          icon: Icons.compare_rounded,
          onPressed: widget.enabled
              ? () {
                  widget.interactions.cancel();
                  unawaited(enhancement.toggleCompare());
                  _show();
                }
              : null,
          selected: enhancement.comparing,
        );
      },
    );
  }

  Widget _gestureFeedback() => AnimatedBuilder(
    animation: widget.interactions,
    builder: (context, _) {
      final hud = widget.interactions.hudState;
      final feedback = widget.interactions.feedback;
      if (hud.type == SwipeAction.seek) {
        return IgnorePointer(
          child: Center(
            child: Container(
              key: const ValueKey('player-seek-preview'),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.swipe_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${formatPosition(hud.value)} / ${formatPosition(widget.player.state.duration.inMilliseconds / 1000)}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '松开跳转',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (hud.type == SwipeAction.brightness ||
          hud.type == SwipeAction.volume) {
        final brightness = hud.type == SwipeAction.brightness;
        final value = hud.value.clamp(0.0, 1.0);
        final percent = (value * 100).round();
        final icon = !brightness
            ? (value == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded)
            : value < 0.33
            ? Icons.brightness_low_rounded
            : value < 0.66
            ? Icons.brightness_medium_rounded
            : Icons.brightness_high_rounded;
        return IgnorePointer(
          child: Center(
            child: Container(
              width: 120,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .75),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withValues(alpha: .15),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .4),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 36),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: 70,
                    height: 6,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: value,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${brightness ? '亮度' : '音量'} $percent%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (feedback.isEmpty) return const SizedBox.shrink();
      if (widget.swipeEnabled) {
        return IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                _bottomChromeInset() + 16,
              ),
              child: Text(
                feedback,
                key: const ValueKey('player-mobile-feedback'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xCCFFFFFF),
                  shadows: [Shadow(color: Color(0x77000000), blurRadius: 3)],
                ),
              ),
            ),
          ),
        );
      }
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.5),
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              feedback,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      );
    },
  );
}
