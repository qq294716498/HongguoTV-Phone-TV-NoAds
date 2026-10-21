import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'diary_service.dart';

class _PreloadRequest {
  final result = Completer<PlaybackPlan?>();
  bool claimed = false;
}

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(
    this.repository, {
    DateTime Function()? now,
    this.onPrepared,
    this.onRelease,
  }) : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final void Function(PlaybackPlan)? onPrepared;
  final Future<void> Function(PlaybackPlan)? onRelease;
  PlaybackPlan? _ready;
  _PreloadRequest? _pending;
  String? _identity;
  Timer? _delay;
  Timer? _poll;
  DateTime _expires = DateTime(2000), _retryAt = DateTime(2000);
  int _generation = 0;
  bool _closed = false, loading = false;
  bool _sourceBlocked = false;
  String error = '';
  void _release(PlaybackPlan plan) => unawaited(_releasePlan(plan));

  Future<void> _releasePlan(PlaybackPlan plan) async {
    try {
      await onRelease?.call(plan);
    } catch (_) {}
    try {
      await repository.release(plan.session);
    } catch (_) {}
  }

  void _prepareMedia(PlaybackPlan plan) {
    if (plan.local || plan.startupReady || plan.preloadComplete) {
      onPrepared?.call(plan);
    }
  }

  String get status {
    final plan = _ready;
    if (plan != null) {
      if (plan.local || plan.preloadComplete) return '下一集整集缓冲完成 · 已核验';
      final size = (plan.prefetchedBytes / (1024 * 1024)).toStringAsFixed(1);
      if (plan.preloadState == 'verifying') return '下一集已接收，正在核验完整性';
      if (plan.preloadState == 'retrying') return '下一集已缓冲 $size MB · 等待重试续传';
      final progress = (plan.preloadProgress * 100).floor().clamp(0, 99);
      return '下一集缓冲中 $progress% · $size MB';
    }
    if (loading || _delay != null) return '正在准备下一集';
    if (_sourceBlocked && _now().isBefore(_retryAt)) {
      final seconds = (_retryAt.difference(_now()).inMilliseconds / 1000)
          .ceil();
      return '站源请求受限，$seconds 秒后重试下一集';
    }
    return error.isNotEmpty ? '下一集缓冲失败，正在重试' : '播放稳定后持续缓冲下一集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.number}\u0000$quality\u0000$online';

  Duration _retryDelay(Object failure) {
    if (failure is AppFailure && failure.code == 'source_blocked') {
      final remaining = failure.retryAt?.difference(_now());
      if (remaining != null && remaining > const Duration(seconds: 3)) {
        return remaining;
      }
      if (remaining == null) return const Duration(seconds: 60);
    }
    return const Duration(seconds: 3);
  }

  void prepare(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    bool immediate = false,
  }) {
    if (_closed) return;
    final identity = _key(drama, episode, quality, online);
    if (_identity != identity) {
      clear();
      _identity = identity;
    }
    if (_ready != null &&
        _ready!.preloadState.isEmpty &&
        !_ready!.local &&
        !_ready!.preloadComplete &&
        !_now().isBefore(_expires)) {
      final expired = _ready!;
      _ready = null;
      _release(expired);
    }
    if (immediate && _delay != null) {
      _delay!.cancel();
      _delay = null;
    }
    if (_ready != null) {
      _prepareMedia(_ready!);
      return;
    }
    if (loading || _delay != null || _now().isBefore(_retryAt)) {
      return;
    }
    final ticket = _generation;
    _delay = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 600),
      () async {
        _delay = null;
        final pending = _PreloadRequest();
        _pending = pending;
        loading = true;
        notifyListeners();
        final clock = Stopwatch()..start();
        DiaryService.add(
          '[Preload] episode=${episode.number}, trigger=${immediate ? 'ready-to-prefetch' : 'stable-playback'}',
        );
        try {
          final plan = await repository.preload(
            drama,
            episode,
            quality: quality,
            online: online,
          );
          if (!pending.claimed && (_closed || ticket != _generation)) {
            if (plan != null) await _releasePlan(plan);
            return;
          }
          if (plan == null || plan.url.isEmpty) {
            if (plan != null) _release(plan);
            throw AppFailure('未取得预加载结果');
          }
          var expires = plan.preloadState.isNotEmpty
              ? DateTime.utc(2100)
              : _now().add(const Duration(minutes: 2));
          if (plan.expiresAt > 0) {
            final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
              plan.expiresAt,
            ).subtract(const Duration(seconds: 5));
            if (authorizationExpiry.isBefore(expires)) {
              expires = authorizationExpiry;
            }
          }
          if (!expires.isAfter(_now()) &&
              !plan.local &&
              !plan.preloadComplete &&
              (plan.preloadState.isEmpty || pending.claimed)) {
            _release(plan);
            throw AppFailure('下一集播放凭证即将过期');
          }
          if (pending.claimed) {
            DiaryService.add(
              '[Preload] 已衔接在途预取 episode=${episode.number}, elapsedMs=${clock.elapsedMilliseconds}',
            );
            pending.result.complete(plan);
            return;
          }
          _ready = plan;
          _prepareMedia(plan);
          _expires = expires;
          error = '';
          _sourceBlocked = false;
          DiaryService.add(
            '[Preload] resolved episode=${episode.number}, elapsedMs=${clock.elapsedMilliseconds}, bytes=${plan.prefetchedBytes}, complete=${plan.local || plan.preloadComplete}',
          );
          if (!plan.local && plan.session.isNotEmpty) {
            _watch(drama, episode, quality, online, ticket);
          }
        } catch (failure) {
          if (_closed || ticket != _generation) return;
          error = failure.toString();
          _sourceBlocked =
              failure is AppFailure && failure.code == 'source_blocked';
          final delay = _retryDelay(failure);
          _retryAt = _now().add(delay);
          _poll = Timer(delay, () {
            if (!_closed && ticket == _generation) {
              prepare(
                drama,
                episode,
                quality: quality,
                online: online,
                immediate: true,
              );
            }
          });
        } finally {
          if (!pending.result.isCompleted) pending.result.complete(null);
          if (identical(_pending, pending)) _pending = null;
          if (!_closed && ticket == _generation) {
            loading = false;
            notifyListeners();
          }
        }
      },
    );
    notifyListeners();
  }

  void _watch(
    Drama drama,
    Episode episode,
    int quality,
    bool online,
    int ticket,
  ) {
    _poll?.cancel();
    final delay = _ready?.startupReady == true
        ? const Duration(seconds: 1)
        : const Duration(milliseconds: 250);
    _poll = Timer(delay, () async {
      final current = _ready;
      if (_closed || ticket != _generation || current == null) return;
      try {
        final updated = await repository.preloadStatus(drama, current);
        if (_closed || ticket != _generation || !identical(current, _ready))
          return;
        if (updated.session != current.session || updated.url.isEmpty) {
          throw AppFailure('下一集缓冲会话不匹配');
        }
        _ready = updated;
        _prepareMedia(updated);
        error = updated.preloadError;
        if (updated.preloadComplete) {
          DiaryService.add(
            '[Preload] verified-complete episode=${episode.number}, bytes=${updated.prefetchedBytes}, total=${updated.preloadTotal}',
          );
        } else {
          if (updated.preloadState != current.preloadState) {
            DiaryService.add(
              '[Preload] episode=${episode.number}, state=${updated.preloadState}, bytes=${updated.prefetchedBytes}, error=${updated.preloadError}',
            );
          }
          _watch(drama, episode, quality, online, ticket);
        }
        notifyListeners();
      } catch (failure) {
        if (_closed || ticket != _generation || !identical(current, _ready))
          return;
        _ready = null;
        _release(current);
        error = failure.toString();
        _sourceBlocked =
            failure is AppFailure && failure.code == 'source_blocked';
        final delay = _retryDelay(failure);
        _retryAt = _now().add(delay);
        _poll = Timer(delay, () {
          if (!_closed && ticket == _generation) {
            prepare(
              drama,
              episode,
              quality: quality,
              online: online,
              immediate: true,
            );
          }
        });
        notifyListeners();
      }
    });
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final result =
        _identity == _key(drama, episode, quality, online) &&
            (_ready?.local == true ||
                _ready?.preloadComplete == true ||
                _now().isBefore(_expires))
        ? _ready
        : null;
    if (result != null) {
      _ready = null;
      DiaryService.add(
        '[Preload] use episode=${episode.number}, bytes=${result.prefetchedBytes}, complete=${result.local || result.preloadComplete}',
      );
    }
    clear();
    return result;
  }

  Future<PlaybackPlan?> takeWhenReady(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    final pending = _pending;
    if (_closed ||
        _identity != _key(drama, episode, quality, online) ||
        _ready != null ||
        pending == null ||
        !loading) {
      return take(drama, episode, quality: quality, online: online);
    }
    pending.claimed = true;
    _pending = null;
    loading = false;
    clear();
    var expired = false;
    return pending.result.future
        .then((plan) {
          if (plan != null && (expired || _closed)) {
            _release(plan);
            return null;
          }
          return plan;
        })
        .timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () {
            expired = true;
            DiaryService.add('[Preload] 在途预取未及时完成，转入正常取流');
            return null;
          },
        );
  }

  void pause() {
    final changed = loading || _delay != null;
    _generation++;
    _delay?.cancel();
    _delay = null;
    _poll?.cancel();
    _poll = null;
    if (loading) {
      unawaited(repository.cancelPreload().catchError((Object _) {}));
    }
    loading = false;
    _pending = null;
    if (changed && !_closed) notifyListeners();
  }

  void clear() {
    pause();
    final old = _ready;
    _ready = null;
    _identity = null;
    _retryAt = DateTime(2000);
    error = '';
    _sourceBlocked = false;
    if (old != null) _release(old);
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}
