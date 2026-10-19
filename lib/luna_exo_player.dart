import 'package:video_player_android/video_player_android.dart';
import 'tv_decoder_settings.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/models/player_log.dart';
import 'package:media_kit/src/models/player_stream.dart';
import 'package:media_kit/src/player/platform_player.dart';
import 'package:video_player/video_player.dart';

import 'diary_service.dart';
import 'playback_frame_hold.dart';

/// 模拟与 media_kit.PlayerStream 接口对齐的流集合
class LunaPlayerStreams implements PlayerStream {
  final StreamController<Duration> positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> durationController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> completedController =
      StreamController<bool>.broadcast();
  final StreamController<String> errorController =
      StreamController<String>.broadcast();
  final StreamController<double> volumeController =
      StreamController<double>.broadcast();
  final StreamController<double> rateController =
      StreamController<double>.broadcast();
  final StreamController<VideoParams> videoParamsController =
      StreamController<VideoParams>.broadcast();
  final StreamController<PlayerLog> logController =
      StreamController<PlayerLog>.broadcast();
  final StreamController<double> pitchController =
      StreamController<double>.broadcast();

  @override
  Stream<Duration> get position => positionController.stream;

  @override
  Stream<Duration> get duration => durationController.stream;

  @override
  Stream<Duration> get buffer => bufferController.stream;

  @override
  Stream<bool> get playing => playingController.stream;

  @override
  Stream<bool> get buffering => bufferingController.stream;

  @override
  Stream<bool> get completed => completedController.stream;

  @override
  Stream<String> get error => errorController.stream;

  @override
  Stream<double> get volume => volumeController.stream;

  @override
  Stream<double> get rate => rateController.stream;

  @override
  Stream<VideoParams> get videoParams => videoParamsController.stream;

  @override
  Stream<PlayerLog> get log => logController.stream;

  @override
  Stream<double> get pitch => pitchController.stream;

  void dispose() {
    positionController.close();
    durationController.close();
    bufferController.close();
    playingController.close();
    bufferingController.close();
    completedController.close();
    errorController.close();
    volumeController.close();
    rateController.close();
    videoParamsController.close();
    logController.close();
    pitchController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      return const Stream<dynamic>.empty();
    }
    return null;
  }
}

/// 采用和 LunaTV-Mobile 完全相同架构的 ExoPlayer (AndroidX Media3) 播放器封装，
/// 同时对上层红果鉴播控 UI (PlayerControls & TelevisionControls) 暴露完全兼容的 Player 契约。
class LunaExoPlayer implements Player {
  LunaExoPlayer({
    this.television,
    this.textureOutput,
    this.decoderMode,
    this.initializationTimeout = const Duration(seconds: 20),
    this.transitionTimeout = const Duration(seconds: 10),
    this.preparationRetryDelay = const Duration(seconds: 3),
  }) {
    state = const PlayerState().copyWith(volume: 100.0);
  }

  VideoPlayerController? _controller;
  final bool Function()? television;
  final bool Function()? textureOutput;
  final TvDecoderMode? Function()? decoderMode;
  final Duration initializationTimeout;
  final Duration transitionTimeout;
  final Duration preparationRetryDelay;
  String? _lastControllerError;
  static const diagnosticChannel = MethodChannel('hongguo/video_diagnostics');
  VoidCallback? _valueListener;
  Timer? _positionPollTimer;
  Timer? _diagnosticTimer;
  Timer? _nativeStartupTimer;
  bool _nativeDiagnosticUnavailable = false;
  bool _nativeSnapshotPending = false;
  int _durationRefreshTicks = 0;
  final _diagnosticClock = Stopwatch();
  int _diagnosticReportedAt = 0;
  int? _bufferStartedAt;
  int _bufferingMs = 0;
  int _bufferingCount = 0;
  int _uiFrames = 0;
  int _uiOverBudget = 0;
  int _buildPeakUs = 0;
  int _rasterPeakUs = 0;
  double _frameBudgetUs = 1000000 / 60;

  int _openGeneration = 0;
  bool _disposed = false;
  bool _transitioning = false;
  bool _transitionWantsPlay = false;
  int _prepareGeneration = 0;
  String? _preparedIdentity;
  String? _preparedUrl;
  String? _preparedMediaType;
  Map<String, String>? _preparedHeaders;
  Future<void>? _preparingNext;
  DateTime _prepareRetryAt = DateTime(2000);
  bool lastTransitionUsedPrepared = false;
  bool lastTransitionFirstFrame = false;
  final frameHold = PlaybackFrameHold();
  final frameHoldFailure = ValueNotifier<String?>(null);
  int _frameRetentionSequence = 0;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @override
  PlayerState state = const PlayerState();

