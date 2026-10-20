import 'dart:async';

import 'core_bridge.dart';

class PlaybackAttemptCancelled implements Exception {}

class PlaybackAttempt {
  PlaybackAttempt({
    this.deadline,
    void Function()? onTimeout,
    DateTime Function()? now,
  }) {
    final remaining = deadline?.difference((now ?? DateTime.now)());
    if (remaining != null) {
      _timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
        expired = true;
        _interrupt();
        onTimeout?.call();
      });
    }
  }

  DateTime? deadline;
  final _interrupted = Completer<void>();
  Timer? _timer;
  bool expired = false;
  bool cancelled = false;

  static AppFailure get timeoutFailure =>
      AppFailure('本次播放准备已超时，请重试、换一集或更换线路。', code: 'playback_timeout');

  Future<T> guard<T>(Future<T> pending) => Future.any<T>([
    pending,
    _interrupted.future.then<T>((_) {
      if (expired) throw timeoutFailure;
      throw PlaybackAttemptCancelled();
    }),
  ]);

  void stable() {
    _timer?.cancel();
    _timer = null;
    deadline = null;
  }

  void cancel() {
    cancelled = true;
    _interrupt();
  }

  void _interrupt() {
    _timer?.cancel();
    _timer = null;
    if (!_interrupted.isCompleted) _interrupted.complete();
  }
}
