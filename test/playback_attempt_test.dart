import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/playback_attempt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'superseding an attempt releases its pending operation immediately',
    (tester) async {
      final attempt = PlaybackAttempt();
      final pending = Completer<void>();
      final guarded = attempt.guard(pending.future);
      final result = expectLater(
        guarded,
        throwsA(isA<PlaybackAttemptCancelled>()),
      );
      attempt.cancel();
      await tester.pump();
      await result;
      expect(pending.isCompleted, false);
      pending.complete();
      await tester.pump();
    },
  );

  testWidgets('one deadline covers multiple pending recovery stages', (
    tester,
  ) async {
    var timeouts = 0;
    final attempt = PlaybackAttempt(
      deadline: DateTime.now().add(const Duration(seconds: 45)),
      onTimeout: () => timeouts++,
    );
    await attempt.guard(Future<void>.value());
    await tester.pump(const Duration(seconds: 30));
    final pending = Completer<void>();
    final result = expectLater(
      attempt.guard(pending.future),
      throwsA(
        isA<AppFailure>().having((e) => e.code, 'code', 'playback_timeout'),
      ),
    );
    await tester.pump(const Duration(seconds: 16));
    await result;
    expect(timeouts, 1);
    pending.complete();
    await tester.pump();
  });

  testWidgets('stable playback clears the startup deadline', (tester) async {
    var timeouts = 0;
    final attempt = PlaybackAttempt(
      deadline: DateTime.now().add(const Duration(seconds: 45)),
      onTimeout: () => timeouts++,
    );
    attempt.stable();
    await tester.pump(const Duration(minutes: 2));
    expect(timeouts, 0);
    expect(attempt.deadline, isNull);
    attempt.cancel();
  });

  testWidgets('a recovery inherits the original remaining deadline', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 20);
    final original = PlaybackAttempt(
      deadline: now.add(const Duration(seconds: 45)),
      now: () => now,
    );
    await tester.pump(const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 30));
    original.cancel();
    var timedOut = false;
    final recovery = PlaybackAttempt(
      deadline: original.deadline,
      now: () => now,
      onTimeout: () => timedOut = true,
    );
    await tester.pump(const Duration(seconds: 14));
    expect(timedOut, false);
    await tester.pump(const Duration(seconds: 1));
    expect(timedOut, true);
    recovery.cancel();
  });
}
