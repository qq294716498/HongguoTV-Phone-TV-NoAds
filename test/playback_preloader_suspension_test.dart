import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'playback_preloader_test.dart' show PendingPreloadRepository;

class SuspensionRepository extends PendingPreloadRepository {
  final controls = <(String, bool)>[];
  final heldControls = <(String, bool), Completer<void>>{};
  int activeControls = 0;
  int peakControls = 0;
  int statusCalls = 0;

  Completer<void> hold(String session, bool paused) =>
      heldControls[(session, paused)] = Completer<void>();

  @override
  Future<void> setPreloadPaused(
    Drama drama,
    PlaybackPlan plan,
    bool paused,
  ) async {
    controls.add((plan.session, paused));
    activeControls++;
    if (activeControls > peakControls) peakControls = activeControls;
    try {
      await heldControls.remove((plan.session, paused))?.future;
    } finally {
      activeControls--;
    }
  }

  @override
  Future<PlaybackPlan> preloadStatus(Drama drama, PlaybackPlan plan) async {
    statusCalls++;
    return super.preloadStatus(drama, plan);
  }
}

void main() {
  final next = Episode({'id': '2', 'currentEpisode': 2}, 2);
  final third = Episode({'id': '3', 'currentEpisode': 3}, 3);
  const drama = FixtureRepository.free;

  PlaybackPlan cached(
    String session, {
    int expiresAt = 0,
    bool complete = false,
  }) => PlaybackPlan(
    url: 'http://127.0.0.1:8765/$session/media.mp4',
    session: session,
    mediaType: 'mp4',
    preloadState: complete ? 'complete' : 'caching',
    preloadComplete: complete,
    startupReady: true,
    prefetchedBytes: 65536,
    expiresAt: expiresAt,
  );

  Future<void> ready(
    WidgetTester tester,
    PlaybackPreloader preloader,
    SuspensionRepository repository,
    PlaybackPlan plan,
  ) async {
    preloader.prepare(drama, next, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    repository.pending.last.complete(plan);
    await tester.pump();
  }

  testWidgets('suspension stops delayed work and resumes one target', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(drama, next);
    await preloader.setSuspended(true);
    await tester.pump(const Duration(seconds: 2));
    expect(repository.pending, isEmpty);
    expect(preloader.status, contains('优先当前播放'));
    await preloader.setSuspended(false);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.pending, hasLength(1));
    repository.pending.single.complete(cached('delayed'));
    await tester.pump();
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('ready cache is paused without release, polling or preparation', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final prepared = <String>[];
    final platform = <bool>[];
    final preloader = PlaybackPreloader(
      repository,
      onPrepared: (plan) => prepared.add(plan.session),
      onSuspended: (paused) async => platform.add(paused),
    );
    await ready(tester, preloader, repository, cached('kept'));
    expect(prepared, ['kept']);
    await preloader.setSuspended(true);
    await tester.pump(const Duration(seconds: 5));
    preloader.prepare(drama, next, immediate: true);
    await tester.pump();
    expect(preloader.hasReady, isTrue);
    expect(preloader.readyPlan?.session, 'kept');
    expect(repository.controls, [('kept', true)]);
    expect(repository.released, isEmpty);
    expect(repository.cancellations, 0);
    expect(repository.statusCalls, 0);
    expect(prepared, ['kept']);
    await preloader.setSuspended(false);
    await tester.pump();
    expect(repository.controls, [('kept', true), ('kept', false)]);
    expect(platform, [true, false]);
    expect(prepared, ['kept', 'kept']);
    expect(repository.pending, hasLength(1));
    preloader.dispose();
    await tester.pump();
    expect(repository.released, ['kept']);
  });

  testWidgets('late resolve is paused before native preparation is allowed', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final prepared = <String>[];
    final preloader = PlaybackPreloader(
      repository,
      onPrepared: (plan) => prepared.add(plan.session),
    );
    preloader.prepare(drama, next, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    await preloader.setSuspended(true);
    repository.pending.single.complete(cached('late'));
    await tester.pump();
    expect(repository.controls, [('late', true)]);
    expect(prepared, isEmpty);
    expect(repository.released, isEmpty);
    expect(repository.cancellations, 0);
    await preloader.setSuspended(false);
    await tester.pump();
    expect(repository.controls, [('late', true), ('late', false)]);
    expect(prepared, ['late']);
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('pause and resume RPCs stay serialized through acknowledgement', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final prepared = <String>[];
    final preloader = PlaybackPreloader(
      repository,
      onPrepared: (plan) => prepared.add(plan.session),
    );
    await ready(tester, preloader, repository, cached('serial'));
    prepared.clear();
    final held = repository.hold('serial', true);
    final pausing = preloader.setSuspended(true);
    final resuming = preloader.setSuspended(false);
    await tester.pump();
    expect(repository.controls, [('serial', true)]);
    expect(prepared, isEmpty);
    held.complete();
    await tester.pump();
    await pausing;
    await resuming;
    expect(repository.controls, [('serial', true), ('serial', false)]);
    expect(repository.peakControls, 1);
    expect(prepared, ['serial']);
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('clearing during an old pause cannot control the new session', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    await ready(tester, preloader, repository, cached('old'));
    final held = repository.hold('old', true);
    final pausing = preloader.setSuspended(true);
    await tester.pump();
    preloader.clear();
    await tester.pump();
    expect(repository.released, ['old']);
    await preloader.setSuspended(false);
    preloader.prepare(drama, third, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    repository.pending.last.complete(cached('new'));
    await tester.pump();
    held.complete();
    await tester.pump();
    await pausing;
    expect(preloader.readyPlan?.session, 'new');
    expect(repository.controls, [('old', true)]);
    expect(repository.released, ['old']);
    expect(preloader.take(drama, third)?.session, 'new');
    preloader.dispose();
    await tester.pump();
    expect(repository.released, ['old']);
  });

  testWidgets('handoff resumes the same session before transferring it', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    await ready(tester, preloader, repository, cached('handoff'));
    await preloader.setSuspended(true);
    expect(preloader.take(drama, next), isNull);
    expect(preloader.readyPlan?.session, 'handoff');
    final held = repository.hold('handoff', false);
    var delivered = false;
    final taken = preloader.takeWhenReady(drama, next).then((plan) {
      delivered = true;
      return plan;
    });
    preloader.clear();
    await tester.pump();
    expect(delivered, isFalse);
    expect(repository.controls, [('handoff', true), ('handoff', false)]);
    expect(repository.released, isEmpty);
    held.complete();
    await tester.pump();
    final plan = await taken;
    expect(plan?.session, 'handoff');
    expect(repository.pending, hasLength(1));
    preloader.dispose();
    await tester.pump();
    expect(repository.released, isEmpty);
    await repository.release(plan!.session);
  });

  testWidgets('timed out resume returns no plan and releases it once', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    await ready(tester, preloader, repository, cached('timeout'));
    await preloader.setSuspended(true);
    final held = repository.hold('timeout', false);
    final taken = preloader.takeWhenReady(drama, next);
    await tester.pump(const Duration(milliseconds: 1201));
    expect(await taken, isNull);
    await tester.pump();
    expect(repository.released, ['timeout']);
    held.complete();
    await tester.pump();
    preloader.dispose();
    await tester.pump();
    expect(repository.released, ['timeout']);
  });

  testWidgets(
    'dispose releases a claimed session while its resume is pending',
    (tester) async {
      final repository = SuspensionRepository();
      final preloader = PlaybackPreloader(repository);
      await ready(tester, preloader, repository, cached('closing'));
      await preloader.setSuspended(true);
      final held = repository.hold('closing', false);
      final taken = preloader.takeWhenReady(drama, next);
      await tester.pump();
      preloader.dispose();
      await tester.pump();
      expect(repository.released, ['closing']);
      held.complete();
      await tester.pump();
      expect(await taken, isNull);
      expect(repository.released, ['closing']);
    },
  );

  testWidgets('suspension does not extend authorization lifetime', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    var now = DateTime.utc(2026, 10, 31);
    final preloader = PlaybackPreloader(repository, now: () => now);
    await ready(
      tester,
      preloader,
      repository,
      cached(
        'expired',
        expiresAt: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
      ),
    );
    await preloader.setSuspended(true);
    now = now.add(const Duration(seconds: 20));
    final taken = preloader.takeWhenReady(drama, next);
    await tester.pump();
    expect(await taken, isNull);
    expect(repository.controls, [('expired', true)]);
    expect(repository.statusCalls, 1);
    expect(repository.released, ['expired']);
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('a verified cache survives authorization expiry while paused', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    var now = DateTime.utc(2026, 10, 31);
    final preloader = PlaybackPreloader(repository, now: () => now);
    await ready(
      tester,
      preloader,
      repository,
      cached(
        'complete',
        expiresAt: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
      ),
    );
    await preloader.setSuspended(true);
    repository.cacheStatus = cached('complete', complete: true);
    now = now.add(const Duration(seconds: 20));
    final taken = preloader.takeWhenReady(drama, next);
    await tester.pump();
    expect((await taken)?.preloadComplete, isTrue);
    expect(repository.released, isEmpty);
    expect(repository.pending, hasLength(1));
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('source retryAt remains authoritative across suspension', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    var now = DateTime.utc(2026, 10, 31);
    final preloader = PlaybackPreloader(repository, now: () => now);
    preloader.prepare(drama, next, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    repository.pending.single.completeError(
      AppFailure(
        'blocked',
        code: 'source_blocked',
        retryAt: now.add(const Duration(seconds: 60)),
      ),
    );
    await tester.pump();
    await preloader.setSuspended(true);
    now = now.add(const Duration(seconds: 59));
    await tester.pump(const Duration(seconds: 59));
    await preloader.setSuspended(false);
    await tester.pump();
    expect(repository.pending, hasLength(1));
    expect(preloader.status, contains('1 秒'));
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(repository.pending, hasLength(2));
    repository.pending.last.complete(cached('after-cooldown'));
    await tester.pump();
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('failed pause releases unsafe producer and keeps suspension', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    await ready(tester, preloader, repository, cached('failed'));
    final held = repository.hold('failed', true);
    final pausing = preloader.setSuspended(true);
    final checked = expectLater(pausing, throwsA(isA<AppFailure>()));
    await tester.pump();
    held.completeError(AppFailure('cannot pause'));
    await tester.pump();
    await checked;
    expect(preloader.suspended, isTrue);
    expect(preloader.readyPlan, isNull);
    expect(repository.released, ['failed']);
    await tester.pump(const Duration(seconds: 10));
    expect(repository.pending, hasLength(1));
    preloader.dispose();
    await tester.pump();
  });

  testWidgets('repeated suspension does not repeat controls or notifications', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final platform = <bool>[];
    final preloader = PlaybackPreloader(
      repository,
      onSuspended: (paused) async => platform.add(paused),
    );
    await ready(tester, preloader, repository, cached('dedup'));
    var notifications = 0;
    preloader.addListener(() => notifications++);
    await preloader.setSuspended(true);
    final count = notifications;
    for (var attempt = 0; attempt < 20; attempt++) {
      await preloader.setSuspended(true);
    }
    expect(repository.controls, [('dedup', true)]);
    expect(platform, [true]);
    expect(notifications, count);
    preloader.dispose();
    await tester.pump();
  });

  testWidgets(
    'verified local cache coordinates renderer but needs no producer RPC',
    (tester) async {
      final repository = SuspensionRepository();
      final platform = <bool>[];
      final preloader = PlaybackPreloader(
        repository,
        onSuspended: (paused) async => platform.add(paused),
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('verified', complete: true),
      );
      await preloader.setSuspended(true);
      await preloader.setSuspended(false);
      expect(platform, [true, false]);
      expect(repository.controls, isEmpty);
      expect(preloader.readyPlan?.session, 'verified');
      preloader.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'activation inside suspension transfers lease before queued controls',
    (tester) async {
      final repository = SuspensionRepository();
      final platform = <bool>[];
      PlaybackPreloadLease? lease;
      late final PlaybackPreloader preloader;
      preloader = PlaybackPreloader(
        repository,
        onSuspended: (paused) async {
          platform.add(paused);
          if (paused) lease = preloader.claimActivated(drama, next);
        },
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('activated', complete: true),
      );
      final pausing = preloader.setSuspended(true);
      await tester.pump();
      await pausing;
      expect(lease?.plan.session, 'activated');
      await lease!.resumed;
      expect(platform, [true, false]);
      expect(repository.controls, isEmpty);
      preloader.clear();
      preloader.dispose();
      await tester.pump();
      expect(repository.released, isEmpty);
      await repository.release(lease!.plan.session);
    },
  );

  testWidgets(
    'an activation waits for an already sent platform pause then resumes',
    (tester) async {
      final repository = SuspensionRepository();
      final held = Completer<void>();
      final platform = <bool>[];
      final preloader = PlaybackPreloader(
        repository,
        onSuspended: (paused) async {
          platform.add(paused);
          if (paused) await held.future;
        },
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('selected', complete: true),
      );
      final pausing = preloader.setSuspended(true);
      await tester.pump();
      final lease = preloader.claimActivated(drama, next)!;
      var resumed = false;
      final confirmed = lease.resumed.then((_) => resumed = true);
      preloader.clear();
      await tester.pump();
      expect(resumed, isFalse);
      expect(platform, [true]);
      expect(repository.released, isEmpty);
      held.complete();
      await tester.pump();
      await pausing;
      await confirmed;
      expect(platform, [true, false]);
      expect(repository.released, isEmpty);
      preloader.dispose();
      await tester.pump();
      expect(repository.released, isEmpty);
      await repository.release(lease.plan.session);
    },
  );

  testWidgets('failed activated resume never deletes externally held media', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(
      repository,
      onSuspended: (paused) async {
        if (!paused) throw AppFailure('native resume failed');
      },
    );
    await ready(
      tester,
      preloader,
      repository,
      cached('external', complete: true),
    );
    await preloader.setSuspended(true);
    final lease = preloader.claimActivated(drama, next)!;
    final checked = expectLater(lease.resumed, throwsA(isA<AppFailure>()));
    preloader.clear();
    await tester.pump();
    await checked;
    preloader.dispose();
    await tester.pump();
    expect(repository.released, isEmpty);
    await repository.release(lease.plan.session);
    expect(repository.released, ['external']);
  });

  testWidgets(
    'activated resume failure remains observable after delayed subscription',
    (tester) async {
      final repository = SuspensionRepository();
      final preloader = PlaybackPreloader(
        repository,
        onSuspended: (paused) async {
          if (!paused) throw AppFailure('delayed observer');
        },
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('observed-later', complete: true),
      );
      await preloader.setSuspended(true);
      final lease = preloader.claimActivated(drama, next)!;
      await tester.pump();
      expect(repository.released, isEmpty);
      await expectLater(lease.resumed, throwsA(isA<AppFailure>()));
      preloader.dispose();
      await tester.pump();
      expect(repository.released, isEmpty);
      await repository.release(lease.plan.session);
    },
  );

  testWidgets(
    'disposing during activated acknowledgement never reclaims its lease',
    (tester) async {
      final repository = SuspensionRepository();
      final held = Completer<void>();
      final preloader = PlaybackPreloader(
        repository,
        onSuspended: (paused) async {
          if (paused) await held.future;
        },
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('leaving-active', complete: true),
      );
      final pausing = preloader.setSuspended(true);
      await tester.pump();
      final lease = preloader.claimActivated(drama, next)!;
      final failed = expectLater(lease.resumed, throwsA(isA<Exception>()));
      preloader.clear();
      preloader.dispose();
      await tester.pump();
      expect(repository.released, isEmpty);
      held.complete();
      await tester.pump();
      await pausing;
      await failed;
      expect(repository.released, isEmpty);
      await repository.release(lease.plan.session);
    },
  );

  testWidgets(
    'a failed native resume backs off without clearing the partial cache',
    (tester) async {
      final repository = SuspensionRepository();
      var now = DateTime.utc(2026, 10, 31);
      final preloader = PlaybackPreloader(repository, now: () => now);
      await ready(tester, preloader, repository, cached('retry-resume'));
      await preloader.setSuspended(true);
      final held = repository.hold('retry-resume', false);
      final resuming = preloader.setSuspended(false);
      final failed = expectLater(resuming, throwsA(isA<AppFailure>()));
      await tester.pump();
      held.completeError(AppFailure('temporary resume failure'));
      await tester.pump();
      await failed;
      for (var attempt = 0; attempt < 10; attempt++) {
        await expectLater(
          preloader.setSuspended(false),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(repository.controls, [
        ('retry-resume', true),
        ('retry-resume', false),
      ]);
      expect(repository.released, isEmpty);
      expect(preloader.take(drama, next), isNull);
      now = now.add(const Duration(seconds: 3));
      await preloader.setSuspended(false);
      expect(repository.controls, [
        ('retry-resume', true),
        ('retry-resume', false),
        ('retry-resume', false),
      ]);
      expect(preloader.take(drama, next)?.session, 'retry-resume');
      preloader.dispose();
      await tester.pump();
      expect(repository.released, isEmpty);
    },
  );

  testWidgets(
    'activation rejects partial or mismatched media without losing ownership',
    (tester) async {
      final repository = SuspensionRepository();
      final preloader = PlaybackPreloader(repository);
      await ready(tester, preloader, repository, cached('partial'));
      expect(preloader.claimActivated(drama, next), isNull);
      expect(preloader.claimActivated(drama, third), isNull);
      expect(preloader.readyPlan?.session, 'partial');
      expect(repository.released, isEmpty);
      preloader.dispose();
      await tester.pump();
      expect(repository.released, ['partial']);
    },
  );

  testWidgets(
    'resume failures are throttled and cannot prepare through a paused renderer',
    (tester) async {
      final repository = SuspensionRepository();
      var now = DateTime.utc(2026, 10, 31);
      final prepared = <String>[];
      var resumeFails = true;
      var attempts = 0;
      final preloader = PlaybackPreloader(
        repository,
        now: () => now,
        onPrepared: (plan) => prepared.add(plan.session),
        onSuspended: (paused) async {
          if (!paused) {
            attempts++;
            if (resumeFails) throw AppFailure('renderer busy');
          }
        },
      );
      await ready(
        tester,
        preloader,
        repository,
        cached('renderer', complete: true),
      );
      await preloader.setSuspended(true);
      await expectLater(
        preloader.setSuspended(false),
        throwsA(isA<AppFailure>()),
      );
      for (var attempt = 0; attempt < 10; attempt++) {
        preloader.prepare(drama, next, immediate: true);
        await expectLater(
          preloader.setSuspended(false),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(attempts, 1);
      expect(prepared, ['renderer']);
      expect(preloader.take(drama, next), isNull);
      now = now.add(const Duration(seconds: 3));
      resumeFails = false;
      await preloader.setSuspended(false);
      expect(attempts, 2);
      expect(prepared, ['renderer', 'renderer']);
      preloader.dispose();
      await tester.pump();
    },
  );

  testWidgets('same drama id cannot transfer a different source session', (
    tester,
  ) async {
    final repository = SuspensionRepository();
    final preloader = PlaybackPreloader(repository);
    await ready(
      tester,
      preloader,
      repository,
      cached('original', complete: true),
    );
    final changedSource = Drama(
      id: drama.id,
      source: 'huangdou',
      title: drama.title,
    );
    final changedSourceId = Drama(
      id: drama.id,
      source: drama.source,
      sourceId: 'alternate-origin',
      title: drama.title,
    );
    expect(preloader.claimActivated(changedSource, next), isNull);
    expect(preloader.claimActivated(changedSourceId, next), isNull);
    expect(preloader.readyPlan?.session, 'original');
    preloader.prepare(changedSource, next, immediate: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.released, ['original']);
    expect(repository.pending, hasLength(2));
    repository.pending.last.complete(cached('changed', complete: true));
    await tester.pump();
    expect(preloader.claimActivated(drama, next), isNull);
    final taken = await preloader.takeWhenReady(changedSource, next);
    expect(taken?.session, 'changed');
    preloader.dispose();
    await tester.pump();
    expect(repository.released, ['original']);
    await repository.release(taken!.session);
  });

  test(
    'native pause command uses playback session and existing source authorization',
    () async {
      final calls = <Map<String, dynamic>>[];
      final repository = NativeRepository.test(
        transport: (input) async {
          calls.add(Map.of(input));
          return {'ok': true, 'data': {}};
        },
      );
      await repository.setPreloadPaused(drama, cached('native'), true);
      await repository.setPreloadPaused(drama, cached('native'), false);
      expect(calls.map((call) => call['paused']), [true, false]);
      expect(
        calls.every((call) => call['action'] == 'setPreloadPaused'),
        isTrue,
      );
      expect(
        calls.every((call) => call['playbackSession'] == 'native'),
        isTrue,
      );
      expect(
        calls.every((call) => (call['drama'] as Map)['source'] == 'hongguo'),
        isTrue,
      );
      expect(
        calls.every(
          (call) =>
              !call.containsKey('session') && !call.containsKey('sequence'),
        ),
        isTrue,
      );
    },
  );

  test(
    'profile changes reject control replies without deleting an existing lease',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = testStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.saveProfile(
        id: 'default',
        name: 'admin',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.saveProfile(
        name: 'other',
        sources: ['hongguo'],
        download: false,
      );
      final reply = Completer<Map<String, dynamic>>();
      final calls = <String>[];
      final repository = NativeRepository.test(
        transport: (input) async {
          calls.add(input['action'] as String);
          if (input['action'] == 'setPreloadPaused') return reply.future;
          return {'ok': true, 'data': {}};
        },
      )..access = store;
      final pending = repository.setPreloadPaused(
        drama,
        cached('existing'),
        false,
      );
      final failed = expectLater(pending, throwsA(isA<AppFailure>()));
      await store.switchProfile(
        store.profiles.firstWhere((profile) => !profile.admin).id,
      );
      reply.complete({
        'ok': true,
        'data': {'session': 'existing'},
      });
      await failed;
      expect(calls, ['setPreloadPaused']);
      await repository.release('existing');
      expect(calls, ['setPreloadPaused', 'release']);
    },
  );

  test('a source-denied profile cannot issue pause controls', () async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.saveProfile(
      id: 'default',
      name: 'admin',
      sources: [],
      download: true,
      pin: 'abcdef12',
    );
    await store.saveProfile(name: 'no-source', sources: [], download: false);
    await store.switchProfile(
      store.profiles.firstWhere((profile) => !profile.admin).id,
    );
    var calls = 0;
    final repository = NativeRepository.test(
      transport: (_) async {
        calls++;
        return {'ok': true, 'data': {}};
      },
    )..access = store;
    await expectLater(
      repository.setPreloadPaused(drama, cached('denied'), true),
      throwsA(isA<AppFailure>()),
    );
    expect(calls, 0);
  });
}
