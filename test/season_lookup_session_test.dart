import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const sessionDrama = Drama(
  id: 'hongguo:123',
  source: 'hongguo',
  title: '合成第一季',
);

Matcher get sessionCancelled => throwsA(
  isA<AppFailure>().having(
    (failure) => failure.code,
    'code',
    'next_season_cancelled',
  ),
);

class SessionRead {
  SessionRead(this.input);
  final Map<String, dynamic> input;
  final done = Completer<Map<String, dynamic>>();
  String get session => input['session'] as String;
  int get sequence => input['sequence'] as int;
  void complete(Map<String, dynamic> data) =>
      done.complete({'ok': true, 'data': data});
}

class SessionTransport {
  final reads = <SessionRead>[];
  final cancelled = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> call(Map<String, dynamic> input) {
    if (input['action'] == 'cancelRead') {
      cancelled.add(Map.of(input));
      return Future.value({'ok': true, 'data': true});
    }
    final read = SessionRead(Map.of(input));
    reads.add(read);
    return read.done.future;
  }

  Future<void> waitFor(int count) async {
    for (var tick = 0; tick < 20 && reads.length < count; tick++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(reads.length, count);
  }
}

class SessionFixture extends FixtureRepository {
  @override
  Future<Drama?> supplementMetadata(Drama drama) async => drama.merge(
    Drama(
      id: drama.id,
      source: drama.source,
      title: drama.title,
      seriesGroupId: '100',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default sessions adapt existing repositories and reject closed work',
    () async {
      final repository = SessionFixture();
      final session = repository.seasonLookup();
      await session.catalog('hongguo', page: 2, query: '合成', force: false);
      expect(repository.pages, [2]);
      expect(repository.forced, [false]);
      expect((await session.metadata(sessionDrama))!.seriesGroupId, '100');
      expect((await session.detail(sessionDrama)).drama.id, sessionDrama.id);
      await session.dispose();
      await session.dispose();
      await expectLater(session.catalog('hongguo'), sessionCancelled);
      await expectLater(session.metadata(sessionDrama), sessionCancelled);
      await expectLater(session.detail(sessionDrama), sessionCancelled);
      expect(repository.pages, [2]);
    },
  );

  test(
    'ordinary catalog cancellation leaves both season sessions isolated',
    () async {
      final transport = SessionTransport();
      final repository = NativeRepository.test(transport: transport.call);
      final first = repository.seasonLookup();
      final second = repository.seasonLookup();
      final oldFirst = first.catalog('hongguo', query: '第一组');
      final oldFirstCheck = expectLater(oldFirst, sessionCancelled);
      final peer = second.catalog('hongguo', query: '第二组');
      final ordinary = repository.catalog('hongguo', query: '普通搜索');
      await transport.waitFor(3);
      expect(transport.reads.map((read) => read.session).toSet(), hasLength(3));
      expect(transport.reads[0].session, endsWith(':season-0-catalog'));
      expect(transport.reads[1].session, endsWith(':season-1-catalog'));
      expect(transport.reads[2].session, endsWith(':catalog-hongguo'));
      await repository.cancelCatalog();
      expect(transport.cancelled.single['session'], transport.reads[2].session);
      transport.reads[2].complete({'items': []});
      await ordinary;
      await first.cancelPending();
      expect(transport.cancelled.last['session'], transport.reads[0].session);
      expect(transport.cancelled, hasLength(2));
      transport.reads[1].complete({'items': []});
      await peer;
      transport.reads[0].complete({'items': []});
      await oldFirstCheck;
      final resumed = first.catalog('hongguo', query: '有限回退');
      await transport.waitFor(4);
      expect(transport.reads[3].session, transport.reads[0].session);
      expect(
        transport.reads[3].sequence,
        greaterThan(transport.reads[0].sequence),
      );
      transport.reads[3].complete({'items': []});
      await resumed;
      await first.dispose();
      await second.dispose();
    },
  );

  test(
    'disposal cancels all owned read kinds and ignores late replies',
    () async {
      final transport = SessionTransport();
      final repository = NativeRepository.test(transport: transport.call);
      final first = repository.seasonLookup();
      final second = repository.seasonLookup();
      final catalog = first.catalog('hongguo');
      final metadata = first.metadata(sessionDrama);
      final detail = first.detail(sessionDrama);
      final cancelledChecks = [
        expectLater(catalog, sessionCancelled),
        expectLater(metadata, sessionCancelled),
        expectLater(detail, sessionCancelled),
      ];
      final peer = second.metadata(sessionDrama);
      await transport.waitFor(4);
      await first.dispose();
      await first.dispose();
      expect(transport.cancelled, hasLength(3));
      expect(
        transport.cancelled.map((read) => read['session']).toSet(),
        transport.reads.take(3).map((read) => read.session).toSet(),
      );
      transport.reads[0].complete({'items': []});
      transport.reads[1].complete({'drama': sessionDrama.toJson()});
      transport.reads[2].complete({
        'drama': sessionDrama.toJson(),
        'chapters': [],
      });
      await Future.wait(cancelledChecks);
      transport.reads[3].complete({'drama': sessionDrama.toJson()});
      expect((await peer)!.id, sessionDrama.id);
      final replacement = repository.seasonLookup();
      final next = replacement.catalog('hongguo');
      await transport.waitFor(5);
      expect(transport.reads.last.session, transport.reads.first.session);
      await first.cancelPending();
      expect(transport.cancelled, hasLength(3));
      transport.reads.last.complete({'items': []});
      await next;
      await replacement.dispose();
      await second.dispose();
    },
  );

  test(
    'successive lookups reuse bounded scopes with increasing sequence',
    () async {
      final sessions = <String>{};
      var lastSequence = 0;
      final repository = NativeRepository.test(
        transport: (input) async {
          expect(input['action'], 'catalog');
          sessions.add(input['session'] as String);
          expect(input['sequence'] as int, greaterThan(lastSequence));
          lastSequence = input['sequence'] as int;
          return {
            'ok': true,
            'data': {'items': []},
          };
        },
      );
      for (var index = 0; index < 160; index++) {
        final session = repository.seasonLookup();
        await session.catalog('hongguo', query: '合成$index');
        await session.dispose();
      }
      expect(sessions, hasLength(1));
      expect(sessions.single, endsWith(':season-0-catalog'));
    },
  );

  for (final replaceAccess in [false, true]) {
    test(
      'session is invalidated by profile or access replacement $replaceAccess',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final store = LocalStore(preferences);
        addTearDown(store.dispose);
        final transport = SessionTransport();
        final repository = NativeRepository.test(transport: transport.call)
          ..access = store;
        final session = repository.seasonLookup();
        final pending = session.metadata(sessionDrama);
        final pendingCheck = expectLater(pending, throwsA(isA<AppFailure>()));
        await transport.waitFor(1);
        if (replaceAccess) {
          final other = LocalStore(preferences);
          addTearDown(other.dispose);
          repository.access = other;
        } else {
          await store.switchProfile('default');
        }
        transport.reads.single.complete({'drama': sessionDrama.toJson()});
        await pendingCheck;
        await expectLater(session.catalog('hongguo'), sessionCancelled);
        expect(transport.reads, hasLength(1));
        await session.dispose();
      },
    );
  }

