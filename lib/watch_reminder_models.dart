enum WatchReminderKind { daily, bedtime }

class WatchReminderPreferences {
  const WatchReminderPreferences({
    this.dailyEnabled = false,
    this.dailyLimitMinutes = 240,
    this.dailyRepeatMinutes = 5,
    this.bedtimeEnabled = false,
    this.bedtimeMinute = 0,
    this.bedtimeRepeatMinutes = 5,
  });

  final bool dailyEnabled;
  final int dailyLimitMinutes;
  final int dailyRepeatMinutes;
  final bool bedtimeEnabled;
  final int bedtimeMinute;
  final int bedtimeRepeatMinutes;

  WatchReminderPreferences copyWith({
    bool? dailyEnabled,
    int? dailyLimitMinutes,
    int? dailyRepeatMinutes,
    bool? bedtimeEnabled,
    int? bedtimeMinute,
    int? bedtimeRepeatMinutes,
  }) => WatchReminderPreferences(
    dailyEnabled: dailyEnabled ?? this.dailyEnabled,
    dailyLimitMinutes: dailyLimitMinutes ?? this.dailyLimitMinutes,
    dailyRepeatMinutes: dailyRepeatMinutes ?? this.dailyRepeatMinutes,
    bedtimeEnabled: bedtimeEnabled ?? this.bedtimeEnabled,
    bedtimeMinute: bedtimeMinute ?? this.bedtimeMinute,
    bedtimeRepeatMinutes: bedtimeRepeatMinutes ?? this.bedtimeRepeatMinutes,
  );

  factory WatchReminderPreferences.fromJson(dynamic value) {
    final map = value is Map ? value : const {};
    int number(String key, int fallback, int min, int max) {
      final value = map[key];
      return value is int && value >= min && value <= max ? value : fallback;
    }

    return WatchReminderPreferences(
      dailyEnabled: map['dailyEnabled'] == true,
      dailyLimitMinutes: number('dailyLimitMinutes', 240, 1, 1440),
      dailyRepeatMinutes: number('dailyRepeatMinutes', 5, 1, 120),
      bedtimeEnabled: map['bedtimeEnabled'] == true,
      bedtimeMinute: number('bedtimeMinute', 0, 0, 1439),
      bedtimeRepeatMinutes: number('bedtimeRepeatMinutes', 5, 1, 120),
    );
  }

  Map<String, dynamic> toJson() => {
    'dailyEnabled': dailyEnabled,
    'dailyLimitMinutes': dailyLimitMinutes,
    'dailyRepeatMinutes': dailyRepeatMinutes,
    'bedtimeEnabled': bedtimeEnabled,
    'bedtimeMinute': bedtimeMinute,
    'bedtimeRepeatMinutes': bedtimeRepeatMinutes,
  };
}

