import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart' show appVersion, windowsBuildNumber;
import 'windows_update_package.dart';
import 'windows_desktop.dart';

class WindowsUpdateHelper {
  WindowsUpdateHelper({
    required this.process,
    required this.transaction,
    required this.nonce,
    this.readyTimeout = const Duration(seconds: 15),
    this.exitTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 100),
  }) {
    process.stdout.listen((_) {}, onError: (_) {});
    process.stderr.listen((_) {}, onError: (_) {});
    exited = process.exitCode.then((code) {
      exitCode = code;
      return code;
    });
  }

  final Process process;
  final Directory transaction;
  final String nonce;
  final Duration readyTimeout;
  final Duration exitTimeout;
  final Duration pollInterval;
  late final Future<int> exited;
  int? exitCode;

  Future<void> log(String phase, {Object? error}) async {
    await File(
      p.join(transaction.path, 'client-diagnostics.jsonl'),
    ).writeAsString(
      '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'phase': phase, 'helperPid': process.pid, 'helperExitCode': exitCode, if (error != null) 'error': error.toString()})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> waitReady() async {
    await log('waiting-helper-ready');
    final ready = File(p.join(transaction.path, 'ready.txt'));
    final status = File(p.join(transaction.path, 'status.txt'));
    final deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await status.exists()) {
        throw StateError(await status.readAsString());
      }
      if (exitCode != null) {
        throw StateError('更新助手 PID ${process.pid} 已退出，退出码 $exitCode');
      }
      if (await ready.exists() && await ready.readAsString() == nonce) {
        await log('helper-ready');
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw StateError('更新助手未在就绪时限内完成验证，应用保持运行，旧版未替换');
  }

  Future<void> authorizeHandoff() async {
    if (exitCode != null ||
        await File(p.join(transaction.path, 'cancel.txt')).exists()) {
      throw StateError('更新助手已退出或事务已取消，旧版未替换');
    }
    await File(
      p.join(transaction.path, 'commit.txt'),
    ).writeAsString(nonce, flush: true);
    await log('handoff-authorized');
  }

  Future<bool> cancelAndWait() async {
    try {
      await File(
        p.join(transaction.path, 'cancel.txt'),
      ).writeAsString(nonce, flush: true);
      await log('cancelling-helper');
    } catch (error) {
      await _tryLog('cancel-write-failed', error);
    }
    if (await _waitExit()) return true;
    try {
      final requested = process.kill();
      await _tryLog('helper-termination-requested', 'requested=$requested');
    } catch (error) {
      await _tryLog('helper-termination-failed', error);
    }
    return _waitExit();
  }

  Future<bool> _waitExit() async {
    try {
      await exited.timeout(exitTimeout);
      await _tryLog('helper-exit-confirmed', 'exitCode=$exitCode');
      return true;
    } catch (error) {
      await _tryLog('helper-exit-unconfirmed', error);
      return false;
    }
  }

  Future<void> _tryLog(String phase, Object error) async {
    try {
      await log(phase, error: error);
    } catch (_) {}
  }
}

class WindowsUpdateRuntime {
  static Object? owner;
  static bool Function()? playing;
  static Future<Map<String, dynamic>?> Function()? savePlayback;
  static Future<void> Function()? flushStore;
  static bool restarting = false;
  static Directory? startupTransaction;
  static String? startupFailure;

  static Future<void> initialize(List<String> arguments) async {
    if (!Platform.isWindows ||
        arguments.firstOrNull != '--windows-update-start')
      return;
    final support = await getApplicationSupportDirectory();
    await loadStartup(
      arguments,
      support: support,
      executable: Platform.resolvedExecutable,
    );
  }

