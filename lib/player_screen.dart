import 'desktop_fullscreen.dart';
import 'tv_decoder_settings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'luna_exo_player.dart';
import 'danmaku_controller.dart';
import 'danmaku_overlay.dart';
import 'watch_reminder_models.dart';
import 'watch_reminder_runtime.dart';
import 'download_picker.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'next_season_resolver.dart';
import 'series_browser_screen.dart';
import 'playback_loader.dart';
import 'playback_attempt.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_preferences.dart';
import 'player_controls.dart';
import 'player_interactions.dart';
import 'episode_swipe_surface.dart';
import 'player_menu.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'lan_controller.dart';
import 'lan_screen.dart';
import 'video_enhancement.dart';
import 'video_output_size.dart';
import 'windows_update_runtime.dart';
import 'windows_desktop.dart';
import 'windows_drama_description.dart';
import 'episode_label.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.initiallyPlaying = true,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
    this.healthClock,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool initiallyPlaying;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  @visibleForTesting
  final DateTime Function()? healthClock;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver, WindowListener {
  late DramaDetail _detail;
  DramaDetail? _openedDetail;
  int _seasonSequence = 0;
  bool _findingNextSeason = false;
  String? _completedSeasonKey;
  String? _seasonNotice;
  Timer? _seasonNoticeTimer;
  late final Player _player;
  late final VideoController? _video;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  double? _danmakuSpeed;
  double? _danmakuOpacity;
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _televisionControls = GlobalKey<TelevisionControlsState>();
  final _videoPaneKey = GlobalKey();
  Object? _windowsVideoGeometry;
  bool _windowsDescription = false;
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _windowsVolumeTimer;
  double? _windowsVolume;
  double? _windowsUnmuted;
  Timer? _healthTimer;
  WatchReminderRuntime? _watchReminders;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Future<void> _operations = Future<void>.value();
  Completer<void> _operationCancellation = Completer<void>();
  PlaybackAttempt? _attempt;
  Duration _attemptPosition = Duration.zero;
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _smoothTransition = false;
  bool _transitionWaitVisible = false;
  Timer? _transitionWaitTimer;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _windowsEpisodesExpanded = true;
  int _windowsActivityRevision = 0;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool _autoAdvance = true;
  bool? _systemFullscreen;
  bool? _brightnessFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _showControlsOnPlaybackReady = true;
  bool _televisionOverlayVisible = false;
  bool _pendingError = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  bool _televisionPlaybackRegistered = false;
  bool? _screenOnRequested = false;
  int _screenOnRequestGeneration = 0;
  Timer? _screenOnDeadline;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _resumePosition = 0;
  bool _rotating = false;
  bool _television = false;
  bool _televisionDevice = false;
  bool _decoderFailure = false;
  AppOrientationController? _orientationController;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      !_television &&
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _desktopPlayer =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);
  bool get _nativeMacWindow =>
      Platform.isMacOS && defaultTargetPlatform == TargetPlatform.macOS;
  bool get _windowsMini =>
      _desktopPlayer && (WindowsDesktop.current?.mini ?? false);
  bool get _windowsSidebarAvailable =>
      _desktopPlayer &&
      !_windowsMini &&
      !_showFullscreen &&
      MediaQuery.sizeOf(context).width >= 760;
  bool get _portraitWatching =>
      _mobile &&
      !_showFullscreen &&
      MediaQuery.orientationOf(context) == Orientation.portrait;
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _speed,
    quality: _requestedQuality,
    autoAdvance: _autoAdvance,
    danmaku: _danmakuEnabled,
    danmakuSpeed: _danmakuSpeed,
    danmakuOpacity: _danmakuOpacity,
    preload: _preloadEnabled,
    reminders: widget.store.playbackPreferences.reminders,
    tvTextureOutput: widget.store.playbackPreferences.tvTextureOutput,
    tvDecoderMode: widget.store.playbackPreferences.tvDecoderMode,
    enhancement: _enhancement.preferences,
  );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? ((_plan?.quality ?? 0) > 0 ? '自动（${_plan!.quality}P）' : '自动')
      : ((_plan?.quality ?? 0) > 0 && _plan!.quality != _requestedQuality
            ? '${_requestedQuality}P（实际 ${_plan!.quality}P）'
            : '${_requestedQuality}P');
  String get _session => _plan?.session ?? '';
  bool get _openedCurrent =>
      identical(_openedDetail, _detail) && _openedIndex == _index;
  bool get _automaticEpisodeBoundary =>
      !_loading &&
      _openedCurrent &&
      _playIntent &&
      _autoAdvance &&
      _index + 1 < _detail.episodes.length &&
      _player.state.duration > Duration.zero &&
      _player.state.position >=
          _player.state.duration - const Duration(milliseconds: 800);
  bool get _quietEpisodeChange =>
      (_loading && !_showControlsOnPlaybackReady) || _automaticEpisodeBoundary;
  double get _currentPosition =>
      _openedCurrent && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  @override
  void initState() {
    super.initState();
    _television =
        context.getInheritedWidgetOfExactType<AppLayout>()?.television ?? false;
    final layout = context.getInheritedWidgetOfExactType<AppLayout>();
    _televisionDevice = layout?.deviceTelevision ?? _television;
    WidgetsBinding.instance.addObserver(this);
    if (_nativeMacWindow) windowManager.addListener(this);
    _detail = widget.detail;
    _index = widget.initialIndex;
    if (_desktopPlayer) {
      WindowsDesktop.current?.addListener(_desktopChanged);
      _windowsEpisodesExpanded =
          widget.store.preferences.getBool(
            'windows_episode_sidebar_expanded',
          ) ??
          true;
    }
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = preferences.quality;
    _autoAdvance = true;
    _danmakuEnabled = preferences.danmaku;
    _danmakuSpeed = preferences.danmakuSpeed;
    _danmakuOpacity = preferences.danmakuOpacity;
    _preloadEnabled = true;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(
      widget.repository,
      onPrepared: (plan) {
        final player = _player;
        if (!_closed && _foreground && player is LunaExoPlayer) {
          unawaited(
            player.prepareNext(
              Media(plan.url, httpHeaders: plan.headers),
              identity: plan.session,
              mediaType: plan.mediaType,
            ),
          );
        }
      },
      onRelease: (plan) async {
        final player = _player;
        if (player is LunaExoPlayer) {
          await player.clearPreparedNext(identity: plan.session);
        }
      },
    );
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _watchReminders = WatchReminderRuntime.current;
    _watchReminders?.addListener(_reminderChanged);
    _player =
        widget.playerFactory?.call() ??
        (Platform.isAndroid
            ? LunaExoPlayer(
                television: () => _television,
                textureOutput: () => _preferences.tvTextureOutput,
                decoderMode: () =>
                    _televisionDevice ? _preferences.tvDecoderMode : null,
              )
            : Player(
                configuration: const PlayerConfiguration(
                  bufferSize: 32 * 1024 * 1024,
                  logLevel: MPVLogLevel.error,
                ),
              ));
    if (_player is LunaExoPlayer) {
      _player.frameHold.addListener(_retainedFrameChanged);
    }
    _video = widget.videoBuilder == null && !Platform.isAndroid
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration:
                  !Platform.isIOS &&
                  (!Platform.isMacOS || AppDevice.macHardwareVideoOutput),
              hwdec: Platform.isWindows
                  ? 'd3d11va-copy'
                  : Platform.isMacOS && !AppDevice.macHardwareVideoOutput
                  ? 'videotoolbox-copy'
                  : null,
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: _detail.drama.category,
      tags: _detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      initialUnmutedVolume: defaultTargetPlatform == TargetPlatform.windows
          ? widget.store.preferences.getDouble('windows_last_volume') ?? 100
          : 100,
      onVolumeChanged: defaultTargetPlatform == TargetPlatform.windows
          ? (volume, unmuted) {
              _windowsVolume = volume;
              _windowsUnmuted = unmuted;
              _windowsVolumeTimer?.cancel();
              _windowsVolumeTimer = Timer(
                const Duration(milliseconds: 250),
                _saveWindowsVolume,
              );
            }
          : null,
      available: () =>
          !(Platform.isWindows && WindowsUpdateRuntime.restarting) &&
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      captureEpisodeFrame: () =>
          _player is LunaExoPlayer ? _player.captureFrame() : Future.value(),
      canNavigateEpisode: (direction) =>
          _index + direction >= 0 &&
          _index + direction < _detail.episodes.length,
      onEpisodeSwipe: (direction) async {
        final next = _index + direction;
        if (next < 0 || next >= _detail.episodes.length) {
          _interactions.hint(next < 0 ? '已经是第一集' : '已经是最后一集');
          return;
        }
        await _play(next, showControlsOnReady: false, gestureAdvance: true);
      },
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= _detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${_detail.episodes[next].number} 集';
      },
    );
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(
        _player.setVolume(
          (widget.store.preferences.getDouble('windows_volume') ?? 100).clamp(
            0,
            100,
          ),
        ),
      );
    }
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery(error: error);
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            (!_desktopPlayer || _playIntent) &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < _detail.episodes.length) {
            _play(
              _index + 1,
              showControlsOnReady: false,
              automaticAdvance: true,
            );
          } else {
            unawaited(_finishSeason());
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedCurrent && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
          if (!_loading &&
              !_player.state.buffering &&
              position > _attemptPosition + const Duration(milliseconds: 500)) {
            _attempt?.stable();
          }
        }
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _syncDesktopPlayback();
          _syncScreenOn();
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          _scheduleSystemUi();
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncScreenOn();
      _syncWatchReminders();
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _playIntent && !_player.state.completed,
            foreground: _foreground,
            now: widget.healthClock?.call() ?? DateTime.now(),
          )) {
        unawaited(_recover(weakNetwork: true));
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null) unawaited(_releaseSession(handoff.plan.session));
      _loading = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        playWhenReady: widget.initiallyPlaying,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(_detail.drama),
          retryCover: true,
        );
      }
    });
    if (_desktopPlayer) {
      final desktop = WindowsDesktop.current;
      desktop?.playbackOwner = this;
      desktop?.togglePlayback = () {
        if (widget.store.profileEpoch == _profileEpoch &&
            !widget.store.locked &&
            widget.store.allowsSource(_detail.drama.source)) {
          _togglePlayback();
        }
      };
      Future<void> pauseAndSave() async {
        _cancelSeasonAdvance();
        _interactions.cancel();
        _playIntent = false;
        if (!_loading) _attempt?.stable();
        _syncScreenOn();
        await _player.pause();
        await _saveWindowsVolume();
        await _saveProgress(flush: true);
        await widget.store.flushPendingWrites();
      }

      desktop?.pausePlayback = pauseAndSave;
      desktop?.savePlayback = pauseAndSave;
      _syncDesktopPlayback();
    }
    if (Platform.isWindows) {
      WindowsUpdateRuntime.owner = this;
      WindowsUpdateRuntime.playing = () =>
          _playIntent ||
          _player.state.playing ||
          _loading ||
          _findingNextSeason;
      WindowsUpdateRuntime.savePlayback = () async {
        if (_playIntent || _player.state.playing || _loading)
          throw StateError('请先暂停播放后安装更新');
        await _saveWindowsVolume();
        await _saveProgress(flush: true);
        await widget.store.flushPendingWrites();
        return {
          'profile': widget.store.profile.id,
          'detail': {
            'drama': _detail.drama.toJson(),
            'chapters': _detail.episodes.map((episode) => episode.raw).toList(),
          },
          'index': _index,
          'position': _player.state.position.inMilliseconds / 1000,
          'localOnly': widget.localOnly,
          'allowOnlineFallback': widget.allowOnlineFallback,
          'mediaId': widget.mediaId,
        };
      };
    }
  }

  Future<void> _saveWindowsVolume() async {
    _windowsVolumeTimer?.cancel();
    if (_windowsVolume == null) return;
    await widget.store.preferences.setDouble('windows_volume', _windowsVolume!);
    await widget.store.preferences.setDouble(
      'windows_last_volume',
      _windowsUnmuted!,
    );
  }

  void _accessChanged() {
    if (!_closed &&
        mounted &&
        !widget.store.locked &&
        widget.store.profileEpoch == _profileEpoch) {
      final preferences = widget.store.playbackPreferences;
      if (preferences.danmaku != _danmakuEnabled ||
          preferences.danmakuSpeed != _danmakuSpeed ||
          preferences.danmakuOpacity != _danmakuOpacity) {
        setState(() {
          _danmakuEnabled = preferences.danmaku;
          _danmakuSpeed = preferences.danmakuSpeed;
          _danmakuOpacity = preferences.danmakuOpacity;
        });
        _danmaku.setEnabled(_danmakuEnabled);
        _syncDanmaku();
        _menuRevision.value++;
      }
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _cancelSeasonAdvance();
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      if (!_loading) _attempt?.stable();
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'televisionBackPressed' &&
          _television &&
          mounted &&
          !_closed) {
        if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
          await Navigator.of(context).maybePop();
        } else {
          _back();
        }
        return;
      }
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  void _setTelevisionPlaybackActive(bool active) {
    if (!_pictureInPictureHandlerInstalled ||
        active == _televisionPlaybackRegistered) {
      return;
    }
    _televisionPlaybackRegistered = active;
    unawaited(
      AppDevice.channel
          .invokeMethod<void>('setTelevisionPlaybackActive', {'active': active})
          .catchError((Object _) {}),
    );
  }

  void _syncScreenOn() {
    if (_closed) _screenOnDeadline?.cancel();
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    final enabled =
        !_closed &&
        (_lifecycleState == AppLifecycleState.resumed ||
            _desktopPlayer && (WindowsDesktop.current?.keepPlayback ?? false) ||
            (defaultTargetPlatform == TargetPlatform.windows ||
                    defaultTargetPlatform == TargetPlatform.macOS) &&
                _lifecycleState == AppLifecycleState.inactive) &&
        !_pictureInPictureVisible &&
        _error == null &&
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked &&
        (_playIntent || _findingNextSeason);
    if (enabled == _screenOnRequested) return;
    _screenOnRequested = enabled;
    final generation = ++_screenOnRequestGeneration;
    _screenOnDeadline?.cancel();
    if (!_closed) {
      _screenOnDeadline = Timer(const Duration(seconds: 2), () {
        if (generation == _screenOnRequestGeneration) {
          _screenOnRequested = null;
        }
      });
    }
    unawaited(
      AppDevice.channel
          .invokeMethod<void>('setPlaybackScreenOn', {'enabled': enabled})
          .then((_) {
            if (generation == _screenOnRequestGeneration) {
              _screenOnDeadline?.cancel();
            }
          })
          .catchError((Object error) {
            if (generation == _screenOnRequestGeneration) {
              _screenOnDeadline?.cancel();
              _screenOnRequested = null;
            }
            DiaryService.add('[ScreenOn] 播放亮屏状态设置失败: $error');
          }),
    );
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    final visible =
        _lifecycleState == AppLifecycleState.resumed ||
        _desktopPlayer && (WindowsDesktop.current?.keepPlayback ?? false) ||
        _pictureInPictureVisible ||
        (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.macOS) &&
            _lifecycleState == AppLifecycleState.inactive;
    if (_foreground != visible) _health.reset();
    _foreground = visible;
    _syncScreenOn();
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    if (!visible) {
      _cancelSeasonAdvance();
      _dismissSeasonNotice();
      _interactions.cancel();
    }
    if (pauseWhenHidden &&
        !visible &&
        (_lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.inactive ||
            _lifecycleState == AppLifecycleState.hidden)) {
      _playIntent = false;
      if (!_loading) _attempt?.stable();
      unawaited(_player.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _loading ||
        _error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice('当前设备不支持画中画');
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice('无法进入画中画，请检查系统权限');
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _recordWindowsVideoGeometry() {
    if (!_desktopPlayer || !mounted || _closed) return;
    final context = _videoPaneKey.currentContext;
    final pane = context?.findRenderObject();
    if (context == null ||
        pane is! RenderBox ||
        !pane.attached ||
        !pane.hasSize) {
      return;
    }
    Rect? texture;
    void visit(Element element) {
      if (element.widget is Texture) {
        final object = element.findRenderObject();
        if (object is RenderBox && object.attached && object.hasSize) {
          texture = MatrixUtils.transformRect(
            object.getTransformTo(pane),
            Offset.zero & object.size,
          );
        }
        return;
      }
      if (texture == null) element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    final media = MediaQuery.of(context);
    final source = videoDisplaySize(_player.state.videoParams);
    final contained = source == null
        ? null
        : applyBoxFit(BoxFit.contain, source, pane.size).destination;
    final expected = contained == null
        ? null
        : Alignment.center.inscribe(contained, Offset.zero & pane.size);
    final geometry = (
      source,
      pane.size,
      pane.localToGlobal(Offset.zero),
      texture,
      media.devicePixelRatio,
      View.of(context).physicalSize,
      media.padding,
      media.viewInsets,
      _showFullscreen,
      _windowsMini,
    );
    if (_windowsVideoGeometry == geometry) return;
    _windowsVideoGeometry = geometry;
    DiaryService.add(
      '[WindowsVideo] source=$source viewport=${pane.size} dpr=${media.devicePixelRatio} padding=${media.padding} insets=${media.viewInsets} texture=$texture expectedContain=$expected fullscreen=$_showFullscreen mini=$_windowsMini',
    );
    final channel = WindowsDesktop.current?.channel;
    if (channel != null) {
      unawaited(() async {
        try {
          final native = await channel
              .invokeMapMethod<String, dynamic>('windowGeometry')
              .timeout(const Duration(seconds: 2));
          if (mounted &&
              !_closed &&
              _windowsVideoGeometry == geometry &&
              native != null) {
            DiaryService.add(
              '[WindowsVideoNative] flutter=$geometry native=$native',
            );
          }
        } catch (error) {
          if (mounted && !_closed && _windowsVideoGeometry == geometry) {
            DiaryService.add('[WindowsVideoNative] unavailable=$error');
          }
        }
      }());
    }
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            _detail.drama.title +
            ' · 第 ' +
            _detail.episodes[_index].number.toString() +
            ' 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        !_openedCurrent ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch)
      return;
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20)
      return;
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    _cancelSeasonAdvance();
    final generation = _generation;
    try {
      await _serialize(() async {
        if (_closed ||
            generation != _generation ||
            widget.store.profileEpoch != _profileEpoch)
          return;
        _playIntent = false;
        if (!_loading) _attempt?.stable();
        _interactions.cancel();
        _enhancement.suspend();
        _health.reset();
        await _player.pause();
        if (_closed || generation != _generation) return;
        await _saveProgress(flush: true);
      });
    } on PlaybackAttemptCancelled {}
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null)
      return;
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: _detail.drama,
          episodeID: _detail.episodes[index].id,
          episode: _detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _loading ||
        _error != null ||
        !_openedCurrent ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= _detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) return;
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0) return;
    final buffered = state.buffer.inMilliseconds;
    final fullyBuffered = buffered >= duration;
    if (!fullyBuffered && (position < 500 || buffered - position < 2000)) {
      return;
    }
    _preloader.prepare(
      _detail.drama,
      _detail.episodes[_index + 1],
      quality: _requestedQuality,
      immediate: true,
    );
  }

  bool get _mobileRemindersAllowed =>
      _mobile &&
      (context.getInheritedWidgetOfExactType<AppLayout>()?.mobileReminders ??
          true);

  bool get _watchingForReminders =>
      !_closed &&
      _mobileRemindersAllowed &&
      _lifecycleState == AppLifecycleState.resumed &&
      !_pictureInPictureVisible &&
      !_loading &&
      _error == null &&
      _openedCurrent &&
      _playIntent &&
      _player.state.playing &&
      !_player.state.buffering &&
      !_player.state.completed &&
      !_danmaku.seeking &&
      widget.store.profileEpoch == _profileEpoch &&
      !widget.store.locked &&
      (_panelOpen || (ModalRoute.of(context)?.isCurrent ?? true));

  bool get _reminderVisible =>
      _watchingForReminders &&
      !_panelOpen &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (_watchReminders?.notice.isNotEmpty ?? false);

  void _reminderChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _syncWatchReminders() {
    if (_watchReminders == null) return;
    _watchReminders!.setPlayback(
      this,
      watching: _watchingForReminders,
      canShow:
          _watchingForReminders &&
          !_panelOpen &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  Widget _watchReminderDialog() {
    final kinds = _watchReminders!.notice;
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Color(0x66000000)),
          Center(
            child: AlertDialog(
              key: const ValueKey('watch-reminder-dialog'),
              title: const Text('休息一下吧'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (kinds.contains(WatchReminderKind.daily))
                      const Text('今天的观看时间已达到你设置的上限，起来活动一下吧。'),
                    if (kinds.contains(WatchReminderKind.bedtime))
                      const Text('已到你设置的睡觉时间，早点休息吧。'),
                    if (_watchReminders!.persistenceError != null)
                      Text(_watchReminders!.persistenceError!),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  key: const ValueKey('watch-reminder-dismiss'),
                  onPressed: _watchReminders!.dismiss,
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    _syncWatchReminders();
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedCurrent &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _televisionDevice = AppLayout.isTelevisionDevice(context);
    _setTelevisionPlaybackActive(_television);
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
    _syncWatchReminders();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      final brightnessFullscreen = _mobile && fullscreen;
      if (_brightnessFullscreen != brightnessFullscreen) {
        _brightnessFullscreen = brightnessFullscreen;
        unawaited(
          AppDevice.setFullscreenBrightness(brightnessFullscreen).then((
            applied,
          ) {
            if (!applied && !_closed) {
              DiaryService.add('[Brightness] 全屏窗口亮度设置未成功');
            }
          }),
        );
      }
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  void _queueRecovery({String? error}) {
    if (_televisionDevice &&
        error != null &&
        isDecoderCompatibilityError(error)) {
      _decoderFailure = true;
    }
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (_loading) return;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      DiaryService.add('[Recovery] 收到播放错误，准备恢复当前集');
      unawaited(_recover());
    });
  }

  Future<void> _recover({bool weakNetwork = false}) async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    if (weakNetwork && !_lowerQualityOffered && _lowerQuality != null) {
      _lowerQualityOffered = true;
      final generation = _generation;
      if (await _offerLowerQuality()) return;
      if (_closed || !mounted || generation != _generation) return;
    }
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local || _decoderFailure
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    DiaryService.add(
      '[Recovery] episode=${_detail.episodes[_index].number}, action=${action.name}, position=$position, playing=${_player.state.playing}, intent=$_playIntent',
    );
    if (action == PlaybackRecoveryAction.stop) {
      _attempt?.stable();
      if (_decoderFailure) {
        _playIntent = false;
        _preloader.clear();
        _syncScreenOn();
      }
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            if (_closed || ticket != _generation) return;
            _openedIndex = -1;
            await _player.stop();
          } finally {
            if (!_decoderFailure &&
                (ticket == _generation || _plan?.session != current.session)) {
              await _releaseSession(current.session);
            }
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = _decoderFailure
              ? '当前视频规格或解码器不兼容。请打开播放设置更改 TV 解码模式，或更换线路、降低清晰度；系统软解也可能不支持该视频。'
              : current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  void _cancelSeasonAdvance() {
    _seasonSequence++;
    if (!_findingNextSeason) return;
    _findingNextSeason = false;
    _interactions.hint('');
  }

  void _dismissSeasonNotice() {
    _seasonNoticeTimer?.cancel();
    if (_seasonNotice == null) return;
    if (mounted && !_closed) {
      setState(() => _seasonNotice = null);
    } else {
      _seasonNotice = null;
    }
  }

  void _showSeasonNotice(DramaDetail detail, int index) {
    if (!mounted || _closed || !_foreground || !_playIntent) return;
    _seasonNoticeTimer?.cancel();
    setState(() {
      _seasonNotice =
          '已自动续播下一季\n${detail.drama.title} · 第 ${detail.episodes[index].number} 集';
    });
    _seasonNoticeTimer = Timer(
      const Duration(seconds: 4),
      _dismissSeasonNotice,
    );
  }

  Future<void> _finishSeason({bool retry = false}) async {
    final completedKey = '${_detail.drama.id}:$_generation:$_index';
    if (_closed ||
        _loading ||
        !_player.state.completed ||
        _findingNextSeason ||
        (!retry && _completedSeasonKey == completedKey)) {
      return;
    }
    _completedSeasonKey = completedKey;
    final generation = _generation;
    final detail = _detail;
    final sequence = ++_seasonSequence;
    bool current() =>
        mounted &&
        !_closed &&
        sequence == _seasonSequence &&
        generation == _generation &&
        identical(detail, _detail) &&
        _foreground &&
        !_panelOpen &&
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked &&
        widget.store.allowsSource(detail.drama.source) &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    final canContinue =
        _autoAdvance &&
        _index == detail.episodes.length - 1 &&
        detail.drama.source == SourceSite.hongguo.id &&
        detail.drama.releaseStatus != 'ongoing' &&
        !widget.localOnly &&
        widget.allowOnlineFallback &&
        widget.mediaId == null &&
        current();
    _findingNextSeason = canContinue;
    _playIntent = false;
    _attempt?.stable();
    _syncScreenOn();
    _interactions.cancel();
    try {
      await _player.pause();
      if (_closed || generation != _generation) return;
      await _saveProgress(flush: true);
      if (!canContinue || !current()) return;
      _interactions.hint('本季已播完，正在查找下一季', persistent: true);
      DiaryService.add('[Season] 查找下一季: ${detail.drama.title}');
      final next = await NextSeasonResolver(widget.repository).resolve(
        detail.drama,
        knownDramas: widget.store.seriesDramasFor(detail.drama),
        isCurrent: current,
      );
      if (!current()) return;
      if (next == null) {
        _notice('本季已播完，暂未找到下一季');
        return;
      }
      widget.repository.catalogUpdates.publish(next.drama);
      unawaited(
        widget.store.refreshDrama(next.drama).catchError((Object error) {
          DiaryService.add('[Season] 更新剧集记录失败: $error');
        }),
      );
      DiaryService.add(
        '[Season] 自动续播: ${next.drama.title}，第 ${next.episodes.first.number} 集',
      );
      await _play(
        0,
        nextDetail: next,
        showControlsOnReady: false,
        automaticAdvance: true,
      );
    } catch (error) {
      DiaryService.add('[Season] 下一季加载未完成: $error');
      if (!current()) return;
      final message = error is AppFailure ? error.message : '下一季加载失败，请检查网络后重试';
      final retryable =
          error is! AppFailure || !error.code.startsWith('next_season_');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action: retryable
              ? SnackBarAction(
                  label: '重试',
                  onPressed: () {
                    if (current()) unawaited(_finishSeason(retry: true));
                  },
                )
              : null,
        ),
      );
    } finally {
      if (!_closed && sequence == _seasonSequence) {
        _findingNextSeason = false;
        _syncScreenOn();
        _interactions.hint('');
      }
    }
  }

  void _togglePlayback() {
    if (Platform.isWindows && WindowsUpdateRuntime.restarting) return;
    if (_closed || _loading || _error != null) return;
    _cancelSeasonAdvance();
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    _playIntent = !_player.state.playing;
    if (!_playIntent) _attempt?.stable();
    _syncScreenOn();
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
  }

  Future<void> _saveProgress({bool flush = false}) async {
    final openedDetail = _openedDetail;
    if (openedDetail == null ||
        _openedIndex < 0 ||
        _openedIndex >= openedDetail.episodes.length ||
        widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? openedDetail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == progressKey && _saveWarning == null) {
      if (flush && widget.mediaId == null) LanController.current?.flush();
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(openedDetail.drama),
      episode: openedDetail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry);
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _releaseSession(String session) async {
    try {
      await widget.repository
          .release(session)
          .timeout(const Duration(seconds: 2));
    } catch (error) {
      DiaryService.add('[Switch] session cleanup delayed: $error');
    }
  }

  Future<void> _serialize(
    Future<void> Function() operation, {
    PlaybackAttempt? attempt,
  }) {
    final cancellation = _operationCancellation;
    final owner = attempt ?? _attempt;
    final pending = _operations.catchError((Object _) {}).then((_) {
      if (cancellation.isCompleted ||
          owner?.cancelled == true ||
          owner?.expired == true) {
        throw PlaybackAttemptCancelled();
      }
      final executing = operation();
      return owner == null ? executing : owner.guard(executing);
    });
    final next = Future.any<void>([
      pending,
      cancellation.future.then<void>((_) => throw PlaybackAttemptCancelled()),
    ]);
    _operations = next;
    return next;
  }

  void _cancelOperations() {
    if (!_operationCancellation.isCompleted) _operationCancellation.complete();
    _operationCancellation = Completer<void>();
  }

  void _failAttempt(PlaybackAttempt attempt, AppFailure failure) {
    if (_closed || !mounted || !identical(attempt, _attempt)) return;
    ++_generation;
    _cancelOperations();
    attempt.cancel();
    _attempt = null;
    _acceptErrors = false;
    _pendingError = false;
    _playIntent = false;
    _errorTimer?.cancel();
    _transitionWaitTimer?.cancel();
    _preloader.clear();
    unawaited(_loader.cancel().catchError((Object _) {}));
    if (_player is LunaExoPlayer) {
      unawaited(_player.cancelPending().catchError((Object _) {}));
      _player.clearRetainedFrame();
    }
    unawaited(
      _player
          .stop()
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) {}),
    );
    final previous = _plan;
    _plan = null;
    _openedIndex = -1;
    _openedDetail = null;
    if (previous != null) unawaited(_releaseSession(previous.session));
    var message = failure.message;
    if (failure.code == 'source_blocked' && failure.retryAt != null) {
      final seconds = failure.retryAt!.difference(DateTime.now()).inSeconds;
      if (seconds > 0) {
        message = '$message 请等待约 ${seconds + 1} 秒后手动重试，也可换一集。';
      }
    }
    setState(() {
      _loading = false;
      _smoothTransition = false;
      _transitionWaitVisible = false;
      _error = message;
      _sourceBlocked = failure.code == 'source_blocked';
      _localFailure = false;
    });
    widget.handoff?.fail(message);
    _syncScreenOn();
  }

  bool get _hasRetainedFrame =>
      _player is LunaExoPlayer && _player.frameHold.active;

  void _retainedFrameChanged() {
    if (!mounted || _closed) return;
    setState(() {
      if (!_loading && !_hasRetainedFrame) {
        _transitionWaitTimer?.cancel();
        _smoothTransition = false;
        _transitionWaitVisible = false;
      }
    });
  }

  Future<void> _play(
    int index, {
    DramaDetail? nextDetail,
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
    bool automaticAdvance = false,
    bool gestureAdvance = false,
  }) async {
    final detail = nextDetail ?? _detail;
    final changingSeason = !identical(detail, _detail);
    if ((Platform.isWindows && WindowsUpdateRuntime.restarting) ||
        _closed ||
        widget.store.profileEpoch != _profileEpoch ||
        (changingSeason &&
            (widget.store.locked ||
                !widget.store.allowsSource(detail.drama.source))) ||
        index < 0 ||
        index >= detail.episodes.length) {
      return;
    }
    final previousDeadline = recoveryAction == null ? null : _attempt?.deadline;
    _cancelOperations();
    _attempt?.cancel();
    unawaited(_loader.cancel().catchError((Object _) {}));
    if (_player is LunaExoPlayer) {
      unawaited(_player.cancelPending().catchError((Object _) {}));
    }
    final ticket = ++_generation;
    late final PlaybackAttempt attempt;
    attempt = PlaybackAttempt(
      deadline:
          detail.drama.source == SourceSite.hongguo.id && !widget.localOnly
          ? previousDeadline ?? DateTime.now().add(const Duration(seconds: 75))
          : null,
      onTimeout: () => _failAttempt(attempt, PlaybackAttempt.timeoutFailure),
    );
    _attempt = attempt;
    _attemptPosition = Duration(milliseconds: (position * 1000).round());
    _cancelSeasonAdvance();
    _completedSeasonKey = null;
    _dismissSeasonNotice();
    final switchClock = Stopwatch()..start();
    final smooth =
        recoveryAction == null &&
        (changingSeason || (index - _index).abs() == 1) &&
        _player is LunaExoPlayer &&
        _player.canTransition;
    final pausedPrevious = smooth ? _player.pause() : Future<void>.value();
    final retainPreviousFrame = automaticAdvance && smooth;
    final frameReady = retainPreviousFrame
        ? _player.retainCurrentFrame()
        : Future<bool>.value(false);
    if (!retainPreviousFrame && _player is LunaExoPlayer) {
      _player.clearRetainedFrame();
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (changingSeason || index != _index) _forceOnline = false;
    final warmedFuture = handoffPlan != null
        ? Future<PlaybackPlan?>.value(handoffPlan)
        : recoveryAction == null && _preloadEnabled && !widget.localOnly
        ? smooth
              ? _preloader.takeWhenReady(
                  detail.drama,
                  detail.episodes[index],
                  quality: _requestedQuality,
                  online: _forceOnline,
                )
              : Future<PlaybackPlan?>.value(
                  _preloader.take(
                    detail.drama,
                    detail.episodes[index],
                    quality: _requestedQuality,
                    online: _forceOnline,
                  ),
                )
        : Future<PlaybackPlan?>.value();
    _preloader.clear();
    _transitionWaitTimer?.cancel();
    _smoothTransition = smooth;
    _transitionWaitVisible = false;
    if (smooth) {
      _transitionWaitTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted &&
            !_closed &&
            ticket == _generation &&
            (_loading || _hasRetainedFrame)) {
          setState(() => _transitionWaitVisible = true);
        }
      });
    }
    _enhancement.suspend();
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _decoderFailure = false;
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    setState(() {
      if (changingSeason || _index != index) _lowerQualityOffered = false;
      _detail = detail;
      if (changingSeason) _mobileTab = 0;
      _index = index;
      _loading = true;
      _error = null;
      _sourceBlocked = false;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        _ => '正在准备播放',
      };
    });
    _syncScreenOn();
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? warmed;
    PlaybackPlan? retained;
    PlaybackPlan? transitionPrevious;
    bool installed = false;
    try {
      DiaryService.add(
        '[Switch] episode=${detail.episodes[index].number}, phase=request, generation=$ticket, origin=${gestureAdvance
            ? 'swipe'
            : automaticAdvance
            ? 'automatic'
            : 'selection'}, reuse=$smooth',
      );
      warmed = await attempt.guard(
        warmedFuture.then((plan) {
          if (plan != null && (_closed || ticket != _generation)) {
            unawaited(_releaseSession(plan.session));
            return null;
          }
          return plan;
        }),
      );
      DiaryService.add(
        '[Switch] episode=${detail.episodes[index].number}, phase=preload, elapsedMs=${switchClock.elapsedMilliseconds}, hit=${warmed != null}, startup=${warmed?.startupReady ?? false}, complete=${warmed?.preloadComplete ?? false}',
      );
      if (_closed || ticket != _generation) return;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await attempt.guard(pausedPrevious);
        await attempt.guard(frameReady);
        if (_closed || ticket != _generation) return;
        if (smooth) {
          unawaited(_saveProgress(flush: true));
        } else {
          await attempt.guard(_saveProgress(flush: true));
        }
        if (_closed || ticket != _generation) return;
        await attempt.guard(_enhancement.beforeMedia());
        if (_closed || ticket != _generation) return;
        _openedIndex = -1;
        _openedDetail = null;
        if (changingSeason) {
          _enhancement.setContent(
            category: detail.drama.category,
            tags: detail.drama.tags,
          );
        }
        if (!smooth) await attempt.guard(_player.stop());
        if (_closed || ticket != _generation) return;
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (smooth) {
          transitionPrevious = previous;
        } else if (previous != null) {
          await _releaseSession(previous.session);
        }
      }, attempt: attempt);
      if (_closed || ticket != _generation) {
        return;
      }
      final resolveClock = Stopwatch()..start();
      DiaryService.add(
        '[Resolve] episode=${detail.episodes[index].number}, mode=${retained != null
            ? 'alternative'
            : warmed != null
            ? 'preloaded'
            : 'fresh'}',
      );
      prepared = await attempt.guard(
        retained != null
            ? _loader.fallback(retained!)
            : warmed != null
            ? _loader.use(warmed)
            : _loader.load(
                detail.drama,
                detail.episodes[index],
                quality: _requestedQuality,
                localOnly: widget.localOnly,
                online: _forceOnline,
                onRetry: (round) {
                  if (mounted && !_closed && ticket == _generation) {
                    setState(() => _loadingMessage = '片源暂未响应，正在重试（$round/3）');
                    DiaryService.add(
                      '[Resolve] empty response recovery round=$round',
                    );
                  }
                },
              ),
      );
      if (prepared == null) {
        if (!_closed && ticket == _generation) {
          throw AppFailure('播放准备已中断，请重试');
        }
        return;
      }
      DiaryService.add(
        '[Resolve] ready after ${resolveClock.elapsedMilliseconds}ms, local=${prepared.local}, route=${prepared.routeIndex + 1}/${prepared.routeCount}',
      );
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await _releaseSession(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          Future<void> setProperty(String name, String value) =>
              attempt.guard(platform.setProperty(name, value));
          if (Platform.isAndroid) {
            if (_television) {
              await setProperty('hwdec', 'mediacodec');
              await setProperty('hwdec-codecs', 'all');
              await setProperty('opengl-pbo', 'yes');
              await setProperty('video-latency-hacks', 'yes');
              await setProperty('scale', 'bilinear');
              await setProperty('cscale', 'bilinear');
              await setProperty('dscale', 'bilinear');
              await setProperty('correct-downscaling', 'no');
              await setProperty('vd-lavc-skiploopfilter', 'all');
              await setProperty('vd-lavc-skipidct', 'all');
              await setProperty('vd-lavc-threads', '2');
              await setProperty('demuxer-max-bytes', '${4 * 1024 * 1024}');
              await setProperty('demuxer-max-back-bytes', '${1 * 1024 * 1024}');
              await setProperty('demuxer-readahead-secs', '5');
            } else {
              await setProperty('hwdec', 'auto-safe');
              await setProperty('hwdec-codecs', 'all');
              await setProperty('vd-lavc-skiploopfilter', 'nonkey');
              await setProperty('vd-lavc-threads', '4');
            }
            await setProperty('vd-lavc-fast', 'yes');
            await setProperty('video-sync', 'audio');
            await setProperty('framedrop', 'vo');
          }
          await setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await setProperty('network-timeout', '20');
        }
        if (_closed || ticket != _generation) return;
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        DiaryService.add(
          '[Play] 调用 _player.open: url=${plan.url}, headers=${plan.headers.keys.toList()}',
        );
        final media = Media(
          plan.url,
          httpHeaders: plan.headers,
          start: position > 0
              ? Duration(milliseconds: (position * 1000).round())
              : null,
        );
        DiaryService.add(
          '[Switch] episode=${detail.episodes[index].number}, phase=${smooth ? 'transition' : 'open'}, cached=${plan.preloadComplete}',
        );
        if (smooth) {
          await _player.transitionTo(
            media,
            play: _foreground && _playIntent,
            reopenOnFailure: plan.preloadState.isEmpty,
            identity: plan.session,
            mediaType: plan.mediaType,
            requestElapsedMs: switchClock.elapsedMilliseconds,
            retainPreviousFrame: retainPreviousFrame,
          );
        } else if (_player is LunaExoPlayer) {
          await _player.open(
            media,
            play: _foreground && _playIntent,
            mediaType: plan.mediaType,
          );
        } else {
          await _player.open(media, play: false);
          if (_closed || ticket != _generation) return;
          if (_foreground && _playIntent) {
            await attempt.guard(_player.play());
          }
        }
        if (_closed || ticket != _generation) {
          return;
        }
        if ((!_foreground || !_playIntent) && _player.state.playing) {
          await attempt.guard(
            _player.pause().timeout(const Duration(seconds: 3)),
          );
          if (_closed || ticket != _generation) return;
        }
        _openedIndex = index;
        _openedDetail = detail;
        _enhancement.mediaReady();
        _attachLanPlayback();
        _health.reset();
        await attempt.guard(_interactions.applySpeed());
        if (mounted && !_closed && ticket == _generation) {
          if (!_hasRetainedFrame) _transitionWaitTimer?.cancel();
          setState(() {
            _loading = false;
            _smoothTransition = _hasRetainedFrame;
          });
          if (!_playIntent) attempt.stable();
          if (_pendingError) _queueRecovery();
          DiaryService.add(
            '[Switch] episode=${detail.episodes[index].number}, phase=ready, requestToReadyMs=${switchClock.elapsedMilliseconds}, prepared=${smooth && _player.lastTransitionUsedPrepared}, firstFrame=${smooth && _player.lastTransitionFirstFrame}',
          );
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
          if (changingSeason && automaticAdvance) {
            _showSeasonNotice(detail, index);
          }
        }
      }, attempt: attempt);
    } catch (error) {
      if (error is PlaybackAttemptCancelled) {
        if (prepared != null && !installed) {
          unawaited(_releaseSession(prepared.session));
        }
        return;
      }
      if (error is AppFailure &&
          (error.code == 'source_blocked' ||
              error.code == 'playback_timeout')) {
        if (prepared != null && !installed) {
          unawaited(_releaseSession(prepared.session));
        }
        _failAttempt(attempt, error);
        return;
      }
      DiaryService.add('[Play] 捕获播放流程错误: $error');
      if (ticket == _generation && _player is LunaExoPlayer) {
        _player.clearRetainedFrame();
      }
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _transitionWaitTimer?.cancel();
          setState(() {
            _loading = false;
            _smoothTransition = false;
          });
          _acceptErrors = true;
          _queueRecovery(error: error.toString());
        } else {
          attempt.stable();
          if (prepared != null) {
            await _releaseSession(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
          }
        }
      } else if (prepared != null && !installed) {
        await _releaseSession(prepared.session);
      }
    } finally {
      if (transitionPrevious != null) {
        unawaited(_releaseSession(transitionPrevious!.session));
      }
      if (warmed != null && !installed) {
        await _releaseSession(warmed.session);
      }
      if (retained != null) {
        await _releaseSession(retained!.session);
      }
      _syncScreenOn();
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  bool _lowerQualityOffered = false;
  bool _sourceBlocked = false;

  int? get _lowerQuality =>
      _plan == null ||
          _sourceBlocked ||
          _localFailure ||
          widget.localOnly ||
          _plan?.local == true ||
          _decoderFailure
      ? null
      : lowerPlaybackQuality(_requestedQuality, _plan?.quality ?? 0);

  Future<bool> _offerLowerQuality() async {
    final quality = _lowerQuality;
    if (quality == null || !mounted || _closed) return false;
    final generation = _generation;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尝试较低清晰度？'),
        content: Text('当前视频持续卡顿，可以尝试 ${quality}P 片源。是否降低清晰度并保留当前进度重试？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不尝试'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('尝试 ${quality}P'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && !_closed && generation == _generation) {
      _preloader.clear();
      await _retry(quality: quality);
      return true;
    }
    return false;
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _player.state.playing,
    );
  }

  bool get _showFullscreen =>
      _television ||
      (_desktopPlayer && WindowsDesktop.current != null
          ? WindowsDesktop.current!.fullscreen
          : _fullscreen) ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (_desktopPlayer && WindowsDesktop.current != null) {
        await WindowsDesktop.current!.setFullscreen(fullscreen);
      } else if (_nativeMacWindow) {
        await DesktopFullscreen.instance.set(fullscreen);
      } else if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                television: _television,
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ),
            ));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  Future<void> _setWindowsEpisodes(bool expanded) async {
    if (!_desktopPlayer || _closed || !mounted) return;
    _interactions.cancel();
    setState(() {
      _windowsEpisodesExpanded = expanded;
      _windowsActivityRevision++;
    });
    _playerFocus.requestFocus();
    try {
      final saved = await widget.store.preferences.setBool(
        'windows_episode_sidebar_expanded',
        expanded,
      );
      if (!saved && mounted && !_closed) _interactions.hint('选集栏偏好暂未保存');
    } catch (_) {
      if (mounted && !_closed) _interactions.hint('选集栏偏好暂未保存');
    }
  }

  Future<void> _windowsEpisodes() => _windowsSidebarAvailable
      ? _setWindowsEpisodes(!_windowsEpisodesExpanded)
      : _openPanel(PlayerMenuSection.episodes);

  @override
  void onWindowEnterFullScreen() {
    if (_nativeMacWindow && mounted && !_closed) {
      setState(() => _fullscreen = true);
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (_nativeMacWindow && mounted && !_closed) {
      setState(() => _fullscreen = false);
    }
  }

  void _desktopChanged() {
    if (!mounted || _closed) return;
    _applyLifecycleVisibility(pauseWhenHidden: false);
    setState(() {});
  }

  void _syncDesktopPlayback() {
    if (!_desktopPlayer || _closed) return;
    final attached =
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked &&
        widget.store.allowsSource(_detail.drama.source);
    unawaited(
      WindowsDesktop.current
          ?.updatePlayback(
            attached: attached,
            playing: attached && _player.state.playing,
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> _toggleMini() async {
    final desktop = WindowsDesktop.current;
    if (desktop == null || _closed) return;
    _interactions.cancel();
    try {
      if (desktop.mini) {
        await desktop.leaveMini();
      } else {
        await desktop.enterMini(aspectRatio: _aspectRatio);
      }
    } catch (_) {
      if (mounted && !_closed) _notice('无法切换迷你窗，请重试');
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selectPlaybackPreference({double? speed, int? quality}) async {
    try {
      await _setPreferences(
        _preferences.copyWith(speed: speed, quality: quality),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final nextPreferences = preferences.copyWith(
      autoAdvance: true,
      preload: true,
    );
    final outputChanged =
        _player is LunaExoPlayer &&
        ((_television &&
                nextPreferences.tvTextureOutput !=
                    _preferences.tvTextureOutput) ||
            (_televisionDevice &&
                nextPreferences.tvDecoderMode != _preferences.tvDecoderMode));
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch)
      return;
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    _enhancement.setPreferences(nextPreferences.enhancement);
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _autoAdvance = true;
      _danmakuEnabled = nextPreferences.danmaku;
      _danmakuSpeed = nextPreferences.danmakuSpeed;
      _danmakuOpacity = nextPreferences.danmakuOpacity;
      _preloadEnabled = true;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (outputChanged || qualityChanged && _plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleSeriesFavorite(_detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _toggleDanmaku() async {
    if (_detail.drama.source != 'hongguo') return;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: !_danmakuEnabled));
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice('弹幕重试失败，请稍后再试');
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      _detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadsScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  bool get _canBrowseSeasons =>
      _detail.drama.source == SourceSite.hongguo.id &&
      !widget.localOnly &&
      widget.allowOnlineFallback &&
      widget.mediaId == null;

  Future<void> _browseSeasons() async {
    if (_panelOpen || _closed || !_canBrowseSeasons) return;
    _cancelSeasonAdvance();
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      final selection = await Navigator.of(context)
          .push<SeriesEpisodeSelection>(
            MaterialPageRoute(
              builder: (_) => SeriesBrowserScreen(
                anchor: _detail.drama,
                initialDetail: _detail,
                currentEpisode: _detail.episodes[_index].number,
                repository: widget.repository,
                store: widget.store,
              ),
            ),
          );
      if (!mounted ||
          _closed ||
          selection == null ||
          widget.store.profileEpoch != _profileEpoch ||
          widget.store.locked ||
          !widget.store.allowsSource(selection.detail.drama.source)) {
        return;
      }
      await _saveProgress(flush: true);
      if (!mounted || _closed) return;
      await _play(
        selection.index,
        nextDetail: selection.detail,
        position: selection.position,
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    var browseSeasons = false;
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _danmaku,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: _detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              local: _plan?.local == true,
              favorite: widget.store.followedSeries(_detail.drama) != null,
              mobile: _mobile,
              mobileReminders: _mobileRemindersAllowed,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onAllSeasons: _canBrowseSeasons
                  ? () => Navigator.pop(menuContext, -1)
                  : null,
              onPreferences: _setPreferences,
              showDanmaku: _detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              onFavorite: () =>
                  widget.store.toggleSeriesFavorite(_detail.drama),
            ),
          ),
        ),
      );
      if (index == -1) {
        browseSeasons = true;
      } else if (mounted && !_closed && index != null && index != _index) {
        await _play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
    if (browseSeasons && mounted && !_closed) await _browseSeasons();
  }

  Future<void> _seekTo(Duration target, {bool resumeAfterSeek = false}) async {
    if (_closed || _loading || _error != null) return;
    _cancelSeasonAdvance();
    _completedSeasonKey = null;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    final intentSequence = _seasonSequence;
    final resume = resumeAfterSeek && !_player.state.playing;
    _danmaku.beginSeek();
    _syncWatchReminders();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
        _syncWatchReminders();
      }
    }
    if (succeeded &&
        resume &&
        !_closed &&
        !_loading &&
        _error == null &&
        _foreground &&
        !_panelOpen &&
        !widget.store.locked &&
        widget.store.profileEpoch == _profileEpoch &&
        ticket == _seekSequence &&
        generation == _generation &&
        intentSequence == _seasonSequence &&
        target < _player.state.duration &&
        !_player.state.playing) {
      _playIntent = true;
      _syncScreenOn();
      _enhancement.mediaReady();
      _health.reset();
      try {
        await _player.play();
      } catch (_) {
        if (!_closed && generation == _generation) {
          _notice('播放失败，请重试');
        }
      }
      if (!_closed && generation == _generation) _syncDanmaku();
    }
  }

  void _seek(int seconds, {bool resumeAfterSeek = false}) {
    if (resumeAfterSeek &&
        (!_interactions.available() ||
            _player.state.duration <= Duration.zero)) {
      return;
    }
    if (resumeAfterSeek) _interactions.cancel();
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target, resumeAfterSeek: resumeAfterSeek));
    if (resumeAfterSeek) {
      _interactions.hint('快进至 ${formatPosition(target.inMilliseconds / 1000)}');
    }
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (dialogContext) => Theme(
          data: televisionTheme(AppTheme.dark),
          child: TelevisionEpisodeDialog(
            episodes: _detail.episodes,
            currentIndex: _index,
            onAllSeasons: _canBrowseSeasons
                ? () => Navigator.pop(dialogContext, -1)
                : null,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index == -1 && mounted && !_closed) {
      await _browseSeasons();
    } else if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _changePlaybackRoute() async {
    if (_closed || _loading || _plan?.hasAlternative != true) return;
    _recovery.reset();
    _decoderFailure = false;
    _playIntent = true;
    await _play(
      _index,
      position: _currentPosition,
      recoveryAction: PlaybackRecoveryAction.alternative,
    );
  }

  Widget _televisionRecoveryActions(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 10,
    alignment: WrapAlignment.center,
    children: [
      FilledButton.tonalIcon(
        key: const ValueKey('tv-recovery-settings'),
        onPressed: () => _televisionSettings(context),
        icon: const Icon(Icons.tune_rounded),
        label: const Text('播放设置'),
      ),
      if (!_loading && !_localFailure && _plan?.hasAlternative == true)
        FilledButton.tonalIcon(
          key: const ValueKey('tv-recovery-source'),
          onPressed: _changePlaybackRoute,
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('更换播放线路'),
        ),
      TextButton.icon(
        key: const ValueKey('tv-recovery-back'),
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text('返回选剧'),
      ),
    ],
  );

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionSettingsDialog(
              speed: _speed,
              tvTextureOutput: _player is LunaExoPlayer
                  ? _preferences.tvTextureOutput
                  : null,
              tvDecoderMode: _player is LunaExoPlayer && _televisionDevice
                  ? _preferences.tvDecoderMode
                  : null,
              quality: _requestedQuality,
              qualities: _plan?.qualities ?? [],
              favorite: widget.store.followedSeries(_detail.drama) != null,
              onFavorite: _toggleFavorite,
              autoAdvance: _autoAdvance,
              danmaku: _danmakuEnabled,
              danmakuSpeed: _danmakuSpeed,
              danmakuOpacity: _danmakuOpacity,
              showDanmaku: _detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preload: _preloadEnabled,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          tvTextureOutput: selection.tvTextureOutput,
          tvDecoderMode: selection.tvDecoderMode,
          quality: selection.quality,
          autoAdvance: true,
          danmaku: selection.danmaku,
          danmakuSpeed: selection.danmakuSpeed,
          danmakuOpacity: selection.danmakuOpacity,
          preload: true,
          enhancement: selection.enhancement,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  void _back() {
    if (_reminderVisible) {
      _watchReminders?.dismiss();
      return;
    }
    _cancelSeasonAdvance();
    _dismissSeasonNotice();
    if (_television) {
      if (_televisionControls.currentState?.handleBack() ?? false) return;
      Navigator.of(context).maybePop();
      return;
    }
    if (_showFullscreen && !_television) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    if (_nativeMacWindow) windowManager.removeListener(this);
    if (_desktopPlayer) {
      WindowsDesktop.current?.removeListener(_desktopChanged);
      unawaited(WindowsDesktop.current?.detachPlayback(this));
    }
    if (identical(WindowsUpdateRuntime.owner, this)) {
      WindowsUpdateRuntime.owner = null;
      WindowsUpdateRuntime.playing = null;
      WindowsUpdateRuntime.savePlayback = null;
    }
    _transitionWaitTimer?.cancel();
    _watchReminders?.removeListener(_reminderChanged);
    _watchReminders?.detachPlayback(this);
    _closed = true;
    _cancelOperations();
    _attempt?.cancel();
    _attempt = null;
    if (_player is LunaExoPlayer) {
      unawaited(_player.cancelPending().catchError((Object _) {}));
    }
    if (_player is LunaExoPlayer) {
      _player.frameHold.removeListener(_retainedFrameChanged);
      _player.clearRetainedFrame();
    }
    _syncScreenOn();
    _dismissSeasonNotice();
    _setTelevisionPlaybackActive(false);
    final enhancementClosed = _enhancement.close();
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _windowsVolumeTimer?.cancel();
    unawaited(_saveWindowsVolume());
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _pictureInPictureExitTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(_releaseSession(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    final disposal = () async {
      await _interactions.pendingRates
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) {});
      await enhancementClosed
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) {});
      try {
        await _player.dispose().timeout(const Duration(seconds: 5));
      } catch (error) {
        DiaryService.add('[Player] cleanup incomplete: $error');
      }
    }();
    if (_desktopPlayer) WindowsDesktop.current?.playbackDisposal = disposal;
    unawaited(disposal);
    if (_nativeMacWindow) {
      unawaited(
        DesktopFullscreen.instance.set(false).catchError((Object error) {
          DiaryService.add('[Player] fullscreen cleanup failed: $error');
        }),
      );
    } else if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile || _television && Platform.isAndroid) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen || _portraitWatching
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: Stack(
              children: [
                _buildPlayer(context),
                if (_reminderVisible) _watchReminderDialog(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final title = _desktopPlayer
        ? '${_detail.drama.title} · ${episodeProgressLabel(_detail, _index)}'
        : _detail.drama.title;
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible;
    return PopScope(
      canPop: _windowsMini
          ? false
          : _television
          ? !_televisionOverlayVisible
          : !fullscreen && !_reminderVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _windowsMini) {
          unawaited(_toggleMini());
          return;
        }
        if (!didPop && _reminderVisible) {
          _watchReminders?.dismiss();
          return;
        }
        _cancelSeasonAdvance();
        _dismissSeasonNotice();
        if (!didPop && _television) {
          _televisionControls.currentState?.handleBack();
          return;
        }
        if (!didPop && fullscreen && !_television) {
          _rotate();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.escape,
            includeRepeats: false,
          ): _back,
          const SingleActivator(
            LogicalKeyboardKey.goBack,
            includeRepeats: false,
          ): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor:
                fullscreen ||
                    _windowsMini ||
                    pictureInPicture ||
                    _portraitWatching
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            appBar: pictureInPicture || fullscreen || _windowsMini || _mobile
                ? null
                : AppBar(
                    title: _desktopPlayer
                        ? Semantics(
                            label: title,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _detail.drama.title,
                                    key: const ValueKey('windows-player-title'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    episodeProgressLabel(_detail, _index),
                                    key: const ValueKey(
                                      'windows-player-episode',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text(
                            title,
                            key: _desktopPlayer
                                ? const ValueKey('windows-player-title')
                                : null,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    actions: [
                      if (_desktopPlayer && WindowsDesktop.current != null)
                        IconButton(
                          key: const ValueKey('windows-mini'),
                          tooltip: '迷你窗（置顶）',
                          onPressed: _toggleMini,
                          icon: const Icon(
                            Icons.picture_in_picture_alt_rounded,
                          ),
                        ),
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            body: pictureInPicture
                ? _videoPane(context)
                : SafeArea(
                    top: !_television && (fullscreen || _mobile),
                    bottom: !fullscreen,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 840;
                        if (_desktopPlayer) {
                          final visible =
                              _windowsEpisodesExpanded &&
                              !fullscreen &&
                              !_windowsMini &&
                              constraints.maxWidth >= 760;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _videoPane(context)),
                              Visibility(
                                visible: visible,
                                maintainState: true,
                                child: SizedBox(
                                  key: const ValueKey(
                                    'windows-episode-sidebar',
                                  ),
                                  width: desktop ? 312 : 210,
                                  child: _windowsSidebar(),
                                ),
                              ),
                            ],
                          );
                        }
                        if (fullscreen || _portraitWatching) {
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 312 : 210,
                                child: _episodePanel(),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          final height = (constraints.maxWidth / _aspectRatio)
                              .clamp(0.0, constraints.maxHeight * .56);
                          return Column(
                            children: [
                              SizedBox(
                                height: height,
                                width: double.infinity,
                                child: _videoPane(context),
                              ),
                              Expanded(child: _mobilePlaybackPanel()),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / _aspectRatio)
                            .clamp(0.0, constraints.maxHeight * .64);
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(child: _episodePanel()),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final videoTheme = _television
        ? televisionTheme(AppTheme.dark)
        : AppTheme.dark;
    final title =
        '${_detail.drama.title} · ${episodeProgressLabel(_detail, _index)}${_plan?.local == true ? ' · 本地' : ''}${_detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    final hideOverlayForPictureInPicture = _pictureInPictureVisible;
    final Widget controls = hideOverlayForPictureInPicture
        ? const SizedBox.shrink()
        : _television
        ? TelevisionControls(
            key: _televisionControls,
            onVisibilityChanged: (visible) {
              if (_televisionOverlayVisible != visible) {
                setState(() => _televisionOverlayVisible = visible);
              }
            },
            player: _player,
            title: title,
            enabled: !_loading && _error == null,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            quietEpisodeChange: () => _quietEpisodeChange,
            enhancement: _enhancementForUi,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onSeekTo: _seekTo,
            speed: _speed,
            qualityLabel: _qualityLabel,
            showDanmaku: _detail.drama.source == 'hongguo',
            danmakuEnabled: _danmakuEnabled,
            onDanmaku: _detail.drama.source == 'hongguo'
                ? _toggleDanmaku
                : null,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < _detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onDiary: () async {
              final player = _player;
              if (player is LunaExoPlayer) {
                await player.reportNativeDiagnostics();
              }
              if (!context.mounted || _closed) return;
              await DiaryService.showDiaryDialog(context);
            },
            onBack: _back,
          )
        : PlayerControls(
            player: _player,
            interactions: _interactions,
            enabled: !_loading && _error == null,
            enhancement: _enhancementForUi,
            panelOpen: _panelOpen,
            fullscreen: _showFullscreen,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            quietEpisodeChange: () => _quietEpisodeChange,
            title: _detail.drama.title,
            episodeLabel: episodeProgressLabel(_detail, _index),
            portraitFooter: _portraitWatching ? _mobilePortraitFooter() : null,
            onTogglePlayback: _togglePlayback,
            onForward: () => _seek(15, resumeAfterSeek: true),
            swipeEnabled: _mobile,
            onFullscreen: _rotate,
            onBack: _back,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _speed,
            qualityLabel: _qualityLabel,
            showDanmaku: _detail.drama.source == 'hongguo',
            danmakuEnabled: _danmakuEnabled,
            danmakuStatus: _danmaku.status,
            onEpisodes: () => _portraitWatching
                ? _openMobileDetails(0)
                : _openPanel(PlayerMenuSection.episodes),
            onSidebar: _desktopPlayer ? _windowsEpisodes : null,
            onMini: _desktopPlayer && WindowsDesktop.current != null
                ? _toggleMini
                : null,
            desktopMini: _windowsMini,
            desktopEpisodesExpanded: _desktopPlayer
                ? _windowsSidebarAvailable && _windowsEpisodesExpanded
                : null,
            desktopActivityRevision: _windowsActivityRevision,
            episodesTooltip: !_desktopPlayer || !_windowsSidebarAvailable
                ? null
                : _windowsEpisodesExpanded
                ? '收起选集栏'
                : '展开选集栏',
            onSelectSpeed: (speed) => _selectPlaybackPreference(speed: speed),
            onSelectQuality: _plan?.local == true
                ? null
                : (quality) => _selectPlaybackPreference(quality: quality),
            qualities: (_plan?.qualities.isNotEmpty ?? false)
                ? _plan!.qualities
                : playbackQualities.where((value) => value > 0).toList(),
            selectedQuality: _requestedQuality,
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onSettings: () => _openPanel(PlayerMenuSection.settings),
            onDanmakuSettings: _mobile
                ? () => _openPanel(PlayerMenuSection.danmaku)
                : null,
            onDanmaku: _detail.drama.source == 'hongguo'
                ? _toggleDanmaku
                : null,
            onRetryDanmaku: _danmaku.canRetry
                ? _retryDanmakuFromControls
                : null,
            onPush: widget.mediaId == null ? _pushToDevice : null,
            onPictureInPicture: _canUsePictureInPicture
                ? _enterPictureInPicture
                : null,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < _detail.episodes.length
                ? () => _play(_index + 1)
                : null,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (_player is LunaExoPlayer)
          AnimatedBuilder(
            animation: Listenable.merge([
              _player.frameHold,
              _player.frameHoldFailure,
            ]),
            builder: (context, _) {
              final image = _player.frameHold.image;
              final failure = _player.frameHoldFailure.value;
              return IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (image != null)
                      ColoredBox(
                        key: const ValueKey('automatic-transition-frame'),
                        color: Colors.black,
                        child: RawImage(image: image, fit: BoxFit.contain),
                      ),
                    if (failure != null && !hideOverlayForPictureInPicture)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(failure),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        if (!hideOverlayForPictureInPicture && !_hasRetainedFrame)
          DanmakuOverlay(
            controller: _danmaku,
            animationBehavior: AppLayout.isTelevisionDevice(context)
                ? AnimationBehavior.preserve
                : AnimationBehavior.normal,
            desktop: _desktopPlayer,
            speed: _preferences.effectiveDanmakuSpeed(mobile: _mobile),
            opacity: _preferences.effectiveDanmakuOpacity(
              mobile: _mobile,
              television: _television,
            ),
            aspectRatio: _aspectRatio,
            television: _television,
            mobile: _mobile,
          ),
        controls,
        if (!hideOverlayForPictureInPicture && _seasonNotice != null)
          IgnorePointer(
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Text(
                      _seasonNotice!,
                      key: const ValueKey('next-season-notice'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _television ? 16 : 14,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: .9),
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final pane = Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final pixels = Size(
            constraints.maxWidth * ratio,
            constraints.maxHeight * ratio,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closed) {
              _enhancement.setViewport(pixels, television: _television);
              _recordWindowsVideoGeometry();
            }
          });
          return Stack(
            key: _videoPaneKey,
            fit: StackFit.expand,
            children: [
              if (widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else if (_player is LunaExoPlayer)
                LunaExoVideoView(
                  player: _player,
                  fit: BoxFit.contain,
                  controls: (_) => layeredControls,
                )
              else
                Video(
                  controller: _video!,
                  pauseUponEnteringBackgroundMode: !_desktopPlayer,
                  fit: BoxFit.contain,
                  controls: (_) => layeredControls,
                ),
              if (_loading &&
                  !_smoothTransition &&
                  !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .78),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(_loadingMessage),
                      ],
                    ),
                  ),
                ),
              if ((_loading || _hasRetainedFrame) &&
                  _smoothTransition &&
                  _transitionWaitVisible &&
                  !hideOverlayForPictureInPicture)
                const Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      '正在衔接下一集…',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                      ),
                    ),
                  ),
                ),
              if (_televisionDevice &&
                  _loading &&
                  _error == null &&
                  !hideOverlayForPictureInPicture)
                Positioned(
                  bottom: 24,
                  left: 24,
                  right: 24,
                  child: _televisionRecoveryActions(context),
                ),
              if (_error != null && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .9),
                  child: StatusPanel(
                    title: '暂时无法播放',
                    message: _sourceBlocked || _localFailure || _decoderFailure
                        ? _error!
                        : '本集暂时无法播放，请稍后重试。具体原因可查看失败详情或播放日志。',
                    onRetry: () => _retry(),
                    action: _localFailure ? '重试本地播放' : '重试播放',
                    secondaryAction: Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (!_sourceBlocked &&
                            !_localFailure &&
                            !widget.localOnly)
                          TextButton.icon(
                            key: const ValueKey('player-error-quality'),
                            onPressed: () =>
                                _openPanel(PlayerMenuSection.quality),
                            icon: const Icon(Icons.tune),
                            label: const Text('选择清晰度'),
                          ),
                        if (_lowerQuality != null && !_lowerQualityOffered)
                          FilledButton.icon(
                            key: const ValueKey('player-lower-quality'),
                            onPressed: _offerLowerQuality,
                            icon: const Icon(Icons.network_check),
                            label: Text('尝试 ${_lowerQuality}P'),
                          ),
                        TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('播放失败详情'),
                              content: SingleChildScrollView(
                                child: SelectableText(_error ?? ''),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          ),
                          child: const Text('查看失败详情'),
                        ),
                        if (_televisionDevice)
                          _televisionRecoveryActions(context),
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              DiaryService.showDiaryDialog(context),
                          icon: const Icon(Icons.receipt_long_rounded),
                          label: const Text('查看播放日记'),
                        ),
                        if (_localFailure && widget.allowOnlineFallback)
                          TextButton.icon(
                            onPressed: _switchOnline,
                            icon: const Icon(Icons.cloud_outlined),
                            label: const Text('改为在线播放'),
                          )
                        else if (!_localFailure &&
                            !widget.localOnly &&
                            widget.repository.supportsSourceManagement)
                          SourceDiagnosticsButton(
                            repository: widget.repository,
                            store: widget.store,
                            drama: _detail.drama,
                          ),
                      ],
                    ),
                    icon: Icons.play_disabled_rounded,
                  ),
                ),
              if (((_loading &&
                          (!_smoothTransition || _transitionWaitVisible)) ||
                      _error != null) &&
                  !hideOverlayForPictureInPicture &&
                  _showFullscreen &&
                  !_television)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '退出全屏',
                          onPressed: _rotate,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              _openPanel(PlayerMenuSection.episodes),
                          child: const Text('选集'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saveWarning != null && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _saveWarning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: const Text('重试保存'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    return EpisodeSwipeSurface(
      interactions: _interactions,
      enabled: _mobile && !_showFullscreen,
      contentReady: !_loading && _error == null,
      currentLabel:
          '${_detail.drama.title}\n${episodeProgressLabel(_detail, _index)}',
      previousLabel: _index > 0
          ? '${_detail.drama.title}\n第 ${_detail.episodes[_index - 1].number} 集'
          : '已经是第一集',
      nextLabel: _index + 1 < _detail.episodes.length
          ? '${_detail.drama.title}\n第 ${_detail.episodes[_index + 1].number} 集'
          : '已经是最后一集',
      child: pane,
    );
  }

  Widget _mobilePortraitFooter() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _detail.drama.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _mobileDetailButton(1, '简介', Icons.info_outline_rounded),
            _mobileDetailButton(2, '下载', Icons.download_outlined),
          ],
        ),
        SizedBox(
          width: double.infinity,
          height: 38,
          child: TextButton.icon(
            key: const ValueKey('player-portrait-episodes'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: .10),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => _openMobileDetails(0),
            icon: const Icon(Icons.grid_view_rounded, size: 18),
            label: Row(
              children: [
                Expanded(
                  child: Text('选集 · ${episodeProgressLabel(_detail, _index)}'),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _mobileDetailButton(int tab, String label, IconData icon) =>
      TextButton.icon(
        key: ValueKey('player-portrait-details-$tab'),
        onPressed: () => _openMobileDetails(tab),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white70,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(48, 42),
        ),
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      );

  Future<void> _openMobileDetails(int tab) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() {
      _panelOpen = true;
      _mobileTab = tab;
    });
    var browseSeasons = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: AppTheme.dark.colorScheme.surface,
        barrierColor: Colors.black.withValues(alpha: .25),
        builder: (sheetContext) => Theme(
          data: AppTheme.dark,
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .68,
            child: StatefulBuilder(
              builder: (panelContext, refreshSheet) => AnimatedBuilder(
                animation: Listenable.merge([_menuRevision, widget.store]),
                builder: (_, _) => _mobilePlaybackPanel(
                  panelContext: panelContext,
                  onTabChanged: (value) =>
                      refreshSheet(() => _mobileTab = value),
                  onClose: () => Navigator.pop(sheetContext),
                  onAllSeasons: () {
                    browseSeasons = true;
                    Navigator.pop(sheetContext);
                  },
                  onEpisodeSelected: (index) {
                    Navigator.pop(sheetContext);
                    if (index != _index) unawaited(_play(index));
                  },
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
    if (browseSeasons && mounted && !_closed) await _browseSeasons();
  }

  Widget _mobilePlaybackPanel({
    BuildContext? panelContext,
    ValueChanged<int>? onTabChanged,
    VoidCallback? onClose,
    ValueChanged<int>? onEpisodeSelected,
    VoidCallback? onAllSeasons,
  }) {
    final context = panelContext ?? this.context;
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _mobileTabs(colors, onTabChanged: onTabChanged),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: '收起面板',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _mobileTab == 0
                      ? _episodePanel(
                          compact: true,
                          onSelected: onEpisodeSelected,
                          onAllSeasons: onAllSeasons,
                          panelContext: context,
                        )
                      : _mobileTab == 1
                      ? _mobileSynopsis(panelContext: context)
                      : _mobileDownload(panelContext: context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileTabs(
    ColorScheme colors, {
    ValueChanged<int>? onTabChanged,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
    child: SizedBox(
      height: 42,
      child: Row(
        children: [
          _mobileTabButton(0, '选集', colors: colors, onTabChanged: onTabChanged),
          _mobileTabButton(1, '简介', colors: colors, onTabChanged: onTabChanged),
          _mobileTabButton(2, '下载', colors: colors, onTabChanged: onTabChanged),
        ],
      ),
    ),
  );

  Widget _mobileTabButton(
    int value,
    String label, {
    ValueChanged<int>? onTabChanged,
    required ColorScheme colors,
  }) {
    final selected = _mobileTab == value;
    return Expanded(
      child: InkWell(
        onTap: () {
          if (onTabChanged != null) {
            onTabChanged(value);
          } else {
            setState(() => _mobileTab = value);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileSynopsis({BuildContext? panelContext}) {
    final context = panelContext ?? this.context;
    final drama = _detail.drama;
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
      if (drama.category.isNotEmpty) drama.category,
    ];
    final body = drama.description.trim().isEmpty ? '暂无简介' : drama.description;
    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            '${drama.onlineDate} 上线',
                          if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                          if (drama.views.isNotEmpty) '播放 ${drama.views}',
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mobileFollowControl(drama, panelContext: context),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  Chip(label: Text(tag), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            body,
            key: const ValueKey('player-description-text'),
            style: TextStyle(color: colors.onSurface, height: 1.55),
          ),
          if (_detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _mobileFollowControl(Drama drama, {BuildContext? panelContext}) {
    final context = panelContext ?? this.context;
    final followed = widget.store.followedSeries(drama) != null;
    return OutlinedButton.icon(
      key: const ValueKey('player-follow-status'),
      onPressed: () => saveUserChange(
        context,
        () => widget.store.toggleSeriesFavorite(drama),
      ),
      icon: Icon(
        followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
      ),
      label: Text(followed ? '取消追剧' : '加入追剧'),
    );
  }

  Widget _mobileDownload({BuildContext? panelContext}) {
    final context = panelContext ?? this.context;
    final colors = Theme.of(context).colorScheme;
    if (!widget.repository.supportsDownloads || !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surface,
        child: const StatusPanel(
          title: '下载不可用',
          message: '当前用户或当前环境未开放本地下载。',
          icon: Icons.download_outlined,
        ),
      );
    }
    return DownloadPicker(
      key: ValueKey(_detail.drama.id),
      detail: _detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _windowsSidebar() {
    final colors = Theme.of(context).colorScheme;
    Widget tab(bool description, String label) => Expanded(
      child: Semantics(
        selected: _windowsDescription == description,
        child: TextButton(
          key: ValueKey(
            description
                ? 'windows-sidebar-description'
                : 'windows-sidebar-episodes',
          ),
          style: TextButton.styleFrom(
            foregroundColor: _windowsDescription == description
                ? colors.onPrimaryContainer
                : colors.onSurface,
            backgroundColor: _windowsDescription == description
                ? colors.primaryContainer
                : null,
          ),
          onPressed: () => setState(() => _windowsDescription = description),
          child: Text(label),
        ),
      ),
    );
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(children: [tab(false, '选集'), tab(true, '简介')]),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _windowsDescription ? 1 : 0,
            children: [
              ExcludeFocus(
                excluding: _windowsDescription,
                child: _episodePanel(preserveScrollOnResize: true),
              ),
              ExcludeFocus(
                excluding: !_windowsDescription,
                child: WindowsDramaDescription(drama: _detail.drama),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _episodePanel({
    bool compact = false,
    ValueChanged<int>? onSelected,
    BuildContext? panelContext,
    VoidCallback? onAllSeasons,
    bool preserveScrollOnResize = false,
  }) => ColoredBox(
    color: Theme.of(panelContext ?? context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_canBrowseSeasons)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OutlinedButton.icon(
              key: const ValueKey('player-all-seasons'),
              onPressed: onAllSeasons ?? _browseSeasons,
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('查看全季'),
            ),
          ),
        Expanded(
          child: PlayerEpisodeGrid(
            key: ValueKey(_detail.drama.id),
            episodes: _detail.episodes,
            currentIndex: _index,
            compact: compact,
            title: compact ? '剧集' : '选集',
            preserveScrollOnResize: preserveScrollOnResize,
            onSelected: onSelected ?? (index) => _play(index),
          ),
        ),
      ],
    ),
  );
}
