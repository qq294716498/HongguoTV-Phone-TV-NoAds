part of 'player_screen.dart';

class _QueueTarget {
  const _QueueTarget(
    this.detail,
    this.index,
    this.generation,
    this.quality,
    this.online,
  );
  final DramaDetail detail;
  final int index;
  final int generation;
  final int quality;
  final bool online;
}

class _QueuedEpisode {
  _QueuedEpisode(
    this.target,
    this.plan,
    this.identity,
    this.generation,
    this.previousDetail,
    this.previousIndex,
    this.previousPosition,
    this.previousDuration,
  );

  final _QueueTarget target;
  PlaybackPlan plan;
  final String identity;
  final int generation;
  final DramaDetail previousDetail;
  final int previousIndex;
  Duration previousPosition;
  Duration previousDuration;
  Duration previousBufferedEnd = Duration.zero;
  PlaybackPlan? previousPlan;
  PlaybackPreloadLease? lease;
  final selected = Completer<bool>();
  final ready = Completer<bool>();
  final positionReset = Completer<bool>();
  final finished = Completer<bool>();
  bool valid = true;
  bool armed = false;
  bool frozen = false;
  bool activated = false;
  bool previousReleased = false;
  bool fallingBack = false;
  bool fallbackClaimed = false;
  Future<bool>? advancing;

  void finish(Completer<bool> signal, bool value) {
    if (!signal.isCompleted) signal.complete(value);
  }

  void cancel() {
    valid = false;
    finish(selected, false);
    finish(ready, false);
    finish(positionReset, false);
    finish(finished, false);
  }
}