  static Future<void> loadStartup(
    List<String> arguments, {
    required Directory support,
    required String executable,
  }) async {
    startupTransaction = null;
    startupFailure = null;
    if (arguments.length != 2 || arguments.first != '--windows-update-start') {
      throw const FormatException('更新启动参数无效');
    }
    final plan = File(arguments[1]);
    final transaction = plan.parent;
    final nonce = p.basename(transaction.path);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce) ||
        !p.equals(
          transaction.parent.path,
          p.join(support.path, 'windows-updates'),
        ) ||
        p.basename(plan.path) != 'plan.txt') {
      throw const FormatException('更新事务路径无效');
    }
    final fields = await readPlan(plan);
    if (fields['nonce'] != nonce ||
        !p.equals(fields['root'] ?? '', p.dirname(executable))) {
      throw const FormatException('更新启动目录不匹配');
    }
    startupTransaction = transaction;
    await startupPhase('validated');
  }

  static Future<Map<String, String>> readPlan(File file) async {
    if (await file.length() > 65536) throw const FormatException('更新计划过大');
    final result = <String, String>{};
    for (final line in await file.readAsLines()) {
      final equals = line.indexOf('=');
      if (equals <= 0 || result.containsKey(line.substring(0, equals))) {
        throw const FormatException('更新计划格式无效或字段重复');
      }
      result[line.substring(0, equals)] = line.substring(equals + 1);
    }
    return result;
  }

  static Future<void> startupPhase(String phase, {Object? error}) async {
    final transaction = startupTransaction;
    if (transaction == null) return;
    await File(
      p.join(transaction.path, 'startup-$windowsBuildNumber.json'),
    ).writeAsString(
      jsonEncode({
        'phase': phase,
        'build': windowsBuildNumber,
        'nonce': p.basename(transaction.path),
        if (error != null) 'error': error.toString(),
      }),
      flush: true,
    );
  }

  static Future<Map<String, dynamic>?> ready() async {
    final transaction = startupTransaction;
    if (transaction == null) return null;
    final fields = await readPlan(File(p.join(transaction.path, 'plan.txt')));
    final statusFile = File(p.join(transaction.path, 'status.txt'));
    if (await statusFile.exists()) {
      final status = await statusFile.readAsString();
      if (status.startsWith('failed:')) {
        startupFailure = '$status\n更新诊断与恢复记录：${transaction.path}';
      }
    }
    if (fields['build'] == '$windowsBuildNumber') {
      await File(
        p.join(transaction.path, 'ack.txt'),
      ).writeAsString(fields['nonce']!, flush: true);
      await startupPhase('acknowledged');
    }
    final delivered = File(
      p.join(transaction.path, 'resume-$windowsBuildNumber.txt'),
    );
    final resume = File(p.join(transaction.path, 'resume.json'));
    if (await delivered.exists() || !await resume.exists()) return null;
    await delivered.writeAsString('consumed', flush: true);
    return jsonDecode(await resume.readAsString()) as Map<String, dynamic>;
  }

  static Future<String> install({
    required String zipPath,
    required String version,
    required int build,
  }) async {
    if (restarting) throw StateError('更新事务已在进行');
    if (playing?.call() == true) return 'playing';
    restarting = true;
    Directory? stage;
    Directory? transaction;
    WindowsUpdateHelper? helperSession;
    var handedOff = false;
    try {
      final root = Directory(p.dirname(Platform.resolvedExecutable));
      if (p.basename(Platform.resolvedExecutable).toLowerCase() !=
              'hongguotv.exe' ||
          root.path.length > 180 ||
          root.path.startsWith(r'\\')) {
        throw const FormatException('请从独立本地应用目录运行更新');
      }
      final old = await validateWindowsDirectory(
        root,
        appVersion,
        windowsBuildNumber,
      );
      final random = Random.secure();
      final nonce = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      stage = Directory(p.join(root.parent.path, '.hongguo-stage-$nonce'));
      final backup = p.join(root.parent.path, '.hongguo-backup-$nonce');
      final stagePath = stage.path;
      final next = await Isolate.run(
        () => extractWindowsPackage(
          zipPath: zipPath,
          stagePath: stagePath,
          version: version,
          build: build,
        ),
      );
      if (playing?.call() == true) throw StateError('播放状态已变化，请暂停后重新安装');
      final support = await getApplicationSupportDirectory();
      transaction = Directory(p.join(support.path, 'windows-updates', nonce));
      await transaction.create(recursive: true);
      await flushStore?.call();
      final resume = await savePlayback?.call();
      if (resume != null)
        await File(
          p.join(transaction.path, 'resume.json'),
        ).writeAsString(jsonEncode(resume), flush: true);
      await flushStore?.call();
      final config = File(p.join(support.path, 'shared_preferences.json'));
      if (await config.exists())
        await config.copy(p.join(transaction.path, 'preferences-backup.json'));
      Future<void> records(
        String name,
        Directory dir,
        Map<String, dynamic> manifest,
      ) async {
        final files = manifest['files'] as Map;
        final entries = <String>[
          for (final entry in files.entries)
            '${(entry.value as Map)['sha256']}\t${entry.key}',
          '${(await sha256.bind(File(p.join(dir.path, 'windows-package.json')).openRead()).first)}\twindows-package.json',
        ];
        await File(
          p.join(transaction!.path, name),
        ).writeAsString('${entries.join('\n')}\n', flush: true);
      }

      await records('old-files.tsv', root, old);
      await records('new-files.tsv', stage, next);
      final fields = {
        'root': root.path,
        'stage': stage.path,
        'backup': backup,
        'pid': '$pid',
        'nonce': nonce,
        'build': '$build',
        'oldBuild': '$windowsBuildNumber',
        'version': version.split('-').first,
        'oldVersion': appVersion.split('-').first,
        'config': config.path,
      };
      if (fields.values.any(
        (value) => value.contains('\n') || value.contains('\r'),
      )) {
        throw const FormatException('更新路径包含换行');
      }
      final plan = File(p.join(transaction.path, 'plan.txt'));
      await plan.writeAsString(
        fields.entries.map((entry) => '${entry.key}=${entry.value}').join('\n'),
        flush: true,
      );
      final helper = await File(
        p.join(root.path, 'HongguoTV-updater.exe'),
      ).copy(p.join(transaction.path, 'HongguoTV-updater.exe'));
      final process = await Process.start(
        helper.path,
        [plan.path],
        mode: ProcessStartMode.normal,
        workingDirectory: transaction.path,
      );
      helperSession = WindowsUpdateHelper(
        process: process,
        transaction: transaction,
        nonce: nonce,
      );
      await helperSession.waitReady();
      try {
        await WindowsDesktop.current?.prepareForUpdate();
        await helperSession.authorizeHandoff();
        handedOff = true;
        if (WindowsDesktop.current case final desktop?) {
          await desktop.finishExit();
        } else {
          await windowManager.destroy();
        }
      } catch (_) {
        handedOff = false;
        await WindowsDesktop.current?.cancelUpdateExit();
        rethrow;
      }
      exit(0);
    } catch (error, stack) {
      final stopped =
          helperSession == null || await helperSession.cancelAndWait();
      if (!stopped) {
        Error.throwWithStackTrace(
          StateError(
            '$error；更新助手 PID ${helperSession.process.pid} 未确认退出，已保留暂存目录 ${stage?.path} 和事务记录 ${transaction?.path}，请保留这些文件以便恢复',
          ),
          stack,
        );
      }
      try {
        if (stage != null && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } catch (cleanupError) {
        Error.throwWithStackTrace(
          StateError('$error；暂存目录清理失败：$cleanupError；事务记录 ${transaction?.path}'),
          stack,
        );
      }
      rethrow;
    } finally {
      if (!handedOff) {
        restarting = false;
      }
    }
  }
}
