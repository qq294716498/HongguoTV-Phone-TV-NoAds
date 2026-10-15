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
            'payload': payload['payload'],
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
              Map<String, dynamic>.from(payload['payload'] as Map),
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
      expect(left.syncMessage, '双方记录已同步');
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
        expect(left.syncMessage, '双方记录已同步');
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
      expect(left.syncMessage, '双方记录已同步');
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
