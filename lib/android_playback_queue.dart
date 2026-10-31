import 'luna_exo_player.dart';
import 'models.dart';
import 'playback_queue_contract.dart';

class AndroidPlaybackQueueDriver implements PlaybackQueueDriver {
  AndroidPlaybackQueueDriver(this.player);

  final LunaExoPlayer player;
  bool _disposed = false;

  @override
  Stream<PlaybackQueueEvent> get events => player.queueEvents;

  static bool supports(PlaybackPlan plan) {
    if ((!plan.local && !plan.preloadComplete) ||
        plan.decryptionKey.isNotEmpty) {
      return false;
    }
    final uri = Uri.tryParse(plan.url);
    if (uri == null) return false;
    if (uri.scheme == 'file' ||
        uri.scheme.isEmpty && plan.url.startsWith('/')) {
      return true;
    }
    return uri.scheme == 'http' &&
        {'127.0.0.1', '::1', 'localhost'}.contains(uri.host);
  }

  @override
  Future<bool> stage({
    required PlaybackPlan current,
    required PlaybackPlan next,
    required String identity,
    required int generation,
  }) {
    if (_disposed || !supports(next)) return Future.value(false);
    return player.stageQueue(
      current: current,
      next: next,
      identity: identity,
      generation: generation,
    );
  }

  @override
  Future<bool> advance({required String identity, required bool play}) =>
      _disposed
      ? Future.value(false)
      : player.advanceQueue(identity: identity, play: play);

  @override
  Future<void> clear({String? identity}) =>
      player.clearQueue(identity: identity);

  @override
  Future<void> suspend(bool paused) => player.suspendQueue(paused);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await clear();
  }
}
