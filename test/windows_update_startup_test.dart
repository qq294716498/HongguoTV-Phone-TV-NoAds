import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/windows_update_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory support;
  late Directory transaction;
  late File plan;
  late String executable;
  const nonce = '0123456789abcdef0123456789abcdef';
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('update-startup-中文 ');
    support = Directory(p.join(temporary.path, 'app support', '红果TV'));
    transaction = Directory(p.join(support.path, 'windows-updates', nonce));
    await transaction.create(recursive: true);
    plan = File(p.join(transaction.path, 'plan.txt'));
    executable = p.join(temporary.path, 'program space 中文', 'HongguoTV.exe');
    WindowsUpdateRuntime.startupTransaction = null;
  });
  tearDown(() async {
    WindowsUpdateRuntime.startupTransaction = null;
    await temporary.delete(recursive: true);
  });
  Future<void> writePlan({
    String token = nonce,
    String? root,
    int? build,
    String ending = '\n',
  }) async {
    await plan.writeAsString(
      [
        'root=${root ?? p.dirname(executable)}',
        'nonce=$token',
        'build=${build ?? windowsBuildNumber}',
        'oldBuild=${windowsBuildNumber - 1}',
      ].join(ending),
    );
  }

  Future<void> load() => WindowsUpdateRuntime.loadStartup(
    ['--windows-update-start', plan.path],
    support: support,
    executable: executable,
  );

  test(
    'CRLF plan in Chinese and spaced paths confirms the exact nonce only after ready',
    () async {
      await writePlan(ending: '\r\n');
      await load();
      final ack = File(p.join(transaction.path, 'ack.txt'));
      expect(await ack.exists(), isFalse);
      expect(
        jsonDecode(
          await File(
            p.join(transaction.path, 'startup-$windowsBuildNumber.json'),
          ).readAsString(),
        )['phase'],
        'validated',
      );
      await WindowsUpdateRuntime.startupPhase('first-frame');
      expect(await ack.exists(), isFalse);
      expect(await WindowsUpdateRuntime.ready(), isNull);
      expect(await ack.readAsString(), nonce);
    },
  );
  test(
    'unrecognized nonce, install root and support namespace never confirm',
    () async {
      for (final kind in [0, 1, 2]) {
        await writePlan(
          token: kind == 0 ? 'bad' : nonce,
          root: kind == 1 ? temporary.path : null,
        );
        await expectLater(
          WindowsUpdateRuntime.loadStartup(
            ['--windows-update-start', plan.path],
            support: kind == 2 ? temporary : support,
            executable: executable,
          ),
          throwsFormatException,
        );
        expect(WindowsUpdateRuntime.startupTransaction, isNull);
        expect(
          await File(p.join(transaction.path, 'ack.txt')).exists(),
          isFalse,
        );
      }
    },
  );
  test(
    'rollback startup keeps old build unconfirmed and restores one paused resume token',
    () async {
      await writePlan(build: windowsBuildNumber + 1);
      final resume = {'profile': 'default', 'position': 43.5, 'index': 1};
      await File(
        p.join(transaction.path, 'resume.json'),
      ).writeAsString(jsonEncode(resume));
      await load();
      expect(await WindowsUpdateRuntime.ready(), resume);
      expect(await File(p.join(transaction.path, 'ack.txt')).exists(), isFalse);
      expect(await WindowsUpdateRuntime.ready(), isNull);
    },
  );
  test(
    'malformed and duplicate plan fields fail before startup confirmation',
    () async {
      for (final content in ['broken', 'nonce=$nonce\nnonce=$nonce']) {
        await plan.writeAsString(content);
        await expectLater(load(), throwsFormatException);
        expect(
          await File(p.join(transaction.path, 'ack.txt')).exists(),
          isFalse,
        );
      }
    },
  );
}
