import 'dart:async';

import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';

class NextSeasonResolver {
  const NextSeasonResolver(this.repository);

  final AppRepository repository;

  Future<DramaDetail?> resolve(
    Drama anchor, {
    required Iterable<Drama> knownDramas,
    required bool Function() isCurrent,
  }) async {
    if (anchor.source != SourceSite.hongguo.id) return null;
    final info = hongguoSeriesInfo(anchor);
    final query = info?.baseTitle ?? anchor.title.trim();
    if (normalizedSearchText(query).isEmpty) return null;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    void checkCurrent() {
      if (!isCurrent()) {
        throw AppFailure('下一季续播已取消', code: 'next_season_cancelled');
      }
    }

    Future<T> bounded<T>(Future<T> Function() request) async {
      checkCurrent();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('下一季加载超时');
      }
      final value = await request().timeout(remaining);
      checkCurrent();
      return value;
    }

    final candidates = <String, Drama>{
      for (final drama in knownDramas) drama.id: drama,
    };
    var matches = _matches(anchor, candidates.values);
    if (matches.isEmpty) {
      for (var page = 1; page <= 5; page++) {
        final result = await bounded(
          () => repository.catalog(
            anchor.source,
            query: query,
            page: page,
            force: page == 1,
          ),
        );
        for (final drama in result.items) {
          candidates[drama.id] = drama;
        }
        if (!result.hasMore) break;
        if (page == 5) {
          throw AppFailure('同名结果较多，请手动选择下一季', code: 'next_season_ambiguous');
        }
      }
      matches = _matches(anchor, candidates.values);
    }
    if (matches.isEmpty) return null;
    if (matches.length != 1) {
      throw AppFailure('找到多个下一季版本，请手动选择', code: 'next_season_ambiguous');
    }
    final candidate = matches.single;
    final detail = await bounded(() => repository.detail(candidate));
    if (detail.drama.id != candidate.id ||
        _matches(anchor, [detail.drama]).length != 1) {
      throw AppFailure('下一季信息不一致，请手动选择', code: 'next_season_ambiguous');
    }
    if (detail.episodes.isEmpty) {
      throw AppFailure('下一季暂时没有可播放的集数', code: 'next_season_empty');
    }
    if (detail.episodes.first.vip) {
      throw AppFailure('下一季首集为 VIP 内容，请手动选择后确认试看', code: 'next_season_vip');
    }
    final merged = repository.catalogUpdates
        .current(candidate)
        .merge(detail.drama);
    return DramaDetail(
      merged,
      detail.episodes,
      warning: detail.warning,
      hasMoreEpisodes: detail.hasMoreEpisodes,
    );
  }

  List<Drama> _matches(Drama anchor, Iterable<Drama> candidates) {
    final current = hongguoSeriesInfo(anchor);
    final key = current?.key ?? normalizedSearchText(anchor.title);
    final next = (current?.season ?? 1) + 1;
    final matches = <String, Drama>{};
    for (final drama in candidates) {
      if (drama.id == anchor.id || drama.source != anchor.source) continue;
      final info = hongguoSeriesInfo(drama);
      if (info == null ||
          info.key != key ||
          info.season != next ||
          (current != null && info.unit != current.unit)) {
        continue;
      }
      matches[drama.id] = drama;
    }
    return matches.values.toList();
  }
}
