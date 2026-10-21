import 'package:duanju_app/watch_reminder_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WatchReminderEngine engine({
    WatchReminderPreferences prefs = const WatchReminderPreferences(
      dailyEnabled: true,
      dailyLimitMinutes: 60,
      bedtimeEnabled: true,
    ),
    DateTime? start,
  }) {
    final value = WatchReminderEngine(WatchReminderProgress(), prefs);
    value.openAppSession(start ?? DateTime(2026, 10, 14, 22), null);
    return value;
  }

  test('old and invalid reminder settings use safe independent defaults', () {
    final defaults = WatchReminderPreferences.fromJson(null);
    expect(defaults.dailyLimitMinutes, 240);
    expect(const WatchReminderPreferences().dailyLimitMinutes, 240);
    expect(WatchReminderPreferences.fromJson({}).dailyLimitMinutes, 240);
    expect(
      WatchReminderPreferences.fromJson({
        'dailyLimitMinutes': 120,
      }).dailyLimitMinutes,
      120,
    );
    expect(defaults.dailyEnabled, false);
    expect(defaults.bedtimeEnabled, false);
    expect(defaults.bedtimeMinute, 0);
    expect(defaults.dailyRepeatMinutes, 5);
    expect(defaults.bedtimeRepeatMinutes, 5);
    final bad = WatchReminderPreferences.fromJson({
      'dailyLimitMinutes': -1,
      'bedtimeMinute': 1440,
      'dailyRepeatMinutes': double.nan,
      'bedtimeEnabled': true,
    });
    expect(bad.dailyLimitMinutes, 240);
    expect(bad.bedtimeEnabled, true);
    expect(bad.bedtimeMinute, 0);
    expect(
      WatchReminderPreferences.fromJson(defaults.toJson()).toJson(),
      defaults.toJson(),
    );
  });

  test(
    'only actual watch elapsed counts, independently of media seeks and rate',
    () {
      final e = engine();
      e.advance(
        now: DateTime(2026, 10, 14, 22, 30),
        elapsed: const Duration(minutes: 30),
        watching: true,
      );
      e.advance(
        now: DateTime(2026, 10, 14, 23),
        elapsed: const Duration(minutes: 30),
        watching: false,
      );
      expect(e.progress.watchedMs, 1800000);
      final due = e.advance(
        now: DateTime(2026, 10, 14, 23, 30),
        elapsed: const Duration(minutes: 30),
        watching: true,
      );
      expect(due, {WatchReminderKind.daily});
      expect(e.progress.watchedMs, 3600000);
    },
  );

  test(
    'daily accumulation splits at local midnight and survives short reopening',
    () {
      final e = engine();
      e.advance(
        now: DateTime(2026, 10, 14, 23, 59),
        elapsed: const Duration(minutes: 90),
        watching: true,
      );
      e.openAppSession(
        DateTime(2026, 10, 14, 23, 59),
        DateTime(2026, 10, 14, 23, 50),
      );
      expect(e.progress.watchedMs, 5400000);
      e.advance(
        now: DateTime(2026, 10, 15, 0, 1),
        elapsed: const Duration(minutes: 2),
        watching: true,
      );
      expect(e.progress.day, '2026-10-15');
      expect(e.progress.watchedMs, 60000);
    },
  );

  test(
    'midnight bedtime triggers only when watching then persists across midnight and reload',
    () {
      final e = engine();
      expect(
        e.advance(
          now: DateTime(2026, 10, 15),
          elapsed: Duration.zero,
          watching: false,
        ),
        isEmpty,
      );
      expect(e.progress.bedtimeLatched, false);
      expect(
        e.advance(
          now: DateTime(2026, 10, 15, 0, 1),
          elapsed: Duration.zero,
          watching: true,
        ),
        {WatchReminderKind.bedtime},
      );
      final copy = WatchReminderEngine(
        WatchReminderProgress.fromJson(e.progress.toJson()),
        e.preferences,
      );
      copy.openAppSession(
        DateTime(2026, 10, 15, 1),
        DateTime(2026, 10, 15, 0, 59),
      );
      expect(copy.progress.bedtimeLatched, true);
      copy.advance(
        now: DateTime(2026, 10, 16, 0, 1),
        elapsed: Duration.zero,
        watching: false,
      );
      expect(copy.progress.bedtimeLatched, true);
    },
  );

  test(
    'strictly greater than four hours releases previous bedtime but not daily totals',
    () {
      for (final gap in [
        const Duration(hours: 4),
        const Duration(hours: 4, seconds: 1),
      ]) {
        final e = engine(start: DateTime(2026, 10, 15));
        e.advance(
          now: DateTime(2026, 10, 15, 1),
          elapsed: const Duration(hours: 1),
          watching: true,
        );
        expect(e.progress.bedtimeLatched, true);
        e.openAppSession(
          DateTime(2026, 10, 15, 1).add(gap),
          DateTime(2026, 10, 15, 1),
        );
        expect(e.progress.bedtimeLatched, gap == const Duration(hours: 4));
        expect(e.progress.watchedMs, 3600000);
        final due = e.advance(
          now: DateTime(2026, 10, 15, 1).add(gap),
          elapsed: Duration.zero,
          watching: true,
        );
        expect(due.contains(WatchReminderKind.daily), true);
        expect(
          due.contains(WatchReminderKind.bedtime),
          gap == const Duration(hours: 4),
        );
      }
    },
  );

  test(
    'long closure skips stale bedtime and schedules the next local bedtime',
    () {
      final e = engine();
      e.openAppSession(DateTime(2026, 10, 15, 9), DateTime(2026, 10, 14, 22));
      expect(
        e.advance(
          now: DateTime(2026, 10, 15, 9),
          elapsed: Duration.zero,
          watching: true,
        ),
        isEmpty,
      );
      expect(e.progress.nextBedtimeAt, DateTime(2026, 10, 16));
    },
  );

  test(
    'overlap combines both reasons, repeat intervals are independent and configurable',
    () {
      final e = engine(
        prefs: const WatchReminderPreferences(
          dailyEnabled: true,
          dailyLimitMinutes: 1,
          dailyRepeatMinutes: 2,
          bedtimeEnabled: true,
          bedtimeMinute: 60,
          bedtimeRepeatMinutes: 5,
        ),
        start: DateTime(2026, 10, 15, 0, 59),
      );
      final now = DateTime(2026, 10, 15, 1);
      final due = e.advance(
        now: now,
        elapsed: const Duration(minutes: 1),
        watching: true,
      );
      expect(due, WatchReminderKind.values.toSet());
      e.markShown(due, now);
      expect(
        e.advance(
          now: now.add(const Duration(minutes: 1)),
          elapsed: Duration.zero,
          watching: true,
        ),
        isEmpty,
      );
      expect(
        e.advance(
          now: now.add(const Duration(minutes: 2)),
          elapsed: Duration.zero,
          watching: true,
        ),
        {WatchReminderKind.daily},
      );
      e.markShown({
        WatchReminderKind.daily,
      }, now.add(const Duration(minutes: 2)));
      expect(
        e.advance(
          now: now.add(const Duration(minutes: 5)),
          elapsed: Duration.zero,
          watching: true,
        ),
        WatchReminderKind.values.toSet(),
      );
    },
  );

  test(
    'turning off one reminder leaves the other and actual daily time intact',
    () {
      final e = engine(start: DateTime(2026, 10, 15));
      e.advance(
        now: DateTime(2026, 10, 15, 1),
        elapsed: const Duration(hours: 1),
        watching: true,
      );
      e.configure(
        e.preferences.copyWith(bedtimeEnabled: false),
        DateTime(2026, 10, 15, 1),
      );
      expect(e.progress.bedtimeLatched, false);
      expect(
        e.advance(
          now: DateTime(2026, 10, 15, 1),
          elapsed: Duration.zero,
          watching: true,
        ),
        {WatchReminderKind.daily},
      );
      expect(e.progress.watchedMs, 3600000);
    },
  );

  test(
    'clock rollback never subtracts watched time or creates an infinite repeat delay',
    () {
      final e = engine();
      final now = DateTime(2026, 10, 14, 23);
      e.advance(now: now, elapsed: const Duration(hours: 1), watching: true);
      e.markShown({WatchReminderKind.daily}, now);
      expect(
        e.advance(
          now: now.subtract(const Duration(minutes: 5)),
          elapsed: const Duration(seconds: -1),
          watching: true,
        ),
        {WatchReminderKind.daily},
      );
      expect(e.progress.watchedMs, 3600000);
    },
  );
}
