import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'local_store.dart';
import 'watch_reminder_models.dart';

class WatchReminderRuntime extends ChangeNotifier {
  WatchReminderRuntime(
    this.store, {
    DateTime Function()? now,
    Duration Function()? elapsed,
    bool startTimer = true,
  }) : _now = now ?? DateTime.now {
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _clock.start();
    _elapsed = elapsed ?? (() => _clock.elapsed);
    _lastElapsed = _elapsed();
    _sessionPreviousActivity = DateTime.tryParse(
      store.preferences.getString(activityKey) ?? '',
    );
    _sessionOpenedAt = _now();
    _loadProfile();
    store.addListener(_storeChanged);
    _saveActivity();
    if (startTimer) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  static WatchReminderRuntime? current;
  static const activityKey = 'watchReminder.lastAppActiveAt';
  final LocalStore store;
  final DateTime Function() _now;
  final Stopwatch _clock = Stopwatch();
  late final Duration Function() _elapsed;
  late Duration _lastElapsed;
  late WatchReminderEngine engine;
  late String _profile;
  late int _epoch;
  final Set<String> _openedProfiles = {};
  DateTime? _sessionPreviousActivity;
  late DateTime _sessionOpenedAt;
  bool _profileLocked = false;
  DateTime? _lastActivity;
  DateTime? _lastSave;
  Timer? _timer;
  Object? _owner;
  bool _watching = false;
  bool _canShow = false;
  bool _foreground = true;
  bool _detached = false;
  bool _disposed = false;
  Set<WatchReminderKind> _notice = {};
  Set<WatchReminderKind> get notice => Set.unmodifiable(_notice);
  bool get foreground => _foreground;
  Future<void> _pendingWrites = Future<void>.value();
  String? persistenceError;

  void _write(Future<void> Function() action) {
    _pendingWrites = _pendingWrites.then((_) async {
      try {
        await action();
        persistenceError = null;
      } catch (_) {
        persistenceError = '提醒记录未能保存，重启后的累计和提醒状态可能不完整';
        if (!_disposed) notifyListeners();
      }
    });
  }

  void _saveActivity() {
    final now = _now();
    _lastActivity = now;
    _write(() async {
      if (!await store.preferences.setString(
        activityKey,
        now.toIso8601String(),
      )) {
        throw StateError('Unable to save app activity');
      }
    });
  }

  void _saveProgress() {
    if (_profileLocked) return;
    final profile = _profile;
    final json = jsonEncode(engine.progress.toJson());
    _lastSave = _now();
    _write(() => store.saveWatchReminderProgress(profile, json));
  }

  void _loadProfile() {
    _profile = store.profile.id;
    _epoch = store.profileEpoch;
    _profileLocked = store.locked;
    engine = WatchReminderEngine(
      store.watchReminderProgress,
      store.playbackPreferences.reminders,
    );
    if (!_profileLocked && _openedProfiles.add(_profile)) {
      engine.openAppSession(_sessionOpenedAt, _sessionPreviousActivity);
    } else {
      engine.configure(store.playbackPreferences.reminders, _now());
    }
    engine.advance(now: _now(), elapsed: Duration.zero, watching: false);
    _notice = {};
    _saveProgress();
  }

  bool _applicable(WatchReminderKind kind) => kind == WatchReminderKind.daily
      ? engine.preferences.dailyEnabled &&
            engine.progress.watchedMs >=
                engine.preferences.dailyLimitMinutes * 60000
      : engine.preferences.bedtimeEnabled && engine.progress.bedtimeLatched;

  void _storeChanged() {
    if (_disposed) return;
    if (store.profileEpoch != _epoch ||
        store.profile.id != _profile ||
        store.locked != _profileLocked) {
      tick(canEmit: false);
      _saveProgress();
      _watching = false;
      _canShow = false;
      _owner = null;
      _loadProfile();
    } else {
      final before = jsonEncode(engine.progress.toJson());
      engine.configure(store.playbackPreferences.reminders, _now());
      if (before != jsonEncode(engine.progress.toJson())) _saveProgress();
      _notice.removeWhere((kind) => !_applicable(kind));
      if (store.locked) {
        _watching = false;
        _notice.clear();
      }
    }
    notifyListeners();
  }

  void setPlayback(
    Object owner, {
    required bool watching,
    required bool canShow,
  }) {
    if (_disposed) return;
    if (identical(_owner, owner) &&
        _watching == watching &&
        _canShow == canShow) {
      return;
    }
    tick(canEmit: false);
    _owner = owner;
    final wasWatching = _watching;
    _watching = watching;
    _canShow = canShow;
    if (!watching && _notice.isNotEmpty) {
      _notice.clear();
      notifyListeners();
    }
    if (wasWatching && !watching) _saveProgress();
    tick();
  }

  void detachPlayback(Object owner) {
    if (!identical(_owner, owner)) return;
    setPlayback(owner, watching: false, canShow: false);
    _owner = null;
    _saveProgress();
  }

  void lifecycle(AppLifecycleState state) {
    if (_disposed) return;
    tick(canEmit: false);
    if (state == AppLifecycleState.resumed && _detached) {
      _sessionPreviousActivity = _lastActivity;
      _openedProfiles.clear();
      _sessionOpenedAt = _now();
      engine.openAppSession(_sessionOpenedAt, _sessionPreviousActivity);
      _openedProfiles.add(_profile);
      _detached = false;
    }
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.detached) _detached = true;
    if (!_foreground) _notice.clear();
    _saveActivity();
    _saveProgress();
    notifyListeners();
  }

  void tick({bool canEmit = true}) {
    if (_disposed) return;
    final elapsed = _elapsed();
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    final now = _now();
    final watching =
        _watching &&
        _foreground &&
        !store.locked &&
        store.profileEpoch == _epoch;
    final due = engine.advance(
      now: now,
      elapsed: delta,
      watching: watching,
      canShow: canEmit && _canShow,
    );
    final previousNoticeLength = _notice.length;
    _notice.removeWhere((kind) => !_applicable(kind));
    final trimmed = _notice.length != previousNoticeLength;
    final fresh = due.difference(_notice);
    if (fresh.isNotEmpty) {
      _notice = {..._notice, ...fresh};
      engine.markShown(fresh, now);
      _saveProgress();
      notifyListeners();
    } else if (trimmed) {
      notifyListeners();
    }
    if (_lastSave == null ||
        now.isBefore(_lastSave!) ||
        now.difference(_lastSave!) >= const Duration(seconds: 30)) {
      _saveProgress();
    }
    if (_foreground &&
        (_lastActivity == null ||
            now.isBefore(_lastActivity!) ||
            now.difference(_lastActivity!) >= const Duration(seconds: 30))) {
      _saveActivity();
    }
  }

  void dismiss() {
    if (_notice.isEmpty) return;
    engine.markShown(_notice, _now());
    _notice = {};
    _saveProgress();
    notifyListeners();
  }

  Future<void> flush() async {
    tick(canEmit: false);
    _saveProgress();
    await _pendingWrites;
  }

  @override
  void dispose() {
    if (_disposed) return;
    tick(canEmit: false);
    _saveActivity();
    _saveProgress();
    _disposed = true;
    _timer?.cancel();
    _clock.stop();
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
