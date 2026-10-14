import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/watch_reminder_models.dart';
import 'package:duanju_app/watch_reminder_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late WatchReminderRuntime runtime;
  late DateTime now;
  late Duration elapsed;
  final owner = Object();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setPlaybackPreferences(
      const PlaybackPreferences(
        reminders: WatchReminderPreferences(
          dailyEnabled: true,
          dailyLimitMinutes: 1,
          bedtimeEnabled: true,
          bedtimeMinute: 60,
        ),
      ),
    );
    now = DateTime(2026, 10, 14, 0, 59);
    elapsed = Duration.zero;
    runtime = WatchReminderRuntime(
      store,
      now: () => now,
      elapsed: () => elapsed,
      startTimer: false,
    );
  });
  tearDown(() async {
    runtime.dispose();
    await runtime.flush();
    store.dispose();
  });
  void advance(Duration value) {
    now = now.add(value);
    elapsed += value;
    runtime.tick();
  }

  test(
    'cross-episode owners accumulate but paused and hidden periods do not',
    () async {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(seconds: 30));
      runtime.detachPlayback(owner);
      advance(const Duration(minutes: 10));
      runtime.setPlayback(Object(), watching: true, canShow: true);
      advance(const Duration(seconds: 30));
      expect(runtime.engine.progress.watchedMs, 60000);
      expect(runtime.notice, WatchReminderKind.values.toSet());
      await runtime.flush();
      expect(store.watchReminderProgress.watchedMs, 60000);
    },
  );

  test(
    'background does not show or accumulate and same-process four-hour absence does not reset latch',
    () {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      runtime.lifecycle(AppLifecycleState.paused);
      expect(runtime.notice, isEmpty);
      advance(const Duration(hours: 5));
      expect(runtime.engine.progress.watchedMs, 60000);
      runtime.lifecycle(AppLifecycleState.resumed);
      runtime.tick();
      expect(runtime.engine.progress.bedtimeLatched, true);
      expect(runtime.notice.contains(WatchReminderKind.bedtime), true);
    },
  );

  test(
    'observed detached session followed by more than four hours releases bedtime only',
    () {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      runtime.lifecycle(AppLifecycleState.detached);
      advance(const Duration(hours: 4, seconds: 1));
      runtime.lifecycle(AppLifecycleState.resumed);
      runtime.tick();
      expect(runtime.engine.progress.bedtimeLatched, false);
      expect(runtime.engine.progress.watchedMs, 60000);
      expect(runtime.notice, {WatchReminderKind.daily});
    },
  );

  test(
    'short restart restores latch, long cold restart releases it and keeps daily time',
    () async {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      await runtime.flush();
      runtime.dispose();
      await runtime.flush();
      now = now.add(const Duration(hours: 1));
      elapsed = Duration.zero;
      runtime = WatchReminderRuntime(
        store,
        now: () => now,
        elapsed: () => elapsed,
        startTimer: false,
      );
      expect(runtime.engine.progress.bedtimeLatched, true);
      expect(runtime.engine.progress.watchedMs, 60000);
      runtime.dispose();
      await runtime.flush();
      now = now.add(const Duration(hours: 4, seconds: 1));
      runtime = WatchReminderRuntime(
        store,
        now: () => now,
        elapsed: () => elapsed,
        startTimer: false,
      );
      expect(runtime.engine.progress.bedtimeLatched, false);
      expect(runtime.engine.progress.watchedMs, 60000);
    },
  );

  test(
    'notices never stack and acknowledgement starts a full repeat interval',
    () {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      expect(runtime.notice.length, 2);
      advance(const Duration(minutes: 10));
      expect(runtime.notice.length, 2);
      runtime.dismiss();
      expect(runtime.notice, isEmpty);
      advance(const Duration(minutes: 4, seconds: 59));
      expect(runtime.notice, isEmpty);
      advance(const Duration(seconds: 1));
      expect(runtime.notice.length, 2);
    },
  );

  test(
    'menus suppress display without losing watch time or pending conditions',
    () {
      runtime.setPlayback(owner, watching: true, canShow: false);
      advance(const Duration(minutes: 1));
      expect(runtime.notice, isEmpty);
      expect(runtime.engine.progress.watchedMs, 60000);
      runtime.setPlayback(owner, watching: true, canShow: true);
      expect(runtime.notice.length, 2);
      runtime.setPlayback(owner, watching: false, canShow: false);
      expect(runtime.notice, isEmpty);
    },
  );

  test(
    'settings changes disable each reminder immediately and preserve the other',
    () async {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(
          reminders: store.playbackPreferences.reminders.copyWith(
            bedtimeEnabled: false,
          ),
        ),
      );
      expect(runtime.notice, {WatchReminderKind.daily});
      expect(runtime.engine.progress.bedtimeLatched, false);
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(
          reminders: store.playbackPreferences.reminders.copyWith(
            dailyEnabled: false,
          ),
        ),
      );
      expect(runtime.notice, isEmpty);
      expect(runtime.engine.progress.watchedMs, 60000);
    },
  );
  test(
    'profile switches keep daily totals and bedtime latches isolated',
    () async {
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.saveProfile(
        name: '访客',
        sources: ['hongguo'],
        download: false,
      );
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      await store.switchProfile(visitor.id);
      expect(runtime.engine.progress.watchedMs, 0);
      expect(runtime.engine.progress.bedtimeLatched, false);
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 2));
      await store.switchProfile('default', pin: 'abcdef12');
      expect(runtime.engine.progress.watchedMs, 60000);
      expect(runtime.engine.progress.bedtimeLatched, true);
      await runtime.flush();
    },
  );

  test('locked startup never overwrites saved reminder progress', () async {
    runtime.setPlayback(owner, watching: true, canShow: true);
    advance(const Duration(minutes: 1));
    await runtime.flush();
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: [],
      download: true,
      pin: 'abcdef12',
    );
    runtime.dispose();
    await runtime.flush();
    final preferences = store.preferences;
    store.dispose();
    store = LocalStore(preferences);
    expect(store.locked, true);
    runtime = WatchReminderRuntime(
      store,
      now: () => now,
      elapsed: () => elapsed,
      startTimer: false,
    );
    await runtime.flush();
    await store.switchProfile('default', pin: 'abcdef12');
    expect(runtime.engine.progress.watchedMs, 60000);
    expect(runtime.engine.progress.bedtimeLatched, true);
  });

  test(
    'frequent progress saves do not postpone app activity heartbeat',
    () async {
      for (var i = 0; i < 12; i++) {
        runtime.setPlayback(owner, watching: true, canShow: false);
        advance(const Duration(seconds: 5));
        runtime.setPlayback(owner, watching: false, canShow: false);
      }
      await runtime.flush();
      final saved = DateTime.parse(
        store.preferences.getString(WatchReminderRuntime.activityKey)!,
      );
      expect(now.difference(saved), lessThan(const Duration(seconds: 30)));
    },
  );
  test(
    'midnight removes a stale daily popup but retains the bedtime reminder',
    () {
      runtime.setPlayback(owner, watching: true, canShow: true);
      advance(const Duration(minutes: 1));
      expect(runtime.notice.length, 2);
      now = DateTime(2026, 10, 15);
      runtime.tick();
      expect(runtime.engine.progress.watchedMs, 0);
      expect(runtime.notice, {WatchReminderKind.bedtime});
    },
  );
  test(
    'runtime created while already backgrounded cannot count or display',
    () async {
      runtime.dispose();
      await runtime.flush();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      try {
        runtime = WatchReminderRuntime(
          store,
          now: () => now,
          elapsed: () => elapsed,
          startTimer: false,
        );
        runtime.setPlayback(owner, watching: true, canShow: true);
        advance(const Duration(minutes: 1));
        expect(runtime.engine.progress.watchedMs, 0);
        expect(runtime.notice, isEmpty);
        runtime.lifecycle(AppLifecycleState.resumed);
        advance(const Duration(minutes: 1));
        expect(runtime.engine.progress.watchedMs, 60000);
      } finally {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}
