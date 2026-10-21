import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/windows_update_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class ControlledHelperProcess implements Process {
  final completion = Completer<int>();
  bool Function()? onKill;
  int kills = 0;

  @override
  int get pid => 321;
  @override
  Future<int> get exitCode => completion.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    return onKill?.call() ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory transaction;
  late ControlledHelperProcess process;
  const nonce = '0123456789abcdef0123456789abcdef';
  setUp(() async {
    transaction = await Directory.systemTemp.createTemp('update-helper-中文 ');
    process = ControlledHelperProcess();
  });
  tearDown(() async {
    if (!process.completion.isCompleted) process.completion.complete(1);
    await transaction.delete(recursive: true);
  });
  WindowsUpdateHelper helper() => WindowsUpdateHelper(
    process: process,
    transaction: transaction,
    nonce: nonce,
    readyTimeout: const Duration(milliseconds: 45),
    exitTimeout: const Duration(milliseconds: 30),
    pollInterval: const Duration(milliseconds: 3),
  );

  test('late readiness after timeout cannot authorize activation', () async {
    final session = helper();
    await expectLater(session.waitReady(), throwsStateError);
    final stopped = session.cancelAndWait();
    final cancel = File(p.join(transaction.path, 'cancel.txt'));
    while (!await cancel.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(await cancel.readAsString(), nonce);
    await File(p.join(transaction.path, 'ready.txt')).writeAsString(nonce);
    await expectLater(session.authorizeHandoff(), throwsStateError);
    expect(
      await File(p.join(transaction.path, 'commit.txt')).exists(),
      isFalse,
    );
    process.completion.complete(1);
    expect(await stopped, isTrue);
    expect(process.kills, 0);
  });

  test(
    'cancellation waits for owned helper exit before permitting cleanup',
    () async {
      final session = helper();
      var returned = false;
      final stopped = session.cancelAndWait().then((value) {
        returned = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(returned, isFalse);
      process.completion.complete(7);
      expect(await stopped, isTrue);
      expect(session.exitCode, 7);
      expect(process.kills, 0);
    },
  );

  test(
    'unresponsive helper is terminated by its own process handle and awaited',
    () async {
      final session = helper();
      process.onKill = () {
        process.completion.complete(9);
        return true;
      };
      expect(await session.cancelAndWait(), isTrue);
      expect(process.kills, 1);
      expect(session.exitCode, 9);
    },
  );

  test(
    'termination without confirmed exit withholds cleanup permission',
    () async {
      final session = helper();
      process.onKill = () => true;
      expect(await session.cancelAndWait(), isFalse);
      expect(process.kills, 1);
      expect(session.exitCode, isNull);
      final lines = await File(
        p.join(transaction.path, 'client-diagnostics.jsonl'),
      ).readAsLines();
      final diagnostics = lines.map((line) => jsonDecode(line) as Map).toList();
      expect(diagnostics.last['phase'], 'helper-exit-unconfirmed');
      expect(diagnostics.every((line) => line['helperPid'] == 321), isTrue);
    },
  );

  test(
    'Win32 details from helper status remain visible to installation UI',
    () async {
      final session = helper();
      const details =
          'failed: phase=backup-current-directory; '
          'MoveFileExW failed, Win32=5; from=I:\\红果TV; to=I:\\.hongguo-backup';
      await File(p.join(transaction.path, 'status.txt')).writeAsString(details);
      await expectLater(
        session.waitReady(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'details',
            details,
          ),
        ),
      );
    },
  );

  test(
    'ready nonce and explicit handoff are distinct authorization steps',
    () async {
      final session = helper();
      await File(p.join(transaction.path, 'ready.txt')).writeAsString(nonce);
      await session.waitReady();
      final commit = File(p.join(transaction.path, 'commit.txt'));
      expect(await commit.exists(), isFalse);
      await session.authorizeHandoff();
      expect(await commit.readAsString(), nonce);
    },
  );

  test(
    'helper early exit does not wait for the full readiness timeout',
    () async {
      final session = helper();
      process.completion.complete(4);
      await expectLater(session.waitReady(), throwsStateError);
      expect(session.exitCode, 4);
      expect(await session.cancelAndWait(), isTrue);
    },
  );
}