  @override
  final LunaPlayerStreams stream = LunaPlayerStreams();

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<int> get handle => Future<int>.value(0);

  VideoPlayerController? get controller => _controller;

  bool get canTransition {
    final c = _controller;
    final nativeView =
        (television?.call() ?? false) && !(textureOutput?.call() ?? false);
    return !_disposed &&
        !_transitioning &&
        c != null &&
        c.value.isInitialized &&
        !c.value.hasError &&
        c.viewType ==
            (nativeView
                ? VideoViewType.platformView
                : VideoViewType.textureView);
  }

  Map<String, String> _headers(Media media) {
    final headers = Map<String, String>.from(media.httpHeaders ?? const {});
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
    return headers;
  }

  Future<Uint8List?> captureFrame({bool allowTelevision = false}) async {
    final c = _controller;
    if (!canTransition ||
        c == null ||
        (television?.call() == true && !allowTelevision) ||
        c.value.rotationCorrection != 0) {
      return null;
    }
    final generation = _openGeneration;
    try {
      final bytes = await diagnosticChannel
          .invokeMethod<Uint8List>('captureFrame', {
            'playerId': c.playerId,
            if (allowTelevision) 'allowTelevision': true,
          })
          .timeout(const Duration(milliseconds: 180), onTimeout: () => null);
      if (_disposed ||
          generation != _openGeneration ||
          _controller != c ||
          bytes == null ||
          bytes.lengthInBytes > 4 * 1024 * 1024) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> retainCurrentFrame() async {
    clearRetainedFrame();
    if (!canTransition) return false;
    final sequence = _frameRetentionSequence;
    final generation = _openGeneration;
    final c = _controller;
    final captured = await frameHold.capture(
      () => captureFrame(allowTelevision: true),
    );
    if (_disposed || sequence != _frameRetentionSequence) return false;
    if (generation != _openGeneration || c != _controller) {
      clearRetainedFrame();
      return false;
    }
    if (!captured) return false;
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 50),
      onTimeout: () {},
    );
    return !_disposed &&
        sequence == _frameRetentionSequence &&
        generation == _openGeneration &&
        c == _controller &&
        frameHold.active;
  }

  void clearRetainedFrame() {
    ++_frameRetentionSequence;
    frameHold.clear();
    frameHoldFailure.value = null;
  }

