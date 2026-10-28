import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'hongguo_series.dart';
import 'models.dart';
import 'series_catalog.dart';

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
        .where((drama) => force || !store.hasNextSeason(drama))
        .toList();
    final generation = ++_generation;
    bool current() => _valid && generation == _generation;
    checking = true;
    checked = 0;
    failed = 0;
    total = dramas.length;
    notifyListeners();
    var cursor = 0;
    final pending = <String, Drama>{};
    Future<void> flush() async {
      if (pending.isEmpty || !current()) return;
      final results = pending.values.toList();
      pending.clear();
      await store.refreshDramas(results);
    }

    Future<void> worker() async {
      while (current() && cursor < dramas.length) {
        final drama = dramas[cursor++];
        if (store.followedSeries(drama) == null ||
            !force && store.hasNextSeason(drama))
          continue;
        final anchor = _anchor(drama);
        bool stillCurrent() {
          if (!current() || store.followedSeries(drama) == null) return false;
          final latest = _anchor(drama);
          return (latest.source, latest.id, latest.title) ==
              (anchor.source, anchor.id, anchor.title);
        }

        final catalog = SeriesCatalog(
          anchor: anchor,
          repository: repository,
          knownDramas: store.seriesDramasFor(drama),
          allowed: stillCurrent,
        );
        try {
          await catalog.load();
          if (!current()) return;
          if (stillCurrent()) {
            for (final entry in catalog.entries) {
              pending[entry.drama.id] = entry.drama;
            }
            final next = (hongguoSeriesInfo(anchor)?.season ?? 1) + 1;
            final foundNext = catalog.entries.any(
              (entry) => entry.season == next,
            );
            if (!foundNext && (catalog.error.isNotEmpty || catalog.hasMore))
              failed++;
          }
        } catch (_) {
          if (current()) failed++;
        } finally {
          catalog.dispose();
        }
        if (!current()) return;
        checked++;
        if (checked % 8 == 0) await flush();
        if (!current()) return;
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    try {
      await worker();
      await flush();
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
