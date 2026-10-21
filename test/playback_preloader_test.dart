import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class PendingPreloadRepository extends FixtureRepository {
  final pending = <Completer<PlaybackPlan?>>[];
  final released = <String>[];
  int cancellations = 0;
  PlaybackPlan? cacheStatus;
  @override
  Future<PlaybackPlan> preloadStatus(Drama drama, PlaybackPlan plan) async =>
      cacheStatus ?? plan;

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final request = Completer<PlaybackPlan?>();
    pending.add(request);
    return request.future;
  }

  @override
  Future<void> cancelPreload() async {
    cancellations++;
  }

  @override
  Future<void> release(String session) async {
    released.add(session);
  }
}

void main() {
  final episode = Episode({'id': '2', 'currentEpisode': 2}, 2);
  PlaybackPlan plan(String session) => PlaybackPlan(
    url: 'https://example.test/$session.mp4',
    session: session,
    prefetchedBytes: 4 << 20,
  );

  testWidgets(
    'blocked source preload respects retryAt instead of retrying every three seconds',
    (tester) async {
      final repository = PendingPreloadRepository();
      var now = DateTime.utc(2026, 10, 20);
      final preloader = PlaybackPreloader(repository, now: () => now);
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending.single.completeError(
        AppFailure(
          '站源暂时限制访问',
          code: 'source_blocked',
          retryAt: now.add(const Duration(seconds: 60)),
        ),
      );
      await tester.pump();
      expect(preloader.status, '站源请求受限，60 秒后重试下一集');
      now = now.add(const Duration(seconds: 59));
      await tester.pump(const Duration(seconds: 59));
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump();
      expect(repository.pending, hasLength(1));
      expect(preloader.status, '站源请求受限，1 秒后重试下一集');
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(repository.pending, hasLength(2));
      preloader.dispose();
      expect(preloader.error, isEmpty);
      repository.pending.last.complete(null);
      await tester.pump();
    },
  );

  testWidgets(
    'startup readiness prepares media and taking transfers ownership',
    (tester) async {
      final repository = PendingPreloadRepository();
      final prepared = <String>[];
      final discarded = <String>[];
      final preloader = PlaybackPreloader(
        repository,
        onPrepared: (plan) => prepared.add(plan.session),
        onRelease: (plan) async => discarded.add(plan.session),
      );
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending.single.complete(
        const PlaybackPlan(
          url: 'file:///next.mp4',
          session: 'next',
          preloadState: 'caching',
        ),
      );
      await tester.pump();
      expect(prepared, isEmpty);
      repository.cacheStatus = const PlaybackPlan(
        url: 'file:///next.mp4',
        session: 'next',
        preloadState: 'caching',
        startupReady: true,
        mediaType: 'mp4',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(prepared, ['next']);
      final taken = preloader.take(FixtureRepository.free, episode);
      expect(taken?.startupReady, true);
      expect(taken?.mediaType, 'mp4');
      preloader.dispose();
      await tester.pump();
      expect(discarded, isEmpty);
      expect(repository.released, isEmpty);
    },
  );

  testWidgets('discard releases native prepared media before its session', (
    tester,
  ) async {
    final repository = PendingPreloadRepository();
    final cleared = Completer<void>();
    final preloader = PlaybackPreloader(
      repository,
      onRelease: (_) => cleared.future,
    );
    preloader.prepare(FixtureRepository.free, episode, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    repository.pending.single.complete(plan('unused'));
    await tester.pump();
    preloader.clear();
    await tester.pump();
    expect(repository.released, isEmpty);
    cleared.complete();
    await tester.pump();
    expect(repository.released, ['unused']);
    preloader.dispose();
  });

  testWidgets(
    'whole episode completion requires verified status and survives URL expiry',
    (tester) async {
      var now = DateTime(2026, 10, 9);
      final repository = PendingPreloadRepository();
      final preloader = PlaybackPreloader(repository, now: () => now);
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending.single.complete(
        PlaybackPlan(
          url: 'https://example.test/next.mp4',
          session: 'cached',
          preloadState: 'caching',
          expiresAt: now
              .add(const Duration(seconds: 10))
              .millisecondsSinceEpoch,
        ),
      );
      await tester.pump();
      expect(preloader.status, contains('缓冲中 0%'));
      repository.cacheStatus = const PlaybackPlan(
        url: 'https://example.test/next.mp4',
        session: 'cached',
        preloadState: 'retrying',
        prefetchedBytes: 1048576,
        preloadProgress: .25,
        preloadTotal: 4194304,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(preloader.status, contains('等待重试续传'));
      expect(preloader.status, isNot(contains('缓冲完成')));
      repository.cacheStatus = const PlaybackPlan(
        url: 'https://example.test/next.mp4',
        session: 'cached',
        preloadState: 'complete',
        preloadComplete: true,
        prefetchedBytes: 4194304,
        preloadTotal: 4194304,
        preloadProgress: 1,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(preloader.status, contains('整集缓冲完成'));
      now = now.add(const Duration(minutes: 5));
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump();
      expect(repository.pending, hasLength(1));
      expect(
        preloader.take(FixtureRepository.free, episode)?.preloadComplete,
        isTrue,
      );
      expect(repository.released, isEmpty);
      preloader.dispose();
    },
  );

  testWidgets(
    'completed buffering starts pending preparation immediately and refreshes expired plans',
    (tester) async {
      var now = DateTime(2026, 10, 3);
      final repository = PendingPreloadRepository();
      final preloader = PlaybackPreloader(repository, now: () => now);
      preloader.prepare(FixtureRepository.free, episode);
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.pending, isEmpty);
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(repository.pending, hasLength(1));
      repository.pending[0].complete(plan('first'));
      await tester.pump(const Duration(milliseconds: 1));
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(repository.pending, hasLength(1));
      now = now.add(const Duration(minutes: 2, seconds: 1));
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(repository.released, ['first']);
      expect(repository.pending, hasLength(2));
      repository.pending[1].complete(plan('fresh'));
      await tester.pump(const Duration(milliseconds: 1));
      expect(preloader.take(FixtureRepository.free, episode)?.session, 'fresh');
      preloader.dispose();
      expect(repository.released, ['first']);
    },
  );

  testWidgets(
    'cancelled preload returning late cannot release or replace the new ready plan',
    (tester) async {
      final repository = PendingPreloadRepository();
      final preloader = PlaybackPreloader(repository);
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      preloader.pause();
      expect(repository.cancellations, 1);
      preloader.prepare(FixtureRepository.free, episode, immediate: true);
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending[1].complete(plan('current'));
      await tester.pump(const Duration(milliseconds: 1));
      repository.pending[0].complete(plan('late'));
      await tester.pump(const Duration(milliseconds: 1));
      expect(repository.released, ['late']);
      expect(
        preloader.take(FixtureRepository.free, episode)?.session,
        'current',
      );
      preloader.dispose();
      expect(repository.released, ['late']);
    },
  );
}
