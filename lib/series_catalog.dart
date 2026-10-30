import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';

class SeriesCatalog extends ChangeNotifier {
  SeriesCatalog({
    required this.anchor,
    required this.repository,
    required Iterable<Drama> knownDramas,
    required this.allowed,
  }) {
    for (final drama in [anchor, ...knownDramas]) {
      _candidates.putIfAbsent(drama.id, () => drama);
    }
  }

  final Drama anchor;
  final AppRepository repository;
  final bool Function() allowed;
  final _candidates = <String, Drama>{};
  final _hydrated = <String>{};
  Drama? _matchingAnchor;
  bool loading = false;
  bool hasMore = true;
  String error = '';
  int _page = 0;
  int _generation = 0;
  bool _targeted = false;
  bool _disposed = false;

  List<HongguoSeriesEntry> get entries {
    final found = hongguoSeriesEntries(
      _matchingAnchor ?? anchor,
      _candidates.values,
    );
    if (found.isNotEmpty) return found;
    final info = hongguoSeriesInfo(anchor);
    return [
      HongguoSeriesEntry(
        drama: anchor,
        season: info?.season ?? 1,
        unit: info?.unit ?? '季',
      ),
    ];
  }

  String get title => hongguoSeriesInfo(anchor)?.baseTitle ?? anchor.title;
  bool _current(int generation) =>
      !_disposed && generation == _generation && allowed();

  Future<void> load({bool refresh = false}) async {
    if (_disposed || loading || !allowed() || (!refresh && !hasMore)) return;
    if (refresh) {
      _page = 0;
      _hydrated.clear();
      _targeted = false;
      hasMore = true;
    }
    final generation = ++_generation;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    Duration remaining() {
      final duration = deadline.difference(DateTime.now());
      if (duration <= Duration.zero) throw TimeoutException('续季查询超时');
      return duration < const Duration(seconds: 20)
          ? duration
          : const Duration(seconds: 20);
    }

    Future<T> bounded<T>(Future<T> Function() request) {
      final timeout = remaining();
      return request().timeout(timeout);
    }

    loading = true;
    error = '';
    notifyListeners();
    try {
      try {
        for (var count = 0; count < 5 && hasMore; count++) {
          final page = _page + 1;
          final result = await bounded(
            () => repository.catalog(
              anchor.source,
              query: title.trim(),
              page: page,
              force: refresh && page == 1,
            ),
          );
          if (!_current(generation)) return;
          for (final drama in result.items) {
            _candidates[drama.id] = drama;
          }
          _page = page;
          hasMore = result.hasMore;
          if (result.warning.isNotEmpty) {
            error = result.warning;
            break;
          }
          notifyListeners();
        }
      } catch (failure) {
        if (!_current(generation)) return;
        if (failure is AppFailure && failure.code == 'source_blocked') rethrow;
        error = '部分季暂时未能加载，请重试';
      }
      _matchingAnchor = await hydrateHongguoNextSeason(
        _matchingAnchor ?? anchor,
        _candidates,
        _hydrated,
        (drama) async {
          if (!_current(generation))
            throw AppFailure('查询已取消', code: 'next_season_cancelled');
          return bounded(() => repository.detail(drama));
        },
      );
      if (!_current(generation)) return;
      final next = (hongguoSeriesInfo(anchor)?.season ?? 1) + 1;
      if (!_targeted && !entries.any((entry) => entry.season == next)) {
        _targeted = true;
        for (final query in hongguoNextSeasonQueries(anchor)) {
          for (var page = 1; page <= 3; page++) {
            if (!_current(generation)) return;
            CatalogPage result;
            try {
              result = await bounded(
                () => repository.catalog(
                  anchor.source,
                  query: query,
                  page: page,
                  force: refresh && page == 1,
                ),
              );
            } catch (failure) {
              if (!_current(generation)) return;
              if (failure is AppFailure && failure.code == 'source_blocked') {
                rethrow;
              }
              _targeted = false;
              error = '部分季暂时未能加载，请重试';
              break;
            }
            if (!_current(generation)) return;
            for (final drama in result.items) {
              _candidates[drama.id] = drama;
            }
            _matchingAnchor = await hydrateHongguoNextSeason(
              _matchingAnchor ?? anchor,
              _candidates,
              _hydrated,
              (drama) async {
                if (!_current(generation))
                  throw AppFailure('查询已取消', code: 'next_season_cancelled');
                return bounded(() => repository.detail(drama));
              },
            );
            if (!_current(generation)) return;
            if (result.warning.isNotEmpty) {
              _targeted = false;
              error = result.warning;
            }
            if (entries.any((entry) => entry.season == next) ||
                !result.hasMore ||
                result.warning.isNotEmpty)
              break;
          }
          if (entries.any((entry) => entry.season == next)) break;
        }
      }
    } catch (_) {
      _targeted = false;
      if (_current(generation)) {
        error = '部分季暂时未能加载，请重试';
      }
    } finally {
      if (_current(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void cancel() {
    _generation++;
    loading = false;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

Future<Drama> hydrateHongguoNextSeason(
  Drama anchor,
  Map<String, Drama> candidates,
  Set<String> attempted,
  Future<DramaDetail> Function(Drama) detail,
) async {
  final current = hongguoSeriesInfo(anchor);
  final next = (current?.season ?? 1) + 1;
  final nearby = candidates.values
      .where((candidate) {
        final info = hongguoSeriesInfo(candidate);
        return info != null &&
            info.season == next &&
            (current == null || current.unit == info.unit) &&
            (hongguoSimilarSeriesTitles(anchor, candidate) ||
                anchor.seriesGroupId.isNotEmpty &&
                    anchor.seriesGroupId == candidate.seriesGroupId) &&
            !hongguoVerifiedSameSeries(anchor, candidate);
      })
      .take(4)
      .toList();
  if (nearby.isEmpty) return anchor;
  Future<Drama> enriched(Drama drama) async {
    if (hongguoSeriesCharacters(drama.description).isNotEmpty ||
        attempted.length >= 5 ||
        !attempted.add(drama.id))
      return drama;
    try {
      final fresh = (await detail(drama)).drama;
      return fresh.id == drama.id ? drama.merge(fresh) : drama;
    } on AppFailure catch (failure) {
      if (failure.code == 'source_blocked' ||
          failure.code == 'next_season_cancelled')
        rethrow;
      return drama;
    } catch (_) {
      return drama;
    }
  }

  anchor = await enriched(anchor);
  candidates[anchor.id] = anchor;
  for (final candidate in nearby) {
    candidates[candidate.id] = await enriched(candidate);
  }
  return anchor;
}
