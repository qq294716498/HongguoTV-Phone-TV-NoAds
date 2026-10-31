import 'models.dart';

enum PlaybackQueueEventKind { activated, ready, failed }

class PlaybackQueueEvent {
  const PlaybackQueueEvent({
    required this.identity,
    required this.generation,
    required this.kind,
    this.firstFrame = false,
    this.message = '',
  });

  final String identity;
  final int generation;
  final PlaybackQueueEventKind kind;
  final bool firstFrame;
  final String message;
}

abstract class PlaybackQueueDriver {
  Stream<PlaybackQueueEvent> get events;

  Future<bool> stage({
    required PlaybackPlan current,
    required PlaybackPlan next,
    required String identity,
    required int generation,
  });

  Future<bool> advance({required String identity, required bool play});

  Future<void> suspend(bool paused);

  Future<void> clear({String? identity});

  Future<void> dispose();
}
