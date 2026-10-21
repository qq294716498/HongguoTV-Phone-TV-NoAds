import 'dart:async';

import 'core_bridge.dart';
import 'models.dart';

class PlaybackLoader {
  PlaybackLoader(
    this.repository, {
    this.resolveTimeout = const Duration(seconds: 20),
    this.cancelTimeout = const Duration(seconds: 2),
  });

  final AppRepository repository;
  final Duration resolveTimeout;
  final Duration cancelTimeout;
  int _generation = 0;
  bool _closed = false;

  Future<void> cancel() {
    ++_generation;
    return repository.cancelPlayback().timeout(cancelTimeout);
  }

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool localOnly = false,
    bool online = false,
  }) => _load(() async {
    if (online) {
      return repository.resolveOnline(drama, episode, quality: quality);
    }
    if (localOnly) {
      final plan = await repository.localPlaybackForPlayer(drama, episode);
      if (plan == null || !plan.local) {
        throw AppFailure('本地视频不可用，请重新下载或选择在线播放。', code: 'local_media');
      }
      return plan;
    }
    return repository.resolve(drama, episode, quality: quality);
  });

  Future<PlaybackPlan?> fallback(PlaybackPlan current) =>
      _load(() => repository.fallback(current));

  Future<PlaybackPlan?> use(PlaybackPlan prepared) async {
    if (_closed) return null;
    ++_generation;
    unawaited(
      repository
          .cancelPlayback()
          .timeout(cancelTimeout)
          .catchError((Object _) {}),
    );
    return prepared;
  }

  Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    var expired = false;
    try {
      await repository.cancelPlayback().timeout(cancelTimeout);
      if (_closed || generation != _generation) {
        return null;
      }
      final plan = await resolve()
          .then<PlaybackPlan?>((plan) {
            if (expired || _closed || generation != _generation) {
              unawaited(
                repository.release(plan.session).catchError((Object _) {}),
              );
              return null;
            }
            return plan;
          })
          .timeout(
            resolveTimeout,
            onTimeout: () {
              expired = true;
              if (!_closed && generation == _generation) {
                unawaited(
                  repository.cancelPlayback().catchError((Object _) {}),
                );
              }
              throw AppFailure('获取播放地址超时，请重试或换一集。', code: 'resolve_timeout');
            },
          );
      if (plan == null) return null;
      if (_closed || generation != _generation) {
        await repository.release(plan.session);
        return null;
      }
      return plan;
    } catch (_) {
      if (_closed || generation != _generation) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    await cancel();
  }
}