  Future<void> _waitForTransitionFrame(
    VideoPlayerController c,
    int generation,
    int nativeGeneration,
    int retentionSequence,
  ) async {
    bool current() =>
        !_disposed &&
        c == _controller &&
        generation == _openGeneration &&
        retentionSequence == _frameRetentionSequence;
    try {
      final result = await diagnosticChannel
          .invokeMapMethod<String, dynamic>('waitForFirstFrame', {
            'playerId': c.playerId,
            'generation': nativeGeneration,
          })
          .timeout(const Duration(seconds: 9));
      if (!current()) return;
      if (result?['firstFrame'] != true ||
          result?['generation'] != nativeGeneration) {
        throw StateError('下一集首帧未得到确认');
      }
      lastTransitionFirstFrame = true;
      clearRetainedFrame();
      DiaryService.add(
        '[FrameHold] target first frame, generation=$nativeGeneration',
      );
    } catch (error) {
      if (!current()) return;
      clearRetainedFrame();
      DiaryService.add(
        '[FrameHold] released without target frame, generation=$nativeGeneration: $error',
      );
      if (error is PlatformException && error.code == 'transition_cancelled') {
        return;
      }
      frameHoldFailure.value = '下一集画面加载失败，正在尝试恢复…';
      final failureSequence = _frameRetentionSequence;
      try {
        await c.pause().timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (_disposed ||
          c != _controller ||
          generation != _openGeneration ||
          failureSequence != _frameRetentionSequence) {
        return;
      }
      _reportControllerError(c, '下一集画面加载失败，请重试');
    }
  }

  Future<void> prepareNext(
    Media media, {
    required String identity,
    String mediaType = '',
  }) {
    if (!canTransition || identity.isEmpty) return Future<void>.value();
    final headers = _headers(media);
    if (_preparedIdentity == identity &&
        _preparedUrl == media.uri &&
        _preparedMediaType == mediaType &&
        mapEquals(_preparedHeaders, headers)) {
      return _preparingNext ?? Future<void>.value();
    }
    if (DateTime.now().isBefore(_prepareRetryAt)) return Future<void>.value();
    final c = _controller!;
    final ticket = ++_prepareGeneration;
    _preparedIdentity = identity;
    _preparedUrl = media.uri;
    _preparedMediaType = mediaType;
    _preparedHeaders = headers;
    final operation = () async {
      try {
        final result = await diagnosticChannel
            .invokeMapMethod<String, dynamic>('prepareNext', {
              'playerId': c.playerId,
              'identity': identity,
              'url': media.uri,
              'headers': headers,
              'mediaType': mediaType,
            })
            .timeout(const Duration(seconds: 12));
        if (_disposed || ticket != _prepareGeneration || _controller != c) {
          return;
        }
        if (result?['prepared'] != true) throw StateError('下一集样本尚未准备好');
        DiaryService.add(
          '[PrepareNext] ready identity=$identity, elapsedMs=${result?['elapsedMs']}',
        );
      } catch (error) {
        if (_disposed || ticket != _prepareGeneration || _controller != c) {
          return;
        }
        await clearPreparedNext(identity: identity);
        _prepareRetryAt = DateTime.now().add(preparationRetryDelay);
        DiaryService.add(
          '[PrepareNext] background preparation unavailable: $error',
        );
      }
    }();
    _preparingNext = operation;
    return operation;
  }

  Future<void> clearPreparedNext({String? identity}) async {
    if (identity != null && _preparedIdentity != identity) return;
    ++_prepareGeneration;
    _preparedIdentity = _preparedUrl = _preparedMediaType = null;
    _preparedHeaders = null;
    _preparingNext = null;
    _prepareRetryAt = DateTime(2000);
    final c = _controller;
    if (_disposed || c == null) return;
    try {
      await diagnosticChannel
          .invokeMethod<void>('clearNext', {
            'playerId': c.playerId,
            'identity': identity,
          })
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> transitionTo(
    Media media, {
    bool play = true,
    bool reopenOnFailure = true,
    String identity = '',
    String mediaType = '',
    int requestElapsedMs = 0,
    bool retainPreviousFrame = false,
  }) async {
    if (!retainPreviousFrame) clearRetainedFrame();
    if (!canTransition) return open(media, play: play, mediaType: mediaType);
    final c = _controller!;
    final ticket = ++_openGeneration;
    final retentionSequence = _frameRetentionSequence;
    final clock = Stopwatch()..start();
    _transitioning = true;
    _transitionWantsPlay = play;
    ++_prepareGeneration;
    _preparedIdentity = _preparedUrl = _preparedMediaType = null;
    _preparedHeaders = null;
    _preparingNext = null;
    _prepareRetryAt = DateTime(2000);
    lastTransitionUsedPrepared = lastTransitionFirstFrame = false;
    _positionPollTimer?.cancel();
    _stopDiagnostics();
    final headers = Map<String, String>.from(media.httpHeaders ?? const {});
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
    try {
      if (_disposed || ticket != _openGeneration) return;
      final result = await diagnosticChannel
          .invokeMapMethod<String, dynamic>('transition', {
            'playerId': c.playerId,
            'url': media.uri,
            'headers': headers,
            'identity': identity,
            'mediaType': mediaType,
            'requestElapsedMs': requestElapsedMs,
          })
          .timeout(transitionTimeout);
      if (_disposed || ticket != _openGeneration || _controller != c) return;
      if (result == null) throw StateError('切集未返回首帧结果');
      lastTransitionUsedPrepared = result['usedPrepared'] == true;
      lastTransitionFirstFrame = result['firstFrame'] == true;
      final duration = Duration(
        milliseconds: (result['durationMs'] as num).toInt(),
      );
      final width = (result['width'] as num).toDouble();
      final height = (result['height'] as num).toDouble();
      c.value = c.value.copyWith(
        duration: duration,
        position: Duration.zero,
        buffered: const [],
        size: width > 0 && height > 0 ? Size(width, height) : c.value.size,
        rotationCorrection: (result['rotation'] as num?)?.toInt() ?? 0,
        isInitialized: true,
        isCompleted: false,
        isPlaying: false,
        isBuffering: false,
        errorDescription: null,
      );
      state = state.copyWith(
        completed: false,
        position: Duration.zero,
        duration: duration,
        buffer: Duration.zero,
        playing: false,
        buffering: false,
      );
      _safeAdd(stream.completedController, false);
      _safeAdd(stream.positionController, Duration.zero);
      _safeAdd(stream.durationController, duration);
      _safeAdd(stream.bufferController, Duration.zero);
      final size = c.value.size;
      final params = VideoParams(
        w: size.width.round(),
        h: size.height.round(),
        dw: size.width.round(),
        dh: size.height.round(),
      );
      state = state.copyWith(
        width: params.w,
        height: params.h,
        videoParams: params,
      );
      _safeAdd(stream.videoParamsController, params);
      _transitioning = false;
      _lastControllerError = null;
      _startDiagnostics();
      _startPositionPolling();
      if (_transitionWantsPlay) {
        await c.play().timeout(const Duration(seconds: 3));
      }
      _onControllerValue(c);
      if (retainPreviousFrame && frameHold.active) {
        final nativeGeneration = (result['transitionGeneration'] as num?)
            ?.toInt();
        if (lastTransitionFirstFrame) {
          clearRetainedFrame();
        } else if (nativeGeneration != null && nativeGeneration > 0) {
          unawaited(
            _waitForTransitionFrame(
              c,
              ticket,
              nativeGeneration,
              retentionSequence,
            ),
          );
        } else {
          clearRetainedFrame();
        }
      }
      revision.value++;
      DiaryService.add(
        '[Transition] reused player=${c.playerId}, readyMs=${clock.elapsedMilliseconds}, firstFrame=${result['firstFrame']}, nativeMs=${result['elapsedMs']}, usedPrepared=${result['usedPrepared']}, preloadReady=${result['preloadReady']}',
      );
    } catch (error) {
      if (_disposed || ticket != _openGeneration) return;
      _transitioning = false;
      clearRetainedFrame();
      if (!reopenOnFailure) {
        DiaryService.add('[Transition] 预取交接失败，交由重新取址: $error');
        rethrow;
      }
      DiaryService.add('[Transition] 复用失败，重新初始化: $error');
      await open(media, play: _transitionWantsPlay, mediaType: mediaType);
    } finally {
      if (ticket == _openGeneration) _transitioning = false;
    }
  }

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    String mediaType = '',
  }) async {
    final pending = _openMedia(playable, play: play, mediaType: mediaType);
    final ticket = _openGeneration;
    await pending.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        if (!_disposed && ticket == _openGeneration) {
          ++_openGeneration;
          unawaited(_releaseController());
        }
        throw TimeoutException('播放器加载超时');
      },
    );
  }

  Future<void> _openMedia(
    Playable playable, {
    bool play = true,
    String mediaType = '',
  }) async {
    if (_disposed) return;
    if (playable is! Media) return;

    final media = playable;
    final url = media.uri;
    if (url.isEmpty) return;

    final myGen = ++_openGeneration;
    _positionPollTimer?.cancel();
    _stopDiagnostics();

    await _releaseController();
    if (_disposed || myGen != _openGeneration) return;
    state = state.copyWith(
      completed: false,
      playing: false,
      buffering: false,
      position: Duration.zero,
      duration: Duration.zero,
      buffer: Duration.zero,
    );
    _safeAdd(stream.completedController, false);

    final Map<String, String> headers = <String, String>{};
    try {
      if (media.httpHeaders != null) {
        headers.addAll(Map<String, String>.from(media.httpHeaders!));
      }
    } catch (_) {}

    // 针对防盗链 CDN 注入标准移动端 UA
    if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }

    final uri = Uri.tryParse(url);
    if (uri == null && !url.startsWith('/')) {
      throw Exception('无效的播放地址');
    }
    bool isHls =
        mediaType == 'hls' ||
        mediaType.isEmpty &&
            (uri?.path.toLowerCase().endsWith('.m3u8') ?? false);
    bool formatKnown = isHls || mediaType == 'mp4';
    String? preparationError;
    if (mediaType.isEmpty &&
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 5));
        headers.forEach((k, v) => req.headers.set(k, v));
        req.headers.set('Range', 'bytes=0-511');
        final resp = await req.close().timeout(const Duration(seconds: 8));
        final cType = resp.headers.contentType?.toString().toLowerCase() ?? '';
        final chunks = await resp
            .take(1)
            .timeout(const Duration(seconds: 5))
            .toList();
        final bytes = chunks.isNotEmpty ? chunks.first : <int>[];
        final firstChunk = String.fromCharCodes(bytes.take(512));
        final mp4 =
            bytes.length >= 8 &&
            String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp';
        final hls =
            cType.contains('mpegurl') ||
            firstChunk.trimLeft().startsWith('#EXTM3U');
        if (hls || mp4) {
          isHls = hls;
          formatKnown = true;
        }
        final transport = resp.headers.value('X-Hongguo-Media') ?? 'original';
        DiaryService.add(
          '[Sniff] status=${resp.statusCode}, contentType=$cType, mp4=$mp4, hls=$hls, transport=$transport',
        );
        if (resp.statusCode >= 400 &&
            uri.host == '127.0.0.1' &&
            uri.queryParameters['cenc'] == 'clear') {
          preparationError = 'MP4 解密转发失败（HTTP ${resp.statusCode}），请重新解析或切换线路';
        }
      } catch (e) {
        DiaryService.add('[Sniff] 探测警告: $e');
      } finally {
        client.close(force: true);
      }
    }
    if (preparationError != null) {
      DiaryService.add('[ExoPlayer] $preparationError');
      throw Exception(preparationError);
    }

    if (_disposed || myGen != _openGeneration) return;
    VideoFormat? formatHint = isHls ? VideoFormat.hls : null;
    final viewType =
        (television?.call() ?? false) && !(textureOutput?.call() ?? false)
        ? VideoViewType.platformView
        : VideoViewType.textureView;

    DiaryService.add(
      '[ExoPlayer] open(gen=$myGen): url=$url, isHls=$isHls, formatHint=$formatHint, output=$viewType, headers=${headers.keys.toList()}',
    );

    final decoder = decoderMode?.call();
    final options = decoder == null
        ? VideoPlayerOptions(mixWithOthers: true)
        : AndroidDecoderOptions(decoderMode: decoder.name);
    DiaryService.add(
      '[ExoPlayer] decoder=${decoder?.name ?? "system-default"}',
    );
    VideoPlayerController c;
    if (url.startsWith('/') || (uri != null && uri.scheme == 'file')) {
      final filePath = uri != null && uri.scheme == 'file'
          ? uri.toFilePath()
          : url;
      DiaryService.add('[ExoPlayer] 本地文件播放: $filePath');
      c = VideoPlayerController.file(
        File(filePath),
        viewType: viewType,
        videoPlayerOptions: options,
      );
    } else {
      c = VideoPlayerController.networkUrl(
        uri!,
        viewType: viewType,
        formatHint: formatHint,
        httpHeaders: headers,
        videoPlayerOptions: options,
      );
    }

    try {
      DiaryService.add(
        '[ExoPlayer] c.initialize() 开始 (formatHint=$formatHint)...',
      );
      await c.initialize().timeout(initializationTimeout);
      DiaryService.add(
        '[ExoPlayer] c.initialize() 成功! duration=${c.value.duration}, size=${c.value.size}, isInitialized=${c.value.isInitialized}',
      );
    } catch (e, stack) {
      if (_disposed || myGen != _openGeneration) {
        await _disposeController(c);
        return;
      }
      DiaryService.add('[ExoPlayer] 首次 initialize 失败: $e');
      if (!(decoder != null && isDecoderCompatibilityError(e.toString())) &&
          !formatKnown &&
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        final alternateFormat = formatHint == VideoFormat.hls
            ? null
            : VideoFormat.hls;
        DiaryService.add(
          '[ExoPlayer] 启动自愈重试，切换格式为 formatHint=$alternateFormat...',
        );
        try {
          await _disposeController(c);
        } catch (_) {}

        final retryHeaders = Map<String, String>.from(headers);
        if (alternateFormat == VideoFormat.hls) {
          retryHeaders['Accept'] =
              'application/vnd.apple.mpegurl,application/x-mpegURL,*/*';
        }
        c = VideoPlayerController.networkUrl(
          uri,
          viewType: viewType,
          formatHint: alternateFormat,
          httpHeaders: retryHeaders,
          videoPlayerOptions: options,
        );
        try {
          await c.initialize().timeout(initializationTimeout);
          formatHint = alternateFormat;
          DiaryService.add('[ExoPlayer] 自愈重试成功! duration=${c.value.duration}');
        } catch (retryErr, retryStack) {
          DiaryService.add(
            '[ExoPlayer] 自愈重试依然失败! 异常: $retryErr\n堆栈: $retryStack',
          );
          if (myGen == _openGeneration) {
            _safeAdd(stream.errorController, retryErr.toString());
          }
          try {
            await _disposeController(c);
          } catch (_) {}
          rethrow;
        }
      } else {
        DiaryService.add('[ExoPlayer] c.initialize() 失败! 异常: $e\n堆栈: $stack');
        if (myGen == _openGeneration) {
          _safeAdd(stream.errorController, e.toString());
        }
        try {
          await _disposeController(c);
        } catch (_) {}
        rethrow;
      }
    }

    if (_disposed || myGen != _openGeneration) {
      try {
        await _disposeController(c);
      } catch (_) {}
      return;
    }

    _controller = c;
    _lastControllerError = null;
    _startDiagnostics();
    final dur = c.value.duration;
    final w = c.value.size.width.round();
    final h = c.value.size.height.round();
    final videoParams = VideoParams(w: w, h: h, dw: w, dh: h);

    state = state.copyWith(
      duration: dur,
      position: Duration.zero,
      playing: play,
      buffering: c.value.isBuffering,
      width: w > 0 ? w : 1920,
      height: h > 0 ? h : 1080,
      videoParams: videoParams,
    );

    _safeAdd(stream.durationController, dur);
    _safeAdd(stream.positionController, Duration.zero);
    _safeAdd(stream.playingController, play);
    _safeAdd(stream.bufferingController, c.value.isBuffering);
    _safeAdd(stream.videoParamsController, videoParams);

    _valueListener = () => _onControllerValue(c);
    c.addListener(_valueListener!);
    revision.value++;

    // 定时轮询真实播放位置 (与 LunaTV-Mobile 对齐)
    _startPositionPolling();

    if (media.start != null && media.start! > Duration.zero) {
      try {
        await c.seekTo(media.start!).timeout(const Duration(seconds: 3));
        if (_disposed || myGen != _openGeneration) return;
        state = state.copyWith(position: media.start!);
        _safeAdd(stream.positionController, media.start!);
      } catch (_) {}
    }

    if (_disposed || myGen != _openGeneration) return;
    if (play) {
      try {
        await c.play().timeout(const Duration(seconds: 3));
      } catch (error) {
        _reportControllerError(c, error.toString());
        rethrow;
      }
    }
  }

  void _startDiagnostics() {
    _nativeDiagnosticUnavailable = false;
    _diagnosticReportedAt = 0;
    _bufferingMs = _bufferingCount = _uiFrames = _uiOverBudget = 0;
    _buildPeakUs = _rasterPeakUs = 0;
    _bufferStartedAt = null;
    final displays = SchedulerBinding.instance.platformDispatcher.displays;
    final refreshRate = displays.isEmpty ? 60.0 : displays.first.refreshRate;
    _frameBudgetUs = 1000000 / (refreshRate > 0 ? refreshRate : 60);
    _diagnosticClock
      ..reset()
      ..start();
    _recordBuffering(_controller?.value.isBuffering ?? false);
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
    _diagnosticTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _reportDiagnostics(),
    );
    _nativeStartupTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(reportNativeDiagnostics()),
    );
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    if (!_diagnosticClock.isRunning ||
        !(_controller?.value.isPlaying ?? false)) {
      return;
    }
    for (final frame in timings) {
      final build = frame.buildDuration.inMicroseconds;
      final raster = frame.rasterDuration.inMicroseconds;
      _uiFrames++;
      if (build > _frameBudgetUs || raster > _frameBudgetUs) _uiOverBudget++;
      if (build > _buildPeakUs) _buildPeakUs = build;
      if (raster > _rasterPeakUs) _rasterPeakUs = raster;
    }
  }

  void _recordBuffering(bool buffering) {
    if (!_diagnosticClock.isRunning) return;
    if (buffering && _bufferStartedAt == null) {
      _bufferStartedAt = _diagnosticClock.elapsedMilliseconds;
      _bufferingCount++;
    } else if (!buffering && _bufferStartedAt != null) {
      _bufferingMs += _diagnosticClock.elapsedMilliseconds - _bufferStartedAt!;
      _bufferStartedAt = null;
    }
  }

  void _reportDiagnostics() {
    final value = _controller?.value;
    if (value == null || !_diagnosticClock.isRunning) return;
    final elapsed = _diagnosticClock.elapsedMilliseconds;
    if (_bufferStartedAt != null) {
      _bufferingMs += elapsed - _bufferStartedAt!;
      _bufferStartedAt = elapsed;
    }
    final buffered = value.buffered.isEmpty
        ? Duration.zero
        : value.buffered.last.end;
    final ahead = (buffered - value.position).inMilliseconds.clamp(0, 86400000);
    DiaryService.add(
      '[PlayStats] intervalMs=${elapsed - _diagnosticReportedAt}, size=${value.size.width.round()}x${value.size.height.round()}, rate=${value.playbackSpeed}, playing=${value.isPlaying}, buffering=${value.isBuffering}, bufferedAheadMs=$ahead, bufferingCount=$_bufferingCount, bufferingMs=$_bufferingMs, uiFrames=$_uiFrames, uiOverBudget=$_uiOverBudget, buildPeakMs=${(_buildPeakUs / 1000).toStringAsFixed(1)}, rasterPeakMs=${(_rasterPeakUs / 1000).toStringAsFixed(1)}, uiBudgetMs=${(_frameBudgetUs / 1000).toStringAsFixed(1)}',
    );
    unawaited(reportNativeDiagnostics());
    _diagnosticReportedAt = elapsed;
    _bufferingMs = _bufferingCount = _uiFrames = _uiOverBudget = 0;
    _buildPeakUs = _rasterPeakUs = 0;
  }

  Future<void> reportNativeDiagnostics({bool log = true}) async {
    final c = _controller;
    if (c == null ||
        _transitioning ||
        _nativeDiagnosticUnavailable ||
        _nativeSnapshotPending) {
      return;
    }
    final generation = _openGeneration;
    _nativeSnapshotPending = true;
    try {
      final values = await diagnosticChannel
          .invokeMapMethod<String, dynamic>('snapshot', {
            'playerId': c.playerId,
          })
          .timeout(const Duration(seconds: 2));
      if (_disposed || generation != _openGeneration || _controller != c) {
        return;
      }
      final durationMs = values?['durationMs'];
      if (!_transitioning &&
          c.value.duration <= Duration.zero &&
          durationMs is num &&
          durationMs.isFinite &&
          durationMs > 0) {
        c.value = c.value.copyWith(
          duration: Duration(milliseconds: durationMs.toInt()),
        );
      }
      if (values != null && log) {
        DiaryService.add(
          '[VideoStats] ${values.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
        );
      }
    } on MissingPluginException {
      if (generation == _openGeneration) _nativeDiagnosticUnavailable = true;
    } catch (e) {
      if (log &&
          !_disposed &&
          generation == _openGeneration &&
          _controller == c) {
        DiaryService.add('[VideoStats] snapshot unavailable: $e');
      }
    } finally {
      _nativeSnapshotPending = false;
    }
  }

  void _stopDiagnostics() {
    _diagnosticTimer?.cancel();
    _nativeStartupTimer?.cancel();
    if (_diagnosticClock.isRunning) {
      _reportDiagnostics();
      _diagnosticClock.stop();
      SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
    }
  }

  void _startPositionPolling() {
    _positionPollTimer?.cancel();
    _durationRefreshTicks = 0;
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      if (!_transitioning && c.value.duration <= Duration.zero) {
        if (++_durationRefreshTicks >= 4) {
          _durationRefreshTicks = 0;
          unawaited(reportNativeDiagnostics(log: false));
        }
      }
      final pos = c.value.position;
      if (pos != state.position) {
        state = state.copyWith(position: pos);
        _safeAdd(stream.positionController, pos);
      }
    });
  }

  void _onControllerValue(VideoPlayerController c) {
    if (_disposed || _controller != c || _transitioning) return;
    final v = c.value;

    bool stateChanged = false;
    if (v.isPlaying != state.playing) {
      DiaryService.add('[ExoPlayer] isPlaying 变为: ${v.isPlaying}');
      state = state.copyWith(playing: v.isPlaying);
      _safeAdd(stream.playingController, v.isPlaying);
      stateChanged = true;
    }
    if (v.isBuffering != state.buffering) {
      _recordBuffering(v.isBuffering);
      DiaryService.add('[ExoPlayer] isBuffering 变为: ${v.isBuffering}');
      state = state.copyWith(buffering: v.isBuffering);
      _safeAdd(stream.bufferingController, v.isBuffering);
      stateChanged = true;
    }
    if (v.hasError) {
      _reportControllerError(c, v.errorDescription ?? '播放器发生未知错误');
    }
    final dur = v.duration;
    if (dur > Duration.zero && dur != state.duration) {
      state = state.copyWith(duration: dur);
      _safeAdd(stream.durationController, dur);
      stateChanged = true;
    }
    final pos = v.position;
    if (pos != state.position) {
      state = state.copyWith(position: pos);
      _safeAdd(stream.positionController, pos);
    }
    if (v.buffered.isNotEmpty) {
      final lastRange = v.buffered.last;
      if (lastRange.end != state.buffer) {
        state = state.copyWith(buffer: lastRange.end);
        _safeAdd(stream.bufferController, state.buffer);
      }
    }
    if (v.isCompleted != state.completed) {
      state = state.copyWith(completed: v.isCompleted);
      _safeAdd(stream.completedController, v.isCompleted);
      stateChanged = true;
    }

    if (stateChanged) {
      revision.value++;
    }
  }

  void _reportControllerError(VideoPlayerController c, String error) {
    if (_disposed || _controller != c || error == _lastControllerError) return;
    _lastControllerError = error;
    DiaryService.add('[ExoPlayer] controller error: $error');
    _safeAdd(stream.errorController, error);
  }

  Future<void> _disposeController(VideoPlayerController controller) async {
    try {
      await controller.dispose().timeout(const Duration(seconds: 2));
    } catch (error) {
      DiaryService.add('[ExoPlayer] release incomplete: $error');
    }
  }

  Future<void> _releaseController() async {
    clearRetainedFrame();
    ++_prepareGeneration;
    _preparedIdentity = _preparedUrl = _preparedMediaType = null;
    _preparedHeaders = null;
    _preparingNext = null;
    _prepareRetryAt = DateTime(2000);
    _transitioning = false;
    _positionPollTimer?.cancel();
    _stopDiagnostics();
    final c = _controller;
    final listener = _valueListener;
    _controller = null;
    _valueListener = null;
    _lastControllerError = null;
    if (c == null) return;
    if (listener != null) c.removeListener(listener);
    revision.value++;
    await _disposeController(c);
  }

  @override
  Future<void> play() async {
    if (_transitioning) {
      _transitionWantsPlay = true;
      return;
    }
    final c = _controller;
    if (c == null) return;
    try {
      await c.play().timeout(const Duration(seconds: 3));
    } catch (error) {
      _reportControllerError(c, error.toString());
    }
  }

  @override
  Future<void> pause() async {
    clearRetainedFrame();
    if (_transitioning) {
      _transitionWantsPlay = false;
      return;
    }
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
    } catch (_) {}
  }

  @override
  Future<void> playOrPause() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration target) async {
    clearRetainedFrame();
    final c = _controller;
    if (c == null) return;
    try {
      await c.seekTo(target);
      state = state.copyWith(position: target);
      _safeAdd(stream.positionController, target);
      if (state.completed) {
        state = state.copyWith(completed: false);
        _safeAdd(stream.completedController, false);
      }
    } catch (_) {}
  }

  @override
  Future<void> setRate(double rate) async {
    final r = rate.clamp(0.25, 4.0);
    state = state.copyWith(rate: r);
    _safeAdd(stream.rateController, r);
    final c = _controller;
    if (c == null) return;
    try {
      await c.setPlaybackSpeed(r).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 100.0);
    state = state.copyWith(volume: v);
    _safeAdd(stream.volumeController, v);
    final c = _controller;
    if (c == null) return;
    try {
      await c.setVolume(v / 100.0);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    final ticket = ++_openGeneration;
    await _releaseController();
    if (_disposed || ticket != _openGeneration) return;
    state = state.copyWith(
      playing: false,
      buffering: false,
      completed: false,
      position: Duration.zero,
      duration: Duration.zero,
      buffer: Duration.zero,
    );
    _safeAdd(stream.playingController, false);
    _safeAdd(stream.bufferingController, false);
    _safeAdd(stream.completedController, false);
    _safeAdd(stream.positionController, Duration.zero);
    _safeAdd(stream.durationController, Duration.zero);
    _safeAdd(stream.bufferController, Duration.zero);
    revision.value++;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    ++_openGeneration;
    await _releaseController();
    frameHold.dispose();
    frameHoldFailure.dispose();
    stream.dispose();
  }

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) return null;
    if (invocation.isMethod) return Future<void>.value();
    return null;
  }
}

/// 采用和 LunaTV-Mobile 完全相同架构的 ExoPlayer 视图组件
class LunaExoVideoView extends StatelessWidget {
  const LunaExoVideoView({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.controls,
  });

  final LunaExoPlayer player;
  final BoxFit fit;
  final Widget Function(BuildContext)? controls;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player.revision,
      builder: (context, _) {
        final c = player.controller;
        final hasVideo = c != null && c.value.isInitialized;
        final rawRatio = hasVideo ? c.value.aspectRatio : 16 / 9;
        final ratio = (rawRatio > 0 && !rawRatio.isNaN && !rawRatio.isInfinite)
            ? rawRatio
            : 16 / 9;

        return Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo)
              Center(
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: VideoPlayer(c, key: ValueKey(c)),
                ),
              )
            else
              const ColoredBox(color: Colors.black),
            if (controls != null) controls!(context),
          ],
        );
      },
    );
  }
}
