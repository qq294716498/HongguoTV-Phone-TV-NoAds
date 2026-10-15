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

  bool get _valid => !_disposed &&
      !store.locked && store.profileEpoch == _epoch;

  Future<void> refresh() async {
    if (!_valid || checking) return;
    final dramas = store.trackedSeries
        .where((drama) => drama.source == SourceSite.hongguo.id).toList();
    final generation = ++_generation;
    bool current() => _valid && generation == _generation;
    checking = true;
    checked = 0;
    failed = 0;
    total = dramas.length;
    notifyListeners();
    var cursor = 0;
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
            await store.refreshDramas(
              catalog.entries.map((entry) => entry.drama),
            );
          }
          if (catalog.error.isNotEmpty || catalog.hasMore) failed++;
        } catch (_) {
          if (current()) failed++;
        } finally {
          catalog.dispose();
        }
        if (!current()) return;
        checked++;
        notifyListeners();
      }
    }

    try {
      await worker();
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
