import 'dart:async';

import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';
import 'series_catalog.dart';

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
    final deadline = DateTime.now().add(const Duration(seconds: 45));
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
    Object? searchFailure;
    var receivedResults = false;
    Future<CatalogPage?> search(String text, int page) async {
      try {
        final result = await bounded(
          () => repository.catalog(
            anchor.source,
            query: text,
            page: page,
            force: page == 1,
          ),
        );
        receivedResults = true;
        return result;
      } catch (failure) {
        checkCurrent();
        if (failure is AppFailure && failure.code == 'source_blocked') rethrow;
        searchFailure = failure;
        return null;
      }
    }

    final hydrated = <String>{};
    Future<void> hydrate() async {
      anchor = await hydrateHongguoNextSeason(
        anchor,
        candidates,
        hydrated,
        (drama) => bounded(() => repository.detail(drama)),
      );
      checkCurrent();
    }

    await hydrate();
    var matches = _matches(anchor, candidates.values);
    if (matches.isEmpty) {
      for (var page = 1; page <= 5; page++) {
        final result = await search(query, page);
        if (result == null) break;
        for (final drama in result.items) {
          candidates[drama.id] = drama;
        }
        await hydrate();
        if (_matches(anchor, candidates.values).isNotEmpty || !result.hasMore) {
          break;
        }
      }
      matches = _matches(anchor, candidates.values);
    }
    if (matches.isEmpty) {
      for (final targeted in hongguoNextSeasonQueries(anchor)) {
        final result = await search(targeted, 1);
        if (result == null) continue;
        for (final drama in result.items) {
          candidates[drama.id] = drama;
        }
        await hydrate();
        matches = _matches(anchor, candidates.values);
        if (matches.isNotEmpty) break;
      }
    }
    if (matches.isEmpty) {
      if (!receivedResults && searchFailure != null) throw searchFailure!;
      return null;
    }
    if (matches.length != 1) {
      final narrowed = _disambiguate(anchor, matches);
      if (narrowed == null) {
        throw AppFailure('找到多个下一季版本，请手动选择', code: 'next_season_ambiguous');
      }
      matches = [narrowed];
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
    final next = (current?.season ?? 1) + 1;
    final matches = <String, Drama>{};
    for (final drama in candidates) {
      if (drama.id == anchor.id || drama.source != anchor.source) continue;
      final info = hongguoSeriesInfo(drama);
      if (info == null ||
          !hongguoSameSeries(anchor, drama) ||
          info.season != next ||
          (current != null && info.unit != current.unit)) {
        continue;
      }
      matches[drama.id] = drama;
    }
    return matches.values.toList();
  }

  /// 同季存在多个发行版本时，用简介相似度挑出唯一候选。
  /// 证据不足一律返回 null，由调用方继续抛歧义交还给用户，
  /// 避免把用户带到别的剧上。
  Drama? _disambiguate(Drama anchor, List<Drama> matches) {
    if (matches.length < 2) return null;
    final anchorShingles = _shingles(anchor.description);
    if (anchorShingles.isEmpty) return null;
    final scored = <_ScoredDrama>[];
    for (final drama in matches) {
      final shingles = _shingles(drama.description);
      scored.add(_ScoredDrama(drama, _jaccard(anchorShingles, shingles)));
    }
    scored.sort((left, right) => right.score.compareTo(left.score));
    final best = scored.first;
    final runnerUp = scored[1];
    if (best.score < _minimumDescriptionScore) return null;
    if (best.score - runnerUp.score < _minimumScoreMargin) return null;
    return best.drama;
  }

  static Set<String> _shingles(String text) {
    final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
    if (normalized.isEmpty) return <String>{};
    final runes = normalized.runes.toList();
    if (runes.length <= _shingleSize) return <String>{normalized};
    return <String>{
      for (var index = 0; index + _shingleSize <= runes.length; index++)
        String.fromCharCodes(runes.sublist(index, index + _shingleSize)),
    };
  }

  static double _jaccard(Set<String> left, Set<String> right) {
    if (left.isEmpty || right.isEmpty) return 0;
    final shared = left.intersection(right).length;
    final union = left.length + right.length - shared;
    if (union <= 0) return 0;
    return shared / union;
  }
}

const _shingleSize = 3;
const _minimumDescriptionScore = 0.35;
const _minimumScoreMargin = 0.12;
final _whitespacePattern = RegExp(r'\s+');

class _ScoredDrama {
  const _ScoredDrama(this.drama, this.score);

  final Drama drama;
  final double score;
}
