import 'dart:async';

import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';

class NextSeasonLookupResult {
  const NextSeasonLookupResult({
    required this.anchor,
    required this.candidates,
    required this.next,
    required this.complete,
    this.warning = '',
    this.ambiguous = false,
    this.detail,
  });

  final Drama anchor;
  final List<Drama> candidates;
  final Drama? next;
  final bool complete;
  final String warning;
  final bool ambiguous;
  final DramaDetail? detail;
}

class NextSeasonResolver {
  const NextSeasonResolver(
    this.repository, {
    this.lookupBudget = const Duration(seconds: 30),
    this.requestBudget = const Duration(seconds: 10),
  });

  final AppRepository repository;
  final Duration lookupBudget;
  final Duration requestBudget;

  Future<NextSeasonLookupResult> lookup(
    Drama anchor, {
    required Iterable<Drama> knownDramas,
    required bool Function() isCurrent,
    bool trustKnownNext = true,
    bool force = false,
  }) async {
    if (anchor.source != SourceSite.hongguo.id ||
        normalizedSearchText(anchor.title).isEmpty) {
      return NextSeasonLookupResult(
        anchor: anchor,
        candidates: const [],
        next: null,
        complete: false,
        warning: '当前剧集缺少可核实的续季信息',
      );
    }
    if (trustKnownNext && !force) {
      for (final cached in knownDramas) {
        if (cached.id == anchor.id && cached.source == anchor.source) {
          anchor = cached.merge(anchor);
        }
      }
    }
    final session = repository.seasonLookup();
    final deadline = DateTime.now().add(lookupBudget);
    final candidates = <String, Drama>{
      if (trustKnownNext && !force)
        for (final drama in knownDramas)
          if (drama.id != anchor.id) drama.id: drama,
    };
    final metadataAttempted = <String>{};
    final detailAttempted = <String>{};
    final details = <String, DramaDetail>{};
    final rejected = <String>{};
    var incomplete = false;
    var warning = '';

    void checkCurrent() {
      if (!isCurrent()) {
        throw AppFailure('下一季续播已取消', code: 'next_season_cancelled');
      }
    }

    Future<T> bounded<T>(Future<T> Function() request) async {
      checkCurrent();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('续季查询超时');
      final timeout = remaining < requestBudget ? remaining : requestBudget;
      late T value;
      try {
        value = await request().timeout(timeout);
      } on TimeoutException {
        await session.cancelPending();
        rethrow;
      }
      checkCurrent();
      return value;
    }

    void failed(Object error) {
      checkCurrent();
      if (error is AppFailure &&
          (error.code == 'source_blocked' ||
              error.code == 'next_season_cancelled')) {
        throw error;
      }
      incomplete = true;
      warning = '部分续季信息暂未能核实，请稍后重试';
    }

    Future<Drama> metadata(Drama drama) async {
      if (drama.seriesGroupId.isNotEmpty || !metadataAttempted.add(drama.id)) {
        return drama;
      }
      try {
        final fresh = await bounded(() => session.metadata(drama));
        if (fresh == null) return drama;
        if (fresh.id != drama.id || fresh.source != drama.source) {
          throw AppFailure('续季元数据身份不一致', code: 'next_season_ambiguous');
        }
        return drama.merge(fresh);
      } catch (error) {
        failed(error);
        return drama;
      }
    }

    Future<Drama> withDetail(Drama drama) async {
      if (!detailAttempted.add(drama.id)) return drama;
      try {
        final detail = await bounded(() => session.detail(drama));
        if (detail.drama.id != drama.id ||
            detail.drama.source != drama.source) {
          throw AppFailure('下一季信息不一致，请手动选择', code: 'next_season_ambiguous');
        }
        final merged = drama.merge(detail.drama);
        details[drama.id] = DramaDetail(
          merged,
          detail.episodes,
          warning: detail.warning,
          hasMoreEpisodes: detail.hasMoreEpisodes,
        );
        return merged;
      } catch (error) {
        if (error is AppFailure && error.code == 'next_season_ambiguous') {
          rethrow;
        }
        failed(error);
        return drama;
      }
    }

    bool consecutive(Drama drama) {
      if (drama.id == anchor.id || drama.source != anchor.source) return false;
      final current = hongguoSeriesInfo(anchor);
      final info = hongguoSeriesInfo(drama);
      return info != null &&
          info.season == (current?.season ?? 1) + 1 &&
          (current == null || info.unit == current.unit);
    }

    bool potential(Drama drama) {
      if (!consecutive(drama) || rejected.contains(drama.id)) return false;
      if (anchor.seriesGroupId.isNotEmpty && drama.seriesGroupId.isNotEmpty) {
        return anchor.seriesGroupId == drama.seriesGroupId;
      }
      return hongguoSimilarSeriesTitles(anchor, drama) ||
          anchor.seriesGroupId.isEmpty && drama.seriesGroupId.isNotEmpty;
    }

    bool mismatchedGroups(Drama drama) =>
        anchor.seriesGroupId.isNotEmpty &&
        drama.seriesGroupId.isNotEmpty &&
        anchor.seriesGroupId != drama.seriesGroupId;

    NextSeasonLookupResult result({
      Drama? next,
      DramaDetail? detail,
      bool complete = false,
      bool ambiguous = false,
    }) => NextSeasonLookupResult(
      anchor: anchor,
      candidates: List.unmodifiable([anchor, ...candidates.values]),
      next: next,
      detail: detail,
      complete: complete,
      warning: warning,
      ambiguous: ambiguous,
    );

    Future<NextSeasonLookupResult?> verifiedNext() async {
      checkCurrent();
      final nearby = candidates.values.where(potential).toList();
      if (nearby.isEmpty) return null;
      if (nearby.length > 4) {
        incomplete = true;
        warning = '续季候选较多，请手动确认';
      }
      for (var drama in nearby.take(4)) {
        if (mismatchedGroups(drama)) {
          rejected.add(drama.id);
          continue;
        }
        if (!hongguoVerifiedSameSeries(anchor, drama)) {
          drama = await metadata(drama);
          if (!mismatchedGroups(drama) &&
              !hongguoVerifiedSameSeries(anchor, drama) &&
              anchor.seriesGroupId.isEmpty) {
            anchor = await metadata(anchor);
          }
          candidates[drama.id] = drama;
          if (mismatchedGroups(drama)) {
            rejected.add(drama.id);
            continue;
          }
          if (!hongguoVerifiedSameSeries(anchor, drama)) {
            if (hongguoSeriesCharacters(anchor.description).isEmpty &&
                anchor.seriesGroupId.isEmpty) {
              anchor = await withDetail(anchor);
            }
            if (mismatchedGroups(drama)) {
              rejected.add(drama.id);
              continue;
            }
            if (!hongguoVerifiedSameSeries(anchor, drama)) {
              drama = await withDetail(drama);
            }
          }
          candidates[drama.id] = drama;
        }
        if (!consecutive(drama)) {
          rejected.add(drama.id);
        } else if (!hongguoVerifiedSameSeries(anchor, drama)) {
          final left = hongguoSeriesCharacters(anchor.description);
          final right = hongguoSeriesCharacters(drama.description);
          if (mismatchedGroups(drama) || left.isNotEmpty && right.isNotEmpty) {
            rejected.add(drama.id);
          } else {
            incomplete = true;
            warning = '续季候选缺少足够的关联依据，请手动确认';
          }
        }
      }
      var matches = candidates.values
          .where(
            (drama) =>
                potential(drama) && hongguoVerifiedSameSeries(anchor, drama),
          )
          .toList();
      if (matches.isEmpty) return null;
      if (nearby.length > 4) return result(ambiguous: true);
      if (matches.length > 1) {
        final narrowed = _disambiguate(anchor, matches);
        if (narrowed == null) return result(ambiguous: true);
        matches = [narrowed];
      }
      var candidate = matches.single;
      candidate = await withDetail(candidate);
      candidates[candidate.id] = candidate;
      final detail = details[candidate.id];
      if (detail == null) return null;
      if (!consecutive(candidate) ||
          !hongguoVerifiedSameSeries(anchor, candidate)) {
        rejected.add(candidate.id);
        incomplete = true;
        warning = '下一季信息不一致，请手动选择';
        return null;
      }
      if (detail.episodes.isEmpty) {
        throw AppFailure('下一季暂时没有可播放的集数', code: 'next_season_empty');
      }
      if (detail.warning.isNotEmpty) {
        incomplete = true;
        warning = detail.warning;
      }
      return result(next: candidate, detail: detail);
    }

    try {
      checkCurrent();
      final known = await verifiedNext();
      if (known != null) return known;
      final generated = hongguoNextSeasonQueries(anchor);
      final current = hongguoSeriesInfo(anchor);
      final next = (current?.season ?? 1) + 1;
      final numeric = RegExp(
        r'(?:第\s*)?'
        '$next'
        r'(?:季|部|$)',
      );
      final targeted = <String>{
        ...generated.where((query) => numeric.hasMatch(query)),
        ...generated,
      }.take(2);
      final broad = current?.baseTitle ?? anchor.title.trim();
      final queries = <String>{
        ...targeted,
        broad,
      }.where((query) => normalizedSearchText(query).isNotEmpty);
      for (final query in queries) {
        var exhausted = false;
        for (var page = 1; page <= 3; page++) {
          checkCurrent();
          CatalogPage response;
          try {
            response = await bounded(
              () => session.catalog(
                anchor.source,
                query: query,
                page: page,
                force: force && page == 1,
              ),
            );
          } catch (error) {
            failed(error);
            break;
          }
          for (final fresh in response.items) {
            if (fresh.source != anchor.source) continue;
            if (fresh.id == anchor.id) {
              anchor = anchor.merge(fresh);
            } else {
              candidates[fresh.id] =
                  candidates[fresh.id]?.merge(fresh) ?? fresh;
            }
          }
          if (response.warning.isNotEmpty) {
            incomplete = true;
            warning = response.warning;
          }
          final found = await verifiedNext();
          if (found != null) return found;
          if (!response.hasMore) {
            exhausted = true;
            break;
          }
          if (response.warning.isNotEmpty) break;
        }
        if (!exhausted) incomplete = true;
      }
      checkCurrent();
      return result(complete: !incomplete);
    } finally {
      await session.dispose();
    }
  }

