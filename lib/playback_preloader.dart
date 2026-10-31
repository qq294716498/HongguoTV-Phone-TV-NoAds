import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'diary_service.dart';

class _PreloadTarget {
  const _PreloadTarget(this.drama, this.episode, this.quality, this.online);

  final Drama drama;
  final Episode episode;
  final int quality;
  final bool online;
}

class _PreloadRequest {
  final result = Completer<_PreloadEntry?>();
  bool claimed = false;
}

class PlaybackPreloadLease {
  const PlaybackPreloadLease._(this.plan, this.resumed);

  final PlaybackPlan plan;
  final Future<void> resumed;
}

class _PreloadEntry {
  _PreloadEntry(this.target, this.plan, this.expires)
    : paused = plan.preloadState == 'paused';

  final _PreloadTarget target;
  PlaybackPlan plan;
  final DateTime expires;
  bool paused;
  bool released = false;
  bool claimed = false;
  bool externallyOwned = false;
  bool polling = false;
  DateTime controlRetryAt = DateTime(2000);
  Object? controlFailure;
  bool? failedPause;
  int controls = 0;
  bool? requestedPause;
  Future<void>? requestedControl;
  Future<void> controlTail = Future<void>.value();
}

class _PreloadObsolete implements Exception {
  @override
  String toString() => '预加载已取消';
}

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(
    this.repository, {
    DateTime Function()? now,
    this.onPrepared,
    this.onRelease,
    this.onSuspended,
  }) : _now = now ?? DateTime.now;

  static const _controlTimeout = Duration(seconds: 2);
  static const _handoffTimeout = Duration(milliseconds: 1200);
  final AppRepository repository;
  final DateTime Function() _now;
  final void Function(PlaybackPlan)? onPrepared;
  final Future<void> Function(PlaybackPlan)? onRelease;
  final Future<void> Function(bool)? onSuspended;
  _PreloadEntry? _entry;
  final _claims = <_PreloadEntry>{};
  _PreloadRequest? _pending;
  _PreloadTarget? _target;
  String? _identity;
  Timer? _delay;
  Timer? _poll;
  DateTime _retryAt = DateTime(2000);
  int _generation = 0;
  bool _closed = false, loading = false;
  bool _sourceBlocked = false;
  bool _suspended = false;
  bool _platformPaused = false;
  DateTime _platformRetryAt = DateTime(2000);
  Object? _platformFailure;
  bool? _failedPlatformPause;
  int _platformControls = 0;
  bool? _requestedPlatformPause;
  Future<void>? _requestedPlatformControl;
  Future<void> _platformControlTail = Future<void>.value();
  String error = '';

  bool get suspended => _suspended;
  bool get hasReady => readyPlan != null;
  PlaybackPlan? get readyPlan {
    final entry = _entry;
    return entry != null && !entry.released && _usable(entry)
        ? entry.plan
        : null;
  }

  bool _usable(_PreloadEntry entry) =>
      entry.plan.local ||
      entry.plan.preloadComplete ||
      _now().isBefore(entry.expires);

  void _release(_PreloadEntry entry) => unawaited(_releaseEntry(entry));

  Future<void> _releaseEntry(_PreloadEntry entry) async {
    if (entry.released || entry.externallyOwned) return;
    entry.released = true;
    try {
      await onRelease?.call(entry.plan).timeout(_controlTimeout);
    } catch (_) {}
    try {
      await repository.release(entry.plan.session).timeout(_controlTimeout);
    } catch (_) {}
  }

  bool _owned(_PreloadEntry entry) =>
      !entry.released &&
      !_closed &&
      (identical(_entry, entry) || entry.claimed);

  Future<void> _controlEntry(_PreloadEntry entry, bool paused) {
    if (!_owned(entry)) return Future<void>.error(_PreloadObsolete());
    if (entry.controls == 0 && entry.paused == paused) {
      return Future<void>.value();
    }
    if (entry.requestedPause == paused && entry.requestedControl != null) {
      return entry.requestedControl!.timeout(_controlTimeout);
    }
    entry.controls++;
    entry.requestedPause = paused;
    final operation = entry.controlTail.then((_) async {
      if (!_owned(entry)) throw _PreloadObsolete();
      if (paused && entry.externallyOwned) return;
      if (entry.paused != paused) {
        if (entry.failedPause == paused &&
            _now().isBefore(entry.controlRetryAt)) {
          throw entry.controlFailure!;
        }
        final plan = entry.plan;
        if (!plan.local &&
            !plan.preloadComplete &&
            plan.session.isNotEmpty &&
            plan.preloadState.isNotEmpty) {
          try {
            await repository.setPreloadPaused(entry.target.drama, plan, paused);
            entry.failedPause = null;
            entry.controlFailure = null;
          } catch (failure) {
            entry.failedPause = paused;
            entry.controlFailure = failure;
            entry.controlRetryAt = _now().add(_retryDelay(failure));
            rethrow;
          }
        }
        if (!_owned(entry)) throw _PreloadObsolete();
        entry.paused = paused;
      }
    });
    entry.requestedControl = operation;
    entry.controlTail = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          entry.controls--;
          if (identical(entry.requestedControl, operation)) {
            entry.requestedControl = null;
            entry.requestedPause = null;
          }
        });
    return operation.timeout(_controlTimeout);
  }

  Future<void> _controlPlatform(bool paused) {
    if (onSuspended == null) {
      _platformPaused = paused;
      return Future<void>.value();
    }
    if (_platformControls == 0 && _platformPaused == paused) {
      return Future<void>.value();
    }
    if (_requestedPlatformPause == paused &&
        _requestedPlatformControl != null) {
      return _requestedPlatformControl!.timeout(_controlTimeout);
    }
    _platformControls++;
    _requestedPlatformPause = paused;
    final operation = _platformControlTail.then((_) async {
      if (_closed) throw _PreloadObsolete();
      if (_platformPaused != paused) {
        if (_failedPlatformPause == paused &&
            _now().isBefore(_platformRetryAt)) {
          throw _platformFailure!;
        }
        try {
          await onSuspended!(paused);
          _failedPlatformPause = null;
          _platformFailure = null;
        } catch (failure) {
          _failedPlatformPause = paused;
          _platformFailure = failure;
          _platformRetryAt = _now().add(_retryDelay(failure));
          rethrow;
        }
        if (_closed) throw _PreloadObsolete();
        _platformPaused = paused;
      }
    });
    _requestedPlatformControl = operation;
    _platformControlTail = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _platformControls--;
          if (identical(_requestedPlatformControl, operation)) {
            _requestedPlatformControl = null;
            _requestedPlatformPause = null;
          }
        });
    return operation.timeout(_controlTimeout);
  }

  Future<void> setSuspended(bool paused) async {
    if (_closed) return;
    final changed = _suspended != paused;
    _suspended = paused;
    if (paused) {
      _delay?.cancel();
      _delay = null;
      _poll?.cancel();
      _poll = null;
    }
    if (changed) notifyListeners();
    final entry = _entry;
    try {
      await Future.wait<void>([
        _controlPlatform(paused),
        if (entry != null) _controlEntry(entry, paused),
      ]);
      if (!_closed && _suspended == paused && !paused) _resumeTarget();
    } on _PreloadObsolete {
      return;
    } catch (failure) {
      if (!_closed && _suspended == paused) {
        error = failure.toString();
        if (paused && entry != null && identical(_entry, entry)) {
          _entry = null;
          _release(entry);
        }
        notifyListeners();
      }
      rethrow;
    }
  }

  void _resumeTarget() {
    final target = _target;
    if (_closed || _suspended || target == null) return;
    prepare(
      target.drama,
      target.episode,
      quality: target.quality,
      online: target.online,
      immediate: true,
    );
  }

  void _prepareMedia(_PreloadEntry entry) {
    if (!_owned(entry) ||
        entry.claimed ||
        _suspended ||
        _platformControls > 0 ||
        _platformPaused ||
        entry.controls > 0 ||
        entry.paused ||
        !_usable(entry)) {
      return;
    }
    final plan = entry.plan;
    if (plan.local || plan.startupReady || plan.preloadComplete) {
      onPrepared?.call(plan);
    }
  }

  String get status {
    if (_suspended) return '优先当前播放，下一集预取已暂停';
    final plan = _entry?.plan;
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
      '${drama.source}\u0000${drama.sourceId}\u0000${drama.id}\u0000${episode.number}\u0000$quality\u0000$online';

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

  void _scheduleRetry(int ticket) {
    if (_closed || _suspended || ticket != _generation || _poll != null) return;
    final remaining = _retryAt.difference(_now());
    _poll = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _poll = null;
      if (!_closed && ticket == _generation) _resumeTarget();
    });
  }

  DateTime _expiry(PlaybackPlan plan) {
    var expires = plan.preloadState.isNotEmpty
        ? DateTime.utc(2100)
        : _now().add(const Duration(minutes: 2));
    if (plan.expiresAt > 0) {
      final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
        plan.expiresAt,
      ).subtract(const Duration(seconds: 5));
      if (authorizationExpiry.isBefore(expires)) expires = authorizationExpiry;
    }
    return expires;
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
    _target = _PreloadTarget(drama, episode, quality, online);
    final current = _entry;
    if (current != null &&
        current.plan.preloadState.isEmpty &&
        !_usable(current)) {
      _entry = null;
      _release(current);
    }
    if (_suspended) return;
    if (immediate && _delay != null) {
      _delay!.cancel();
      _delay = null;
    }
    final ready = _entry;
    if (ready != null) {
      _prepareMedia(ready);
      _watch(ready, _generation);
      return;
    }
    if (loading || _delay != null) return;
    if (_now().isBefore(_retryAt)) {
      _scheduleRetry(_generation);
      return;
    }
    final ticket = _generation;
    final target = _target!;
    _delay = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 600),
      () async {
        _delay = null;
        if (_closed || _suspended || ticket != _generation) return;
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
          final entry = plan == null
              ? null
              : _PreloadEntry(target, plan, _expiry(plan));
          if (!pending.claimed && (_closed || ticket != _generation)) {
            if (entry != null) await _releaseEntry(entry);
            return;
          }
          if (entry == null || entry.plan.url.isEmpty) {
            if (entry != null) _release(entry);
            throw AppFailure('未取得预加载结果');
          }
          if (!_usable(entry) &&
              (entry.plan.preloadState.isEmpty || pending.claimed)) {
            _release(entry);
            throw AppFailure('下一集播放凭证即将过期');
          }
          if (pending.claimed) {
            DiaryService.add(
              '[Preload] 已衔接在途预取 episode=${episode.number}, elapsedMs=${clock.elapsedMilliseconds}',
            );
            pending.result.complete(entry);
            return;
          }
          _entry = entry;
          if (_suspended) {
            await _controlEntry(entry, true);
            if (!_owned(entry) || ticket != _generation) return;
          }
          _prepareMedia(entry);
          if (ticket != _generation || !identical(_entry, entry)) return;
          error = '';
          _sourceBlocked = false;
          DiaryService.add(
            '[Preload] resolved episode=${episode.number}, elapsedMs=${clock.elapsedMilliseconds}, bytes=${plan!.prefetchedBytes}, complete=${plan.local || plan.preloadComplete}',
          );
          if (identical(_entry, entry)) _watch(entry, ticket);
        } catch (failure) {
          if (_closed || ticket != _generation) return;
          final entry = _entry;
          if (_suspended && entry != null) {
            _entry = null;
            _release(entry);
          }
          error = failure.toString();
          _sourceBlocked =
              failure is AppFailure && failure.code == 'source_blocked';
          _retryAt = _now().add(_retryDelay(failure));
          _scheduleRetry(ticket);
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

  void _watch(_PreloadEntry entry, int ticket) {
    if (_closed ||
        _suspended ||
        ticket != _generation ||
        !identical(_entry, entry) ||
        entry.released ||
        entry.polling ||
        _poll != null ||
        entry.plan.local ||
        entry.plan.preloadComplete ||
        entry.plan.session.isEmpty) {
      return;
    }
    final delay = entry.plan.startupReady
        ? const Duration(seconds: 1)
        : const Duration(milliseconds: 250);
    _poll = Timer(delay, () async {
      _poll = null;
      if (_closed ||
          _suspended ||
          ticket != _generation ||
          !identical(_entry, entry)) {
        return;
      }
      entry.polling = true;
      try {
        final updated = await repository.preloadStatus(
          entry.target.drama,
          entry.plan,
        );
        if (_closed ||
            _suspended ||
            ticket != _generation ||
            !identical(_entry, entry)) {
          return;
        }
        if (updated.session != entry.plan.session || updated.url.isEmpty) {
          throw AppFailure('下一集缓冲会话不匹配');
        }
        final previous = entry.plan;
        entry.plan = updated;
        _prepareMedia(entry);
        if (ticket != _generation || !identical(_entry, entry)) return;
        error = updated.preloadError;
        if (updated.preloadComplete) {
          DiaryService.add(
            '[Preload] verified-complete episode=${entry.target.episode.number}, bytes=${updated.prefetchedBytes}, total=${updated.preloadTotal}',
          );
        } else if (updated.preloadState != previous.preloadState) {
          DiaryService.add(
            '[Preload] episode=${entry.target.episode.number}, state=${updated.preloadState}, bytes=${updated.prefetchedBytes}, error=${updated.preloadError}',
          );
        }
        notifyListeners();
      } catch (failure) {
        if (_closed ||
            _suspended ||
            ticket != _generation ||
            !identical(_entry, entry)) {
          return;
        }
        _entry = null;
        _release(entry);
        error = failure.toString();
        _sourceBlocked =
            failure is AppFailure && failure.code == 'source_blocked';
        _retryAt = _now().add(_retryDelay(failure));
        _scheduleRetry(ticket);
        notifyListeners();
      } finally {
        entry.polling = false;
        _watch(entry, ticket);
      }
    });
  }

  void _detach() {
    pause();
    _target = null;
    _identity = null;
    _retryAt = DateTime(2000);
    error = '';
    _sourceBlocked = false;
    if (!_closed) notifyListeners();
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final entry = _entry;
    if (_suspended ||
        _platformPaused ||
        (entry?.paused ?? false) ||
        (entry?.controls ?? 0) > 0 ||
        _platformControls > 0) {
      return null;
    }
    final result =
        _identity == _key(drama, episode, quality, online) &&
            entry != null &&
            !entry.released &&
            !entry.paused &&
            _usable(entry)
        ? entry
        : null;
    if (result != null) {
      _entry = null;
      result.claimed = true;
      _detach();
      DiaryService.add(
        '[Preload] use episode=${episode.number}, bytes=${result.plan.prefetchedBytes}, complete=${result.plan.local || result.plan.preloadComplete}',
      );
      return result.plan;
    }
    clear();
    return null;
  }

  PlaybackPreloadLease? claimActivated(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final entry = _entry;
    if (_closed ||
        entry == null ||
        entry.released ||
        _identity != _key(drama, episode, quality, online) ||
        !(entry.plan.local || entry.plan.preloadComplete)) {
      return null;
    }
    _entry = null;
    entry.claimed = true;
    entry.externallyOwned = true;
    _claims.remove(entry);
    if (_suspended) {
      _suspended = false;
      notifyListeners();
    }
    _detach();
    final resumed = Future.wait<void>([
      _controlEntry(entry, false),
      _controlPlatform(false),
    ]).then<void>((_) {});
    unawaited(
      resumed.then<void>(
        (_) {},
        onError: (Object failure, StackTrace _) {
          DiaryService.add('[Preload] 已激活预取的恢复确认失败，等待播放方回退：$failure');
        },
      ),
    );
    return PlaybackPreloadLease._(entry.plan, resumed);
  }

  Future<PlaybackPlan?> _claim(_PreloadEntry entry) async {
    try {
      if (_closed || entry.released) throw _PreloadObsolete();
      if (!_usable(entry) && entry.plan.preloadState.isNotEmpty) {
        final updated = await repository.preloadStatus(
          entry.target.drama,
          entry.plan,
        );
        if (_closed ||
            entry.released ||
            updated.session != entry.plan.session ||
            updated.url.isEmpty) {
          throw _PreloadObsolete();
        }
        entry.plan = updated;
      }
      if (!_usable(entry)) throw AppFailure('下一集播放凭证即将过期');
      await Future.wait<void>([
        _controlEntry(entry, false),
        _controlPlatform(false),
      ]);
      if (_closed || entry.released) throw _PreloadObsolete();
      return entry.plan;
    } catch (failure) {
      _release(entry);
      DiaryService.add('[Preload] 预取交接不可用，转入正常取流：$failure');
      return null;
    } finally {
      _claims.remove(entry);
    }
  }

  Future<PlaybackPlan?> takeWhenReady(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    if (_closed || _identity != _key(drama, episode, quality, online)) {
      return take(drama, episode, quality: quality, online: online);
    }
    final entry = _entry;
    final pending = _pending;
    if (entry == null && (pending == null || !loading)) {
      return take(drama, episode, quality: quality, online: online);
    }
    if (_suspended) {
      _suspended = false;
      notifyListeners();
    }
    _entry = null;
    if (entry != null) {
      entry.claimed = true;
      _claims.add(entry);
    }
    if (entry == null) pending!.claimed = true;
    _pending = null;
    loading = false;
    _detach();
    var expired = false;
    _PreloadEntry? claimed = entry;
    final result =
        (entry != null
                ? Future<_PreloadEntry?>.value(entry)
                : pending!.result.future)
            .then((candidate) async {
              claimed = candidate;
              if (candidate == null) return null;
              candidate.claimed = true;
              if (expired || _closed) {
                _release(candidate);
                return null;
              }
              return _claim(candidate);
            });
    return result.timeout(
      _handoffTimeout,
      onTimeout: () {
        expired = true;
        final candidate = claimed;
        if (candidate != null) _release(candidate);
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
    final old = _entry;
    _entry = null;
    _detach();
    if (old != null) _release(old);
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    for (final entry in _claims.toList()) {
      _release(entry);
    }
    _claims.clear();
    super.dispose();
  }
}
