import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
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

  Future<void> refresh() async {
    if (!_valid || checking) return;
    final dramas = store.trackedSeries
        .where((drama) => drama.source == SourceSite.hongguo.id)
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
        if (store.followedSeries(drama) == null) continue;
        final catalog = SeriesCatalog(
          anchor: drama,
          repository: repository,
          knownDramas: store.seriesDramasFor(drama),
          allowed: () => current() && store.followedSeries(drama) != null,
        );
        try {
          await catalog.load();
          if (!current()) return;
          if (store.followedSeries(drama) != null) {
            for (final entry in catalog.entries) {
              pending[entry.drama.id] = entry.drama;
            }
            if (catalog.error.isNotEmpty || catalog.hasMore) failed++;
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
