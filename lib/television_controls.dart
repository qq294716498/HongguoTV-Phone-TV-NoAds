import 'tv_decoder_settings.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'playback_preferences.dart';
import 'video_enhancement.dart';
import 'video_enhancement_preferences.dart';
import 'video_enhancement_settings.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'diary_service.dart';

class TelevisionControls extends StatefulWidget {
  const TelevisionControls({
    super.key,
    required this.player,
    required this.title,
    required this.enabled,
    required this.showOnPlaybackReady,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onEpisodes,
    required this.onSettings,
    required this.onBack,
    this.onDiary,
    this.onSeekTo,
    this.onVisibilityChanged,
    this.speed = 1,
    this.qualityLabel = '',
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.onDanmaku,
    this.enhancement,
    this.quietEpisodeChange,
  });
  final Player player;
  final String title;
  final bool enabled;
  final bool showOnPlaybackReady;
  final bool Function()? quietEpisodeChange;
  final VoidCallback onTogglePlayback;
  final ValueChanged<int> onSeek;
  final Future<void> Function(Duration)? onSeekTo;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSettings;
  final VoidCallback onBack;
  final Future<void> Function()? onDiary;
  final ValueChanged<bool>? onVisibilityChanged;
  final double speed;
  final String qualityLabel;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final Future<void> Function()? onDanmaku;
  final VideoEnhancementController? enhancement;

  @override
  State<TelevisionControls> createState() => TelevisionControlsState();
}