  Future<DramaDetail?> resolve(
    Drama anchor, {
    required Iterable<Drama> knownDramas,
    required bool Function() isCurrent,
  }) async {
    if (anchor.source != SourceSite.hongguo.id) return null;
    final result = await lookup(
      anchor,
      knownDramas: knownDramas,
      isCurrent: isCurrent,
    ).timeout(const Duration(seconds: 45));
    if (!isCurrent()) {
      throw AppFailure('下一季续播已取消', code: 'next_season_cancelled');
    }
    if (result.ambiguous) {
      throw AppFailure('找到多个下一季版本，请手动选择', code: 'next_season_ambiguous');
    }
    final detail = result.detail;
    if (result.next == null || detail == null) {
      if (!result.complete) {
        throw AppFailure(
          result.warning.isEmpty ? '续季信息尚未能完整核实，请稍后重试' : result.warning,
          code: 'next_season_incomplete',
        );
      }
      return null;
    }
    if (detail.episodes.first.vip) {
      throw AppFailure('下一季首集为 VIP 内容，请手动选择后确认试看', code: 'next_season_vip');
    }
    final merged = repository.catalogUpdates
        .current(result.next!)
        .merge(detail.drama);
    return DramaDetail(
      merged,
      detail.episodes,
      warning: detail.warning,
      hasMoreEpisodes: detail.hasMoreEpisodes,
    );
  }

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
