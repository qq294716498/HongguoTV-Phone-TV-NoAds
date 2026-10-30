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
  int checked = 0;
  int total = 0;
  int failed = 0;
  bool _disposed = false;
  int _generation = 0;

  bool get _valid =>
      !_disposed && !store.locked && store.profileEpoch == _epoch;

  Drama _anchor(Drama drama) =>
      store.seriesWatch(drama)?.drama ?? store.followedSeries(drama) ?? drama;

  Future<void> refresh({bool force = false}) async {
    if (!_valid || checking) return;
    final dramas = store.trackedSeries
        .where((drama) => drama.source == SourceSite.hongguo.id)
        .where(
          (drama) => store.shouldCheckNextSeason(_anchor(drama), force: force),
        )
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
            !store.shouldCheckNextSeason(_anchor(drama), force: force)) {
          continue;
        }
        final anchor = _anchor(drama);
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
        }
        if (!current()) return;
        checked++;
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    try {
      await Future.wait([worker(), worker()]);
    } finally {
      if (current()) {
        checking = false;
        notifyListeners();
      }
    }
  }

  void cancel() {
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
