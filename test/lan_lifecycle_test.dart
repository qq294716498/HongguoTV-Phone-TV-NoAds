import 'dart:async';
import 'dart:collection';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/lan_controller.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class MemoryLanRepository extends FixtureRepository {
  MemoryLanRepository(this.id);
  final String id;
  final commands = <String>[];
  final events = Queue<Map<String, dynamic>>();
  final pendingRequests = <String, Completer<Map<String, dynamic>>>{};
  final replies = <String, Completer<Map<String, dynamic>>>{};
  final held = <void Function()>[];
  Completer<Map<String, dynamic>>? poll;
  late MemoryLanRepository remote;
  int starts = 0;
  int sequence = 0;
  bool holdSummary = false;
  bool legacySyncRequests = false;
  bool legacySyncResponses = false;
  String? holdPath;
  String? holdResponsePath;
  final responsePaths = <String, String>{};
  Map<String, dynamic> config = {};
  String get pin => id * 2;

  void deliver(Map<String, dynamic> event) {
    if (poll != null) {
      final pending = poll!;
      poll = null;
      pending.complete({'event': event});
    } else {
      events.add(event);
    }
  }

  void releaseSummary() {
    for (final send in held.toList()) {
      send();
    }
    held.clear();
  }

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async {
    commands.add(command);
    switch (command) {
      case 'start':
        starts++;
        config = Map<String, dynamic>.from(payload['config'] as Map);
        return {
          'generation': starts.toRadixString(16).padLeft(32, '0'),
          'deviceId': id,
          'pin': pin,
          'port': 12345,
          'protocol': 1,
          'kind': config['kind'],
          'name': config['name'],
          'addresses': ['127.0.0.1:12345'],
        };
      case 'stop':
      case 'disconnect':
        for (final pending in pendingRequests.values.toList()) {
          if (!pending.isCompleted) {
            pending.completeError(AppFailure('context canceled'));
          }
        }
        pendingRequests.clear();
        if (command == 'stop') {
          poll?.complete({});
          poll = null;
          events.clear();
          held.clear();
        }
        return {};
      case 'allow':
        return {'token': 'a' * 64};
      case 'configure':
        config = Map<String, dynamic>.from(payload['config'] as Map);
        return {};
      case 'cancel':
        final pending = pendingRequests.remove(payload['requestId']);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(AppFailure('context canceled'));
        }
        return {};
      case 'poll':
        if (events.isNotEmpty) return {'event': events.removeFirst()};
        poll = Completer<Map<String, dynamic>>();
        return poll!.future;
      case 'request':
        final request = payload['requestId'] as String;
        final pending = Completer<Map<String, dynamic>>();
        pendingRequests[request] = pending;
        final eventId = '$id-${sequence++}';
        remote.replies[eventId] = pending;
        remote.responsePaths[eventId] = payload['path'] as String;
        void send() {
          if (pending.isCompleted) return;
          remote.deliver({
            'id': eventId,
            'path': payload['path'],
            'peerId': id,
            'pin': pin,
            'host': '127.0.0.1',
            'payload': {...Map<String, dynamic>.from(payload['payload'] as Map)}
              ..removeWhere((key, _) => legacySyncRequests && key == 'schema'),
          });
        }
        if (holdSummary && payload['path'] == 'sync/summary' ||
            payload['path'] == holdPath) {
          held.add(send);
        } else {
          send();
        }
        try {
          return await pending.future;
        } finally {
          pendingRequests.remove(request);
        }
      case 'respond':
        final path = responsePaths.remove(payload['eventId']);
        final pending = replies.remove(payload['eventId']);
        if (path == holdResponsePath) return {'accepted': true};
        if (pending != null && !pending.isCompleted) {
          if (payload['error'] != '') {
            pending.completeError(AppFailure(payload['error'] as String));
          } else {
            pending.complete(
              Map<String, dynamic>.from(payload['payload'] as Map)..removeWhere(
                (key, _) => legacySyncResponses && key == 'schema',
              ),
            );
          }
        }
        return {'accepted': true};
      default:
        throw StateError(command);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final result = testStore(await SharedPreferences.getInstance());
    await result.saveLanSettings({'autoSync': false});
    addTearDown(result.dispose);
    return result;
  }

  Future<
    (LanController, LanController, MemoryLanRepository, MemoryLanRepository)
  >
  pair() async {
    final a = MemoryLanRepository('1' * 32);
    final b = MemoryLanRepository('2' * 32);
    a.remote = b;
    b.remote = a;
    final left = LanController(a, await store(), kind: 'phone');
    final right = LanController(b, await store(), kind: 'tv');
    addTearDown(() async {
      left.dispose();
      right.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await left.setEnabled(true);
    await right.setEnabled(true);
    await left.connect(right.local!);
    return (left, right, a, b);
  }

  const season1 = Drama(
    id: 'hongguo:sync-s1',
    source: 'hongguo',
    title: '跨设备合成 第一季',
    episodes: 10,
  );
  const season2 = Drama(
    id: 'hongguo:sync-s2',
    source: 'hongguo',
    title: '跨设备合成 第二季',
    episodes: 12,
  );
  const season3 = Drama(
    id: 'hongguo:sync-s3',
    source: 'hongguo',
    title: '跨设备合成 第三季',
    episodes: 14,
  );
  WatchEntry progress(Drama drama, int episode, double position, int minute) =>
      WatchEntry(
        drama: drama,
        episode: episode,
        position: position,
        duration: 120,
        updatedAt: DateTime.utc(2026, 10, 17, 12, minute),
      );
  Future<void> baseline(LanController left, LanController right) async {
    await left.store.toggleSeriesFavorite(season1);
    await right.store.toggleSeriesFavorite(season1);
    await left.synchronize();
    await left.store.saveWatch(progress(season1, 2, 8, 1));
    await left.synchronize();
  }

  void expectProgress(
    LocalStore store,
    Drama drama,
    int episode,
    double position,
  ) {
    expect(store.favorites.map((d) => d.id), [season1.id]);
    final record = store.lanDocument.records[season1.id]!;
    expect(record.watch!.drama.id, drama.id);
    expect(record.watch!.episode, episode);
    expect(record.watch!.position, position);
    expect(record.watch!.duration, 120);
    expect(store.seriesWatch(season1)!.drama.id, drama.id);
    expect(store.watched(drama.id)!.position, position);
  }

  for (final mode in ['merge', 'push', 'pull', 'automatic']) {
    test(
      'cross-season $mode preserves the favorite anchor and real watched identity after restart',
      () async {
        final (left, right, _, _) = await pair();
        await baseline(left, right);
        await left.store.saveWatch(progress(season3, 7, 37, 3));
        expect(
          right.store.seriesDramasFor(season1).any((d) => d.id == season3.id),
          false,
        );
        if (mode == 'merge') {
          await left.synchronize();
        } else if (mode == 'automatic') {
          await left.setAutoSync(true);
          await right.setAutoSync(true);
          left.connection!.autoSync = true;
          right.connection!.autoSync = true;
          left.flush();
          for (
            var i = 0;
            i < 100 && right.store.seriesWatch(season1)?.drama.id != season3.id;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        } else {
          final owner = mode == 'push' ? left : right;
          final preview = await owner.preview(
            mode == 'push' ? LanSyncMode.push : LanSyncMode.pull,
          );
          await owner.applyPreview(preview);
        }
        expectProgress(right.store, season3, 7, 37);
        final restarted = LocalStore(right.store.preferences);
        addTearDown(restarted.dispose);
        expectProgress(restarted, season3, 7, 37);
      },
    );
  }

  test(
    'rewatching season one replaces the later season instead of maximizing season or episode',
    () async {
      final (left, right, _, _) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 12, 70, 3));
      await left.synchronize();
      await right.store.saveWatch(progress(season1, 1, 3, 5));
      await right.synchronize();
      expectProgress(left.store, season1, 1, 3);
      expect(left.store.history.any((w) => w.drama.id == season3.id), true);
    },
  );

  test(
    'offline cross-season conflict selection retains the entire chosen progress value',
    () async {
      final (left, right, _, _) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      await right.store.saveWatch(progress(season2, 9, 61, 4));
      await left.synchronize();
      final conflict = left.store.lanDocument.records[season1.id]!;
      expect(conflict.progress.conflict, true);
      final choice = conflict.progress.values.firstWhere(
        (v) => lanMap(lanMap(v.value)['drama'])['id'] == season3.id,
      );
      await left.store.resolveLanConflict(
        season1.id,
        'progress',
        choice,
        conflict.hash,
      );
      await left.synchronize();
      expectProgress(right.store, season3, 7, 37);
      expect(
        right.store.lanDocument.records[season1.id]!.watch!.updatedAt,
        progress(season3, 7, 37, 3).updatedAt,
      );
      final restarted = LocalStore(right.store.preferences);
      addTearDown(restarted.dispose);
      expectProgress(restarted, season3, 7, 37);
    },
  );

  test(
    'deleting one season propagates its tombstone without clearing other seasons',
    () async {
      final (left, right, _, _) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      await left.synchronize();
      await left.store.removeHistory(season3.id);
      await left.synchronize();
      expectProgress(right.store, season1, 2, 8);
      expect(right.store.history.any((w) => w.drama.id == season3.id), false);
      await right.synchronize();
      expect(
        left.store.lanDocument.records[season1.id]!.watch!.drama.id,
        season1.id,
      );
      await left.store.saveWatch(progress(season3, 4, 15, 6));
      await left.synchronize();
      await left.store.removeHistory(season1.id);
      await left.synchronize();
      expectProgress(right.store, season3, 4, 15);
      expect(right.store.history.any((w) => w.drama.id == season1.id), false);
    },
  );

  test(
    'clear and unfollow do not revive stale synchronized series progress',
    () async {
      final (left, right, _, _) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      await left.synchronize();
      await left.store.clearHistory();
      await left.synchronize();
      expect(right.store.seriesWatch(season1), isNull);
      expect(right.store.history, isEmpty);
      await right.synchronize();
      expect(left.store.lanDocument.records[season1.id]!.watch, isNull);
      await left.store.toggleSeriesFavorite(season1);
      await left.synchronize();
      await right.store.saveWatch(progress(season3, 8, 40, 5));
      await right.synchronize();
      expect(left.store.favorites, isEmpty);
      expect(right.store.lanDocument.records[season1.id]!.watch, isNull);
    },
  );

  for (final mode in [LanSyncMode.push, LanSyncMode.pull]) {
    test(
      'authoritative ${mode.name} null progress dominates an offline season change',
      () async {
        final (left, right, _, _) = await pair();
        await baseline(left, right);
        await left.store.clearHistory();
        await right.store.saveWatch(progress(season3, 7, 37, 3));
        final owner = mode == LanSyncMode.push ? left : right;
        await owner.applyPreview(await owner.preview(mode));
        expect(right.store.seriesWatch(season1), isNull);
        expect(left.store.lanDocument.records[season1.id]!.watch, isNull);
        await right.synchronize();
        expect(left.store.seriesWatch(season1), isNull);
      },
    );
  }

  test(
    'history truncation retains a followed cross-season resume cursor',
    () async {
      final (left, right, _, _) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      for (var i = 0; i < 301; i++) {
        await left.store.saveWatch(
          progress(
            Drama(
              id: 'hongguo:unfollowed-$i',
              source: 'hongguo',
              title: '无关历史$i',
            ),
            1,
            1,
            i + 10,
          ),
        );
      }
      expect(left.store.history, hasLength(300));
      expect(left.store.history.any((w) => w.drama.id == season3.id), false);
      expect(left.store.watched(season3.id)!.position, 37);
      await left.synchronize();
      expectProgress(right.store, season3, 7, 37);
      expect(right.store.favorites, hasLength(1));
      expect(
        right.store.history.any(
          (w) => w.drama.id.startsWith('hongguo:unfollowed-'),
        ),
        false,
      );
    },
  );

  for (final direction in ['request', 'response']) {
    test('legacy sync $direction fails before writing either device', () async {
      final (left, right, a, b) = await pair();
      await baseline(left, right);
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      final beforeLeft = left.store.lanDocument.hashFor({'hongguo'});
      final beforeRight = right.store.lanDocument.hashFor({'hongguo'});
      a.legacySyncRequests = direction == 'request';
      b.legacySyncResponses = direction == 'response';
      await expectLater(
        left.synchronize(),
        throwsA(predicate((e) => e.toString().contains('升级'))),
      );
      expect(left.store.lanDocument.hashFor({'hongguo'}), beforeLeft);
      expect(right.store.lanDocument.hashFor({'hongguo'}), beforeRight);
    });
  }

  test(
    'unfollowed history stays local even when synchronization has zero changes',
    () async {
      final (left, right, _, _) = await pair();
      await left.store.saveWatch(progress(season3, 7, 37, 3));
      await left.synchronize();
      expect(left.store.history, hasLength(1));
      expect(right.store.history, isEmpty);
      expect(right.store.favorites, isEmpty);
      expect(left.store.lanDocument.records, isEmpty);
      expect(left.syncMessage, '追剧及其续播进度已同步');
    },
  );

  test(
    'two devices merge followed records in both directions without duplication',
    () async {
      final (left, right, _, _) = await pair();
      const other = Drama(id: 'hongguo:200', source: 'hongguo', title: '合成追剧');
      await left.store.toggleFavorite(FixtureRepository.free);
      await right.store.toggleFavorite(other);
      await left.synchronize();
      expect(right.store.isFavorite(FixtureRepository.free.id), isTrue);
      expect(left.store.isFavorite(other.id), isTrue);
      final hash = left.store.lanDocument.hashFor({'hongguo'});
      expect(right.store.lanDocument.hashFor({'hongguo'}), hash);
      await right.synchronize();
      expect(left.store.lanDocument.hashFor({'hongguo'}), hash);
      expect(right.store.lanDocument.hashFor({'hongguo'}), hash);
    },
  );

  test(
    'inactive retains an in-flight summary and resumed does not recreate the session',
    () async {
      final (left, right, transport, _) = await pair();
      transport.holdSummary = true;
      final sync = left.synchronize();
      await Future<void>.delayed(Duration.zero);
      final starts = transport.starts;
      final stops = transport.commands.where((value) => value == 'stop').length;
      left.didChangeAppLifecycleState(AppLifecycleState.inactive);
      right.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(left.receiving, isTrue);
      expect(right.receiving, isTrue);
      transport.releaseSummary();
      await sync;
      left.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(transport.starts, starts);
      expect(
        transport.commands.where((value) => value == 'stop').length,
        stops,
      );
      expect(left.syncMessage, '追剧及其续播进度已同步');
    },
  );

  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test(
      '$state cancels safely and resumed reconnects for a successful retry',
      () async {
        final (left, right, transport, _) = await pair();
        transport.holdSummary = true;
        final sync = left.synchronize();
        final failure = expectLater(
          sync,
          throwsA(
            isA<LanSyncCancelled>().having(
              (value) => value.reason,
              'reason',
              contains('后台'),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        left.didChangeAppLifecycleState(state);
        await failure;
        expect(left.receiving, isFalse);
        left.didChangeAppLifecycleState(AppLifecycleState.inactive);
        expect(left.receiving, isFalse);
        left.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await left.ensureEnabled();
        await left.connect(right.local!);
        transport.holdSummary = false;
        await left.synchronize();
        expect(left.syncMessage, '追剧及其续播进度已同步');
      },
    );
  }

  test(
    'explicit cancel reports its reason and a new synchronization succeeds',
    () async {
      final (left, _, transport, _) = await pair();
      DiaryService.clear();
      transport.holdSummary = true;
      final sync = left.synchronize();
      final failure = expectLater(
        sync,
        throwsA(
          isA<LanSyncCancelled>().having(
            (value) => value.reason,
            'reason',
            contains('主动取消'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await left.cancelSync();
      await failure;
      expect(left.syncMessage, contains('主动取消'));
      expect(left.syncMessage, isNot(contains('context canceled')));
      expect(DiaryService.fullText, contains('phase=sync/summary'));
      expect(DiaryService.fullText, contains('主动取消'));
      transport.holdSummary = false;
      await left.synchronize();
      expect(left.syncMessage, '追剧及其续播进度已同步');
    },
  );

  test(
    'disabled interconnection remains stopped through inactive and resumed',
    () async {
      final (left, _, transport, _) = await pair();
      await left.setEnabled(false);
      final starts = transport.starts;
      left.didChangeAppLifecycleState(AppLifecycleState.inactive);
      left.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(left.receiving, isFalse);
      expect(transport.starts, starts);
    },
  );
  test(
    'cancel before commit preserves records and does not hide an uncertain remote receipt',
    () async {
      final (left, right, transport, _) = await pair();
      await left.store.toggleFavorite(FixtureRepository.free);
      transport.holdPath = 'sync/commit';
      final sync = left.synchronize();
      final failure = expectLater(
        sync,
        throwsA(
          isA<StateError>().having(
            (value) => value.toString(),
            'warning',
            contains('尚未确认对方是否保存'),
          ),
        ),
      );
      while (transport.held.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await left.cancelSync();
      await failure;
      expect(left.store.isFavorite(FixtureRepository.free.id), isTrue);
      expect(right.store.isFavorite(FixtureRepository.free.id), isFalse);
      transport.holdPath = null;
      await left.synchronize();
      expect(right.store.isFavorite(FixtureRepository.free.id), isTrue);
    },
  );

  test(
    'cancel after remote save retains the partial-save warning and retry converges',
    () async {
      final (left, right, transport, remote) = await pair();
      await left.store.toggleFavorite(FixtureRepository.free);
      remote.holdResponsePath = 'sync/commit';
      final sync = left.synchronize();
      final failure = expectLater(
        sync,
        throwsA(
          isA<StateError>().having(
            (value) => value.toString(),
            'warning',
            contains('对方已保存'),
          ),
        ),
      );
      while (!right.store.isFavorite(FixtureRepository.free.id)) {
        await Future<void>.delayed(Duration.zero);
      }
      await left.cancelSync();
      await failure;
      expect(left.store.isFavorite(FixtureRepository.free.id), isTrue);
      expect(right.store.isFavorite(FixtureRepository.free.id), isTrue);
      remote.holdResponsePath = null;
      await left.synchronize();
      expect(
        left.store.lanDocument.hashFor({'hongguo'}),
        right.store.lanDocument.hashFor({'hongguo'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.pendingRequests, isEmpty);
    },
  );
}