String watchLocalDay(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

class WatchReminderProgress {
  WatchReminderProgress({
    this.day = '',
    this.watchedMs = 0,
    this.bedtimeLatched = false,
    this.nextBedtimeAt,
    this.dailyShownAt,
    this.bedtimeShownAt,
    this.scheduledMinute,
    this.timezoneMinutes,
  });

  String day;
  int watchedMs;
  bool bedtimeLatched;
  DateTime? nextBedtimeAt;
  DateTime? dailyShownAt;
  DateTime? bedtimeShownAt;
  int? scheduledMinute;
  int? timezoneMinutes;

  factory WatchReminderProgress.fromJson(dynamic value) {
    final map = value is Map ? value : const {};
    DateTime? date(String key) {
      final value = map[key];
      if (value is! int || value < 0 || value > 8640000000000000) return null;
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    final rawDay = map['day'];
    final rawMs = map['watchedMs'];
    return WatchReminderProgress(
      day: rawDay is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawDay)
          ? rawDay
          : '',
      watchedMs: rawMs is int && rawMs >= 0 && rawMs <= 172800000 ? rawMs : 0,
      bedtimeLatched: map['bedtimeLatched'] == true,
      nextBedtimeAt: date('nextBedtimeAt'),
      dailyShownAt: date('dailyShownAt'),
      bedtimeShownAt: date('bedtimeShownAt'),
      scheduledMinute: map['scheduledMinute'] is int
          ? map['scheduledMinute'] as int
          : null,
      timezoneMinutes: map['timezoneMinutes'] is int
          ? map['timezoneMinutes'] as int
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'day': day,
    'watchedMs': watchedMs,
    'bedtimeLatched': bedtimeLatched,
    'nextBedtimeAt': nextBedtimeAt?.millisecondsSinceEpoch,
    'dailyShownAt': dailyShownAt?.millisecondsSinceEpoch,
    'bedtimeShownAt': bedtimeShownAt?.millisecondsSinceEpoch,
    'scheduledMinute': scheduledMinute,
    'timezoneMinutes': timezoneMinutes,
  };
}

class WatchReminderEngine {
  WatchReminderEngine(this.progress, this.preferences);
  final WatchReminderProgress progress;
  WatchReminderPreferences preferences;

  DateTime _nextBedtime(DateTime now, {bool strictlyAfter = false}) {
    final minute = preferences.bedtimeMinute;
    final today = DateTime(
      now.year,
      now.month,
      now.day,
      minute ~/ 60,
      minute % 60,
    );
    if (today.isBefore(now) || strictlyAfter && today == now) {
      return DateTime(
        now.year,
        now.month,
        now.day + 1,
        minute ~/ 60,
        minute % 60,
      );
    }
    return today;
  }

  void configure(WatchReminderPreferences value, DateTime now) {
    preferences = value;
    if (!value.dailyEnabled) progress.dailyShownAt = null;
    if (!value.bedtimeEnabled) {
      progress.bedtimeLatched = false;
      progress.nextBedtimeAt = null;
      progress.bedtimeShownAt = null;
    } else if (progress.nextBedtimeAt == null ||
        progress.scheduledMinute != value.bedtimeMinute ||
        progress.timezoneMinutes != now.timeZoneOffset.inMinutes) {
      progress.nextBedtimeAt = _nextBedtime(now);
    }
    progress.scheduledMinute = value.bedtimeMinute;
    progress.timezoneMinutes = now.timeZoneOffset.inMinutes;
  }

  void openAppSession(DateTime now, DateTime? lastActiveAt) {
    configure(preferences, now);
    if (lastActiveAt != null &&
        now.difference(lastActiveAt) > const Duration(hours: 4)) {
      progress.bedtimeLatched = false;
      progress.bedtimeShownAt = null;
      if (preferences.bedtimeEnabled) {
        progress.nextBedtimeAt = _nextBedtime(now, strictlyAfter: true);
      }
    }
    advance(now: now, elapsed: Duration.zero, watching: false);
  }

  Set<WatchReminderKind> advance({
    required DateTime now,
    required Duration elapsed,
    required bool watching,
    bool canShow = true,
  }) {
    final day = watchLocalDay(now);
    if (progress.day != day) {
      progress.day = day;
      progress.watchedMs = 0;
      progress.dailyShownAt = null;
    }
    if (watching && elapsed > Duration.zero) {
      final midnight = DateTime(now.year, now.month, now.day);
      final todayMs = now.difference(midnight).inMilliseconds;
      final delta = elapsed.inMilliseconds.clamp(0, todayMs);
      progress.watchedMs = (progress.watchedMs + delta).clamp(0, 172800000);
    }
    if (!watching) return {};
    if (preferences.bedtimeEnabled &&
        progress.nextBedtimeAt != null &&
        !now.isBefore(progress.nextBedtimeAt!)) {
      progress.bedtimeLatched = true;
    }
    if (!canShow) return {};
    bool due(DateTime? last, int minutes) =>
        last == null ||
        now.isBefore(last) ||
        now.difference(last) >= Duration(minutes: minutes);
    return {
      if (preferences.dailyEnabled &&
          progress.watchedMs >= preferences.dailyLimitMinutes * 60000 &&
          due(progress.dailyShownAt, preferences.dailyRepeatMinutes))
        WatchReminderKind.daily,
      if (preferences.bedtimeEnabled &&
          progress.bedtimeLatched &&
          due(progress.bedtimeShownAt, preferences.bedtimeRepeatMinutes))
        WatchReminderKind.bedtime,
    };
  }

  void markShown(Set<WatchReminderKind> kinds, DateTime now) {
    if (kinds.contains(WatchReminderKind.daily)) progress.dailyShownAt = now;
    if (kinds.contains(WatchReminderKind.bedtime)) {
      progress.bedtimeShownAt = now;
    }
  }
}