class TelevisionControlsState extends State<TelevisionControls>
    with WidgetsBindingObserver {
  final _surface = FocusNode(debugLabel: 'tv-player-surface');
  final _play = FocusNode(debugLabel: 'tv-player-play');
  final _episodes = FocusNode(debugLabel: 'tv-player-episodes');
  final _settings = FocusNode(debugLabel: 'tv-player-settings');
  final _diary = FocusNode(debugLabel: 'tv-player-diary');
  final _progress = FocusNode(debugLabel: 'tv-player-progress');
  final _rewind = FocusNode(debugLabel: 'tv-player-rewind');
  final _forward = FocusNode(debugLabel: 'tv-player-forward');
  final _previous = FocusNode(debugLabel: 'tv-player-previous');
  final _next = FocusNode(debugLabel: 'tv-player-next');
  final _danmaku = FocusNode(debugLabel: 'tv-player-danmaku');
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _hideTimer;
  Timer? _seekTimer;
  Timer? _commitTimer;
  int? _pendingSeek;
  int? _seekDisplay;
  int _seekDirection = 1;
  int _repeatCount = 0;
  LogicalKeyboardKey? _heldKey;
  bool _visible = true;
  bool _panelOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visible = widget.showOnPlaybackReady;
    _reportVisibility();
    for (final stream in [
      widget.player.stream.position,
      widget.player.stream.duration,
      widget.player.stream.buffer,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted && widget.enabled && _visible) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      widget.player.stream.buffering.listen((_) {
        if (mounted && widget.enabled) setState(() {});
      }),
    );
    _subscriptions.add(
      widget.player.stream.playing.listen((playing) {
        if (!mounted || !widget.enabled || _panelOpen || _heldKey != null) {
          return;
        }
        if (widget.quietEpisodeChange?.call() ?? false) {
          _visible = false;
          _reportVisibility();
          setState(() {});
          return;
        }
        if (playing) {
          _scheduleHide();
        } else {
          _show();
        }
        setState(() {});
      }),
    );
    if (widget.enabled) {
      if (widget.showOnPlaybackReady) {
        _show();
      } else {
        _focus(_surface);
      }
    }
  }

  @override
  void didUpdateWidget(covariant TelevisionControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.title != oldWidget.title || !widget.enabled) {
      _cancelSeek();
    }
    if (widget.enabled && !oldWidget.enabled) {
      if (widget.showOnPlaybackReady) {
        _show();
      } else {
        _visible = false;
        _focus(_surface);
      }
    } else if (!widget.enabled) {
      _hideTimer?.cancel();
    }
    _reportVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || state == AppLifecycleState.resumed) return;
    _hideTimer?.cancel();
    setState(_cancelSeek);
    _reportVisibility();
  }

  void _cancelSeek() {
    _commitTimer?.cancel();
    _seekTimer?.cancel();
    _pendingSeek = _seekDisplay = null;
    _heldKey = null;
    _repeatCount = 0;
  }

  void _focus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.enabled &&
          !_panelOpen &&
          node.context != null &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        node.requestFocus();
      }
    });
  }

  void _reportVisibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onVisibilityChanged?.call(
          widget.enabled && (_visible || _seekDisplay != null),
        );
      }
    });
  }

  void _show() {
    final needsFocus =
        !_visible || !_surface.hasFocus || _surface.hasPrimaryFocus;
    if (!_visible) setState(() => _visible = true);
    _reportVisibility();
    if (needsFocus) _focus(_play);
    _scheduleHide();
  }

  void _hide() {
    _commitSeek();
    _hideTimer?.cancel();
    _seekTimer?.cancel();
    _heldKey = null;
    _repeatCount = 0;
    setState(() {
      _visible = false;
      _seekDisplay = null;
    });
    _reportVisibility();
    _focus(_surface);
  }

  bool handleBack() {
    if (!widget.enabled || _panelOpen || (!_visible && _seekDisplay == null)) {
      return false;
    }
    _hide();
    return true;
  }

  void _togglePlayback() {
    _commitSeek();
    widget.onTogglePlayback();
    _show();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.enabled ||
        _panelOpen ||
        _pendingSeek != null ||
        !widget.player.state.playing) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted &&
          widget.enabled &&
          !_panelOpen &&
          widget.player.state.playing &&
          !widget.player.state.buffering) {
        setState(() => _visible = false);
        _reportVisibility();
        _focus(_surface);
      }
    });
  }

  void _seek(int seconds) {
    if (!widget.enabled || widget.player.state.duration <= Duration.zero) {
      return;
    }
    final origin = _pendingSeek ?? widget.player.state.position.inMilliseconds;
    final target = (origin + seconds * 1000).clamp(
      0,
      widget.player.state.duration.inMilliseconds,
    );
    setState(() {
      _pendingSeek = _seekDisplay = target;
      _seekDirection = seconds.sign;
    });
    _reportVisibility();
    _hideTimer?.cancel();
    _commitTimer?.cancel();
    _seekTimer?.cancel();
    if (_heldKey == null) {
      _commitTimer = Timer(const Duration(milliseconds: 240), _commitSeek);
    }
  }

  void _commitSeek() {
    _commitTimer?.cancel();
    _heldKey = null;
    _repeatCount = 0;
    final target = _pendingSeek;
    _pendingSeek = null;
    if (target == null || !widget.enabled) return;
    if (widget.onSeekTo != null) {
      unawaited(widget.onSeekTo!(Duration(milliseconds: target)));
    } else {
      widget.onSeek(
        ((target - widget.player.state.position.inMilliseconds) / 1000).round(),
      );
    }
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _seekDisplay = null);
        _reportVisibility();
      }
    });
    _scheduleHide();
  }

  Future<void> _openPanel(Future<void> Function() action) async {
    if (_panelOpen) return;
    _commitSeek();
    _panelOpen = true;
    _hideTimer?.cancel();
    try {
      await action();
    } finally {
      if (mounted) {
        _panelOpen = false;
        if (widget.enabled) {
          _hide();
        }
      }
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent && event.logicalKey == _heldKey) {
      _heldKey = null;
      _repeatCount = 0;
      _commitSeek();
      return KeyEventResult.handled;
    }
    if (!widget.enabled ||
        _panelOpen ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    _scheduleHide();
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (event is KeyDownEvent) {
        if (_visible) {
          _hide();
        } else {
          widget.onBack();
        }
      }
    } else if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) _togglePlayback();
    } else if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent &&
          widget.player.state.playing !=
              (key == LogicalKeyboardKey.mediaPlay)) {
        _togglePlayback();
      }
    } else if (key == LogicalKeyboardKey.mediaTrackNext) {
      if (event is KeyDownEvent) widget.onNext?.call();
    } else if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) widget.onPrevious?.call();
    } else if (key == LogicalKeyboardKey.contextMenu) {
      if (event is KeyDownEvent) unawaited(_openPanel(widget.onEpisodes));
    } else if (((!_visible || key == _heldKey) &&
            (key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowRight)) ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaFastForward) {
      if (event is KeyDownEvent) {
        _heldKey = key;
        _repeatCount = 0;
      } else if (key != _heldKey) {
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) _repeatCount++;
      final direction =
          key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.mediaRewind
          ? -1
          : 1;
      _seek(direction * (_repeatCount >= 6 ? 30 : 15));
    } else if ((!_visible || _surface.hasPrimaryFocus) &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      _show();
    } else if ((!_visible || _surface.hasPrimaryFocus) &&
        [
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.gameButtonA,
        ].contains(key)) {
      if (event is KeyDownEvent) _togglePlayback();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekTimer?.cancel();
    _commitTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final node in [
      _surface,
      _play,
      _episodes,
      _settings,
      _diary,
      _progress,
      _rewind,
      _forward,
      _previous,
      _next,
      _danmaku,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Widget _transport({
    required Key key,
    required String label,
    required IconData icon,
    required FocusNode focus,
    required VoidCallback? action,
    bool primary = false,
  }) => RemoteTarget(
    key: key,
    label: label,
    focusNode: focus,
    onPressed: action,
    radius: 12,
    padding: const EdgeInsets.all(4),
    child: SizedBox(
      width: primary ? 72 : 76,
      height: 50,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: primary ? 26 : 22,
            color: action == null ? Colors.white30 : Colors.white,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: action == null ? Colors.white30 : Colors.white,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _action({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    FocusNode? focus,
    bool selected = false,
  }) => RemoteTarget(
    key: key,
    label: label,
    focusNode: focus,
    selected: selected,
    onPressed: onPressed,
    radius: 12,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    child: SizedBox(
      height: 42,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position =
        (_pendingSeek ?? _seekDisplay ?? state.position.inMilliseconds) / 1000;
    return ExcludeFocus(
      excluding: !widget.enabled,
      child: Focus(
        focusNode: _surface,
        onKeyEvent: _key,
        onFocusChange: (focused) {
          if (!focused && mounted && _heldKey != null) {
            setState(_cancelSeek);
            _reportVisibility();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? _show : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (state.buffering &&
                  widget.enabled &&
                  !(widget.quietEpisodeChange?.call() ?? false))
                const Center(child: CircularProgressIndicator()),
              if (_visible && widget.enabled) ...[
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xCC000000),
                          Colors.transparent,
                          Color(0xF0000000),
                        ],
                        stops: [0, .45, 1],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 18,
                  left: 28,
                  right: 28,
                  child: Row(
                    children: [
                      RemoteButton(
                        key: const ValueKey('tv-player-back'),
                        label: '返回',
                        icon: Icons.arrow_back_rounded,
                        onPressed: widget.onBack,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        '${widget.speed}x${widget.qualityLabel.isEmpty ? '' : ' · ${widget.qualityLabel}'}',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 28,
                  right: 28,
                  bottom: 18,
                  child: Container(
                    key: const ValueKey('tv-control-panel'),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    decoration: BoxDecoration(
                      color: const Color(0xD9161821),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RemoteTarget(
                          key: const ValueKey('tv-progress'),
                          label: '播放进度，按确认暂停或播放',
                          focusNode: _progress,
                          onPressed: _togglePlayback,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Stack(
                                    children: [
                                      LinearProgressIndicator(
                                        value: duration > 0
                                            ? (state.buffer.inMilliseconds /
                                                      1000 /
                                                      duration)
                                                  .clamp(0, 1)
                                            : 0,
                                        minHeight: 7,
                                        color: Colors.white30,
                                        backgroundColor: Colors.white12,
                                      ),
                                      LinearProgressIndicator(
                                        value: duration > 0
                                            ? (position / duration).clamp(0, 1)
                                            : 0,
                                        minHeight: 7,
                                        backgroundColor: Colors.transparent,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Row(
                                  children: [
                                    Text(
                                      '${formatPosition(position)} / ${formatPosition(duration)}',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                    const Spacer(),
                                    const Text(
                                      '返回播放后，左右 ±15秒',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.white60,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _transport(
                                key: const ValueKey('tv-previous'),
                                label: '上一集',
                                icon: Icons.skip_previous_rounded,
                                focus: _previous,
                                action: widget.onPrevious,
                              ),
                              const SizedBox(width: 8),
                              _transport(
                                key: const ValueKey('tv-rewind'),
                                label: '后退15秒',
                                icon: Icons.replay_rounded,
                                focus: _rewind,
                                action: () => _seek(-15),
                              ),
                              const SizedBox(width: 8),
                              _transport(
                                key: const ValueKey('tv-play-pause'),
                                label: state.playing ? '暂停' : '播放',
                                icon: state.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                focus: _play,
                                action: _togglePlayback,
                                primary: true,
                              ),
                              const SizedBox(width: 8),
                              _transport(
                                key: const ValueKey('tv-forward'),
                                label: '快进15秒',
                                icon: Icons.forward_rounded,
                                focus: _forward,
                                action: () => _seek(15),
                              ),
                              const SizedBox(width: 8),
                              _transport(
                                key: const ValueKey('tv-next'),
                                label: '下一集',
                                icon: Icons.skip_next_rounded,
                                focus: _next,
                                action: widget.onNext,
                              ),
                              const SizedBox(width: 8),
                              _action(
                                key: const ValueKey('tv-episodes'),
                                label: '选集',
                                icon: Icons.grid_view_rounded,
                                focus: _episodes,
                                onPressed: () => _openPanel(widget.onEpisodes),
                              ),
                              if (widget.showDanmaku &&
                                  widget.onDanmaku != null)
                                _action(
                                  key: const ValueKey('tv-danmaku'),
                                  label: widget.danmakuEnabled ? '弹幕开' : '弹幕关',
                                  icon: Icons.subtitles_rounded,
                                  focus: _danmaku,
                                  selected: widget.danmakuEnabled,
                                  onPressed: () =>
                                      _openPanel(widget.onDanmaku!),
                                ),
                              _action(
                                key: const ValueKey('tv-settings'),
                                label: '倍速 / 画质',
                                icon: Icons.tune_rounded,
                                focus: _settings,
                                onPressed: () => _openPanel(widget.onSettings),
                              ),
                              if (widget.enhancement != null)
                                AnimatedBuilder(
                                  animation: widget.enhancement!,
                                  builder: (_, _) {
                                    final enhancement = widget.enhancement!;
                                    if (!enhancement.canCompare) {
                                      return const SizedBox.shrink();
                                    }
                                    return _action(
                                      key: const ValueKey(
                                        'tv-enhancement-compare',
                                      ),
                                      label: enhancement.comparing
                                          ? '恢复增强'
                                          : '原画对比',
                                      icon: Icons.compare_rounded,
                                      onPressed: () {
                                        unawaited(enhancement.toggleCompare());
                                        _focus(_play);
                                        _scheduleHide();
                                      },
                                    );
                                  },
                                ),
                              _action(
                                key: const ValueKey('tv-diary'),
                                label: '播放日记',
                                icon: Icons.receipt_long_rounded,
                                focus: _diary,
                                onPressed: () => _openPanel(
                                  widget.onDiary ??
                                      () =>
                                          DiaryService.showDiaryDialog(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '左右快进后退 · 上下控制条 · 菜单键选集 · 返回播放',
                          style: TextStyle(fontSize: 13, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_seekDisplay != null && widget.enabled)
                IgnorePointer(
                  child: Align(
                    alignment: Alignment(0, _visible ? -.55 : -.15),
                    child: Container(
                      key: const ValueKey('tv-seek-preview'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 20,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekDirection > 0
                                ? Icons.fast_forward_rounded
                                : Icons.fast_rewind_rounded,
                            size: 32,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${formatPosition(position)} / ${formatPosition(duration)}',
                            style: const TextStyle(
                              fontSize: 26,
                              fontFeatures: [FontFeature.tabularFigures()],
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
    );
  }
}

class TelevisionEpisodeDialog extends StatelessWidget {
  const TelevisionEpisodeDialog({
    super.key,
    required this.episodes,
    required this.currentIndex,
    this.onAllSeasons,
  });
  final List<Episode> episodes;
  final int currentIndex;
  final VoidCallback? onAllSeasons;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('选集 · 共 ${episodes.length} 集'),
    content: SizedBox(
      width: 900,
      height: MediaQuery.sizeOf(context).height * .55,
      child: LayoutBuilder(
        builder: (context, constraints) => RemoteGrid(
          itemKeys: episodes.map((episode) => '${episode.number}').toList(),
          columns: ((constraints.maxWidth - 6) / 72).floor().clamp(1, 14),
          itemExtent: 48,
          spacing: 6,
          initialIndex: currentIndex,
          autofocus: true,
          padding: const EdgeInsets.all(6),
          itemBuilder: (_, index, node, onFocus) => RemoteEpisodeButton(
            key: ValueKey('tv-select-episode-${episodes[index].number}'),
            compact: true,
            fontSize: 17,
            borderWidth: 2,
            number: episodes[index].number,
            vip: episodes[index].vip,
            current: index == currentIndex,
            focusNode: node,
            onFocus: onFocus,
            onPressed: () => Navigator.pop(context, index),
          ),
        ),
      ),
    ),
    actions: [
      if (onAllSeasons != null)
        OutlinedButton.icon(
          key: const ValueKey('tv-all-seasons'),
          onPressed: onAllSeasons,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('查看全季'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('返回播放'),
      ),
    ],
  );
}

class TelevisionPlaybackSetting {
  const TelevisionPlaybackSetting({
    this.speed,
    this.tvTextureOutput,
    this.tvDecoderMode,
    this.quality,
    this.autoAdvance,
    this.danmaku,
    this.danmakuSpeed,
    this.danmakuOpacity,
    this.preload,
    this.enhancement,
  });
  final double? speed;
  final bool? tvTextureOutput;
  final TvDecoderMode? tvDecoderMode;
  final int? quality;
  final bool? autoAdvance;
  final bool? danmaku;
  final double? danmakuSpeed;
  final double? danmakuOpacity;
  final bool? preload;
  final VideoEnhancementPreferences? enhancement;
}

class TelevisionSettingsDialog extends StatelessWidget {
  const TelevisionSettingsDialog({
    super.key,
    required this.speed,
    this.tvTextureOutput,
    this.tvDecoderMode,
    required this.quality,
    required this.qualities,
    required this.favorite,
    required this.onFavorite,
    this.autoAdvance = true,
    this.danmaku = true,
    this.danmakuSpeed,
    this.danmakuOpacity,
    this.showDanmaku = false,
    this.danmakuStatus = '',
    this.onRetryDanmaku,
    this.preload = true,
    this.preloadStatus = '',
    this.enhancement,
    this.onCompareEnhancement,
  });
  final double speed;
  final bool? tvTextureOutput;
  final TvDecoderMode? tvDecoderMode;
  final int quality;
  final List<int> qualities;
  final bool favorite;
  final VoidCallback onFavorite;
  final bool autoAdvance;
  final bool danmaku;
  final double? danmakuSpeed;
  final double? danmakuOpacity;
  final bool showDanmaku;
  final String danmakuStatus;
  final VoidCallback? onRetryDanmaku;
  final bool preload;
  final String preloadStatus;
  final VideoEnhancementController? enhancement;
  final VoidCallback? onCompareEnhancement;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('播放设置'),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tvDecoderMode != null) ...[
              TvDecoderSettings(
                value: tvDecoderMode!,
                applyingToPlayback: true,
                onChanged: (mode) => Navigator.pop(
                  context,
                  TelevisionPlaybackSetting(tvDecoderMode: mode),
                ),
              ),
              const SizedBox(height: 20),
            ],
            const Text('倍速', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in playbackSpeeds)
                  RemoteButton(
                    key: ValueKey('tv-speed-$value'),
                    label: '${value}x',
                    autofocus: tvDecoderMode == null && value == speed,
                    selected: value == speed,
                    onPressed: () => Navigator.pop(
                      context,
                      TelevisionPlaybackSetting(speed: value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (tvTextureOutput != null) ...[
              const Text('视频输出', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final texture in [false, true])
                    RemoteButton(
                      key: ValueKey('tv-output-$texture'),
                      label: texture ? '兼容模式' : '流畅模式（默认）',
                      selected: texture == tvTextureOutput,
                      onPressed: () => Navigator.pop(
                        context,
                        TelevisionPlaybackSetting(tvTextureOutput: texture),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],
            const Text('清晰度', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in {
                  ...playbackQualities,
                  ...qualities.where((value) => value > 0),
                })
                  RemoteButton(
                    key: ValueKey('tv-quality-$value'),
                    label: value == 0 ? '自动（优先高清）' : '${value}P',
                    selected: value == quality,
                    onPressed: () => Navigator.pop(
                      context,
                      TelevisionPlaybackSetting(quality: value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (enhancement != null)
              VideoEnhancementSettings(
                controller: enhancement!,
                television: true,
                onChanged: (value) => Navigator.pop(
                  context,
                  TelevisionPlaybackSetting(enhancement: value),
                ),
                onCompare: onCompareEnhancement ?? () {},
              ),
            if (showDanmaku) ...[
              RemoteButton(
                key: const ValueKey('tv-danmaku-enabled'),
                label: danmaku ? '弹幕：开' : '弹幕：关',
                onPressed: () => Navigator.pop(
                  context,
                  TelevisionPlaybackSetting(danmaku: !danmaku),
                ),
              ),
              const SizedBox(height: 8),
              const Text('弹幕速度（独立于视频倍速）'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in danmakuSpeeds)
                    RemoteButton(
                      key: ValueKey('tv-danmaku-speed-$value'),
                      label: '${value}x${value == 1 ? '（默认）' : ''}',
                      selected: value == (danmakuSpeed ?? 1),
                      onPressed: () => Navigator.pop(
                        context,
                        TelevisionPlaybackSetting(danmakuSpeed: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('弹幕不透明度（越低越透明）'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in danmakuOpacities)
                    RemoteButton(
                      key: ValueKey('tv-danmaku-opacity-$value'),
                      label: '${(value * 100).round()}%',
                      selected: value == (danmakuOpacity ?? .55),
                      onPressed: () => Navigator.pop(
                        context,
                        TelevisionPlaybackSetting(danmakuOpacity: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(danmakuStatus, style: const TextStyle(fontSize: 14)),
              if (onRetryDanmaku != null)
                RemoteButton(
                  key: const ValueKey('tv-danmaku-retry'),
                  label: '重试弹幕',
                  onPressed: onRetryDanmaku,
                ),
              const SizedBox(height: 20),
            ],
            RemoteButton(
              key: const ValueKey('tv-auto-advance'),
              label: autoAdvance ? '自动连播：开' : '自动连播：关',
              onPressed: () => Navigator.pop(
                context,
                TelevisionPlaybackSetting(autoAdvance: !autoAdvance),
              ),
            ),
            const SizedBox(height: 16),
            RemoteButton(
              key: const ValueKey('tv-preload-enabled'),
              label: preload ? '下一集预加载：开' : '下一集预加载：关',
              onPressed: () => Navigator.pop(
                context,
                TelevisionPlaybackSetting(preload: !preload),
              ),
            ),
            const SizedBox(height: 8),
            Text(preloadStatus, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 20),
            RemoteButton(
              label: favorite ? '取消追剧' : '加入追剧',
              icon: favorite
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              onPressed: () {
                onFavorite();
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('返回播放'),
      ),
    ],
  );
}