  test('invalid source and identity never enter native transport', () async {
    var calls = 0;
    final repository = NativeRepository.test(
      transport: (_) async {
        calls++;
        return {'ok': true, 'data': {}};
      },
    );
    final session = repository.seasonLookup();
    for (final request in [
      () => session.catalog('huangdou'),
      () => session.metadata(
        const Drama(id: 'huangdou:123', source: 'huangdou', title: '合成'),
      ),
      () => session.metadata(
        const Drama(id: 'hongguo:invalid', source: 'hongguo', title: '合成'),
      ),
      () => session.detail(
        const Drama(id: 'hongguo:123', source: 'huangdou', title: '合成'),
      ),
    ]) {
      await expectLater(request(), throwsA(isA<AppFailure>()));
    }
    expect(calls, 0);
    await session.dispose();
  });

  test('locked profiles cannot enter season metadata transport', () async {
    SharedPreferences.setMockInitialValues({});
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.saveProfile(
      id: 'default',
      name: '合成管理员',
      sources: [],
      download: true,
      pin: 'abcdef12',
    );
    store.lock();
    expect(store.locked, isTrue);
    var calls = 0;
    final repository = NativeRepository.test(
      transport: (_) async {
        calls++;
        return {'ok': true, 'data': {}};
      },
    )..access = store;
    final session = repository.seasonLookup();
    await expectLater(
      session.metadata(sessionDrama),
      throwsA(
        isA<AppFailure>().having((e) => e.message, 'message', contains('解锁')),
      ),
    );
    expect(calls, 0);
    await session.dispose();
  });

  test('metadata and detail reject a mismatched returned identity', () async {
    final repository = NativeRepository.test(
      transport: (_) async => {
        'ok': true,
        'data': {
          'drama': const Drama(
            id: 'hongguo:456',
            source: 'hongguo',
            title: '其他合成',
          ).toJson(),
          'chapters': [],
        },
      },
    );
    final session = repository.seasonLookup();
    for (final request in [
      () => session.metadata(sessionDrama),
      () => session.detail(sessionDrama),
    ]) {
      await expectLater(
        request(),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            'next_season_ambiguous',
          ),
        ),
      );
    }
    await session.dispose();
  });
}
