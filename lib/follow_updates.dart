import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'next_season_resolver.dart';
import 'season_check.dart';

class FollowUpdates extends ChangeNotifier {
  FollowUpdates(this.repository, this.store) : _epoch = store.profileEpoch;
  final AppRepository repository;
  final LocalStore store;
  final int _epoch;
  bool checking = false;
  bool _forcePending = false;
  int checked = 0;
  int total = 0;
  int failed = 0;
  bool _disposed = false;
  int _generation = 0;

  bool get _valid =>
      !_disposed && !store.locked && store.profileEpoch == _epoch;

  Drama _anchor(Drama drama) =>
      store.seriesWatch(drama)?.drama ?? store.followedSeries(drama) ?? drama;

  bool _shouldCheck(Drama drama, {bool force = false}) =>
      !store.hasNextSeason(drama) &&
      store.shouldCheckNextSeason(_anchor(drama), force: force);

  Future<void> refresh({bool force = false}) async {
    if (!_valid) return;
    if (checking) {
      if (force) _forcePending = true;
      return;
    }
    final tracked = store.trackedSeries
        .where((drama) => drama.source == SourceSite.hongguo.id)
        .toList();
    final dramas = tracked
        .where((drama) => _shouldCheck(drama, force: force))
        .toList();
    final generation = ++_generation;
    bool current() => _valid && generation == _generation;
    checking = true;
    checked = 0;
    failed = 0;
    total = dramas.length;
    notifyListeners();
    var cursor = 0;
    Future<void> worker() async {
      while (current() &&
          !store.seasonChecksBlocked &&
          cursor < dramas.length) {
        final drama = dramas[cursor++];
        if (store.followedSeries(drama) == null ||
            !_shouldCheck(drama, force: force)) {
          continue;
        }
        var anchor = _anchor(drama);
        var claimed = false;
        while (current()) {
          final pending = store.seasonCheckPending(anchor.id, _epoch);
          if (pending != null) {
            await pending;
            if (!current() || store.followedSeries(drama) == null) break;
            anchor = _anchor(drama);
            if (!_shouldCheck(drama, force: force)) break;
            continue;
          }
          if (store.beginSeasonCheck(anchor.id, _epoch)) {
            claimed = true;
            break;
          }
        }
        if (!claimed) continue;
        if (!current() ||
            store.followedSeries(drama) == null ||
            !_shouldCheck(drama, force: force)) {
          store.endSeasonCheck(anchor.id, _epoch);
          continue;
        }
        final expected = SeasonCheck.observed(
          anchor,
          checkedAt: store.seasonCheckTime,
          nextId: null,
          complete: false,
        );
        bool stillCurrent() {
          if (!current() || store.followedSeries(drama) == null) return false;
          return expected.matches(_anchor(drama));
        }

        try {
          final result = await NextSeasonResolver(repository).lookup(
            anchor,
            knownDramas: store.seriesDramasFor(drama),
            isCurrent: stillCurrent,
            trustKnownNext: false,
            requirePlayableDetail: false,
            singleSearch: true,
            force: force,
          );
          if (!current()) return;
          if (stillCurrent()) {
            final next = result.ambiguous ? null : result.next;
            final complete =
                result.complete && !result.ambiguous && result.warning.isEmpty;
            await store.applySeasonCheck(
              followed: drama,
              anchor: anchor,
              resolvedAnchor: result.anchor,
              next: next,
              complete: complete,
              isCurrent: stillCurrent,
            );
            if (next == null && !complete) failed++;
          }
        } catch (error) {
          if (stillCurrent()) {
            failed++;
            final failure = error is AppFailure ? error : null;
            try {
              await store.applySeasonCheck(
                followed: drama,
                anchor: anchor,
                resolvedAnchor: anchor,
                next: null,
                complete: false,
                isCurrent: stillCurrent,
                retryAt: failure?.retryAt,
                blocked: failure?.code == 'source_blocked',
              );
            } catch (_) {}
          }
        } finally {
          store.endSeasonCheck(anchor.id, _epoch);
        }
        if (!current()) return;
        checked++;
        notifyListeners();
      }
    }

    try {
      await Future.wait(
        List.generate(tracked.length > 3 ? 3 : 1, (_) => worker()),
      );
    } finally {
      if (current()) {
        checking = false;
        final repeat = _forcePending;
        _forcePending = false;
        notifyListeners();
        if (repeat) unawaited(refresh(force: true));
      }
    }
  }

  void cancel() {
    _forcePending = false;
    _generation++;
    checking = false;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
