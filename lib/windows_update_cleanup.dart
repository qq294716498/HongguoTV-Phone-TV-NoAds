import 'dart:convert';
import 'dart:io' hide ZLibDecoder;
import 'dart:io' as io show ZLibDecoder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'windows_update_package.dart';

Future<RandomAccessFile> lockWindowsUpdateCache(Directory updates) async {
  final path = p.join(updates.parent.path, 'windows-update-cache.lock');
  if (await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('更新下载锁路径含链接');
  }
  final file = await File(path).open(mode: FileMode.append);
  try {
    await file.lock(FileLock.exclusive);
    return file;
  } catch (_) {
    await file.close();
    rethrow;
  }
}

class WindowsUpdateCleanup {
  WindowsUpdateCleanup({
    required this.support,
    required this.executable,
    required this.build,
  });

  final Directory support;
  final String executable;
  final int build;
  static const receiptName = 'cleanup-receipt.json';

  Future<void> _safe(String path) async {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path == p.rootPrefix(path) ||
        path.startsWith(r'\\')) {
      throw const FormatException('更新清理路径无效');
    }
    for (var current = path; ; current = p.dirname(current)) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('更新清理路径含链接');
      }
      if (current == p.dirname(current)) break;
    }
  }

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<Map<String, String>> _records(File file) async {
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('更新文件记录过大');
    }
    final result = <String, String>{};
    final aliases = <String>{};
    for (final line in await file.readAsLines()) {
      if (line.length < 66 ||
          line[64] != '\t' ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(line.substring(0, 64))) {
        throw const FormatException('更新文件记录无效');
      }
      final name = windowsPackagePath(line.substring(65));
      if (!aliases.add(name.toLowerCase())) {
        throw const FormatException('更新文件记录重复');
      }
      result[name] = line.substring(0, 64);
    }
    if (result.isEmpty || result.length > 2048) {
      throw const FormatException('更新文件记录数量无效');
    }
    return result;
  }

  Future<void> _location(Directory transaction) async {
    await _safe(transaction.path);
    final nonce = p.basename(transaction.path);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce) ||
        !p.equals(
          transaction.parent.path,
          p.join(support.path, 'windows-updates'),
        )) {
      throw const FormatException('更新清理事务无效');
    }
  }

  Future<Map<String, String>> _plan(Directory transaction) async {
    await _location(transaction);
    final file = File(p.join(transaction.path, 'plan.txt'));
    await _safe(file.path);
    if (await file.length() > 65536) {
      throw const FormatException('更新计划过大');
    }
    final fields = <String, String>{};
    for (final line in await file.readAsLines()) {
      final separator = line.indexOf('=');
      if (separator <= 0 || fields.containsKey(line.substring(0, separator))) {
        throw const FormatException('更新计划无效');
      }
      fields[line.substring(0, separator)] = line.substring(separator + 1);
    }
    await _fields(transaction, fields);
    return fields;
  }

  Future<void> _fields(
    Directory transaction,
    Map<String, String> fields,
  ) async {
    final nonce = p.basename(transaction.path);
    final root = p.dirname(executable);
    if (fields['nonce'] != nonce ||
        !p.equals(fields['root'] ?? '', root) ||
        !p.equals(
          fields['backup'] ?? '',
          p.join(p.dirname(root), '.hongguo-backup-$nonce'),
        ) ||
        !p.equals(
          fields['stage'] ?? '',
          p.join(p.dirname(root), '.hongguo-stage-$nonce'),
        ) ||
        !p.equals(
          fields['config'] ?? '',
          p.join(support.path, 'shared_preferences.json'),
        )) {
      throw const FormatException('更新清理目录不匹配');
    }
    for (final name in ['root', 'stage', 'backup', 'config']) {
      await _safe(fields[name]!);
    }
    final target = int.tryParse(fields['build'] ?? '');
    final previous = int.tryParse(fields['oldBuild'] ?? '');
    if (target == null || previous == null || target <= previous) {
      throw const FormatException('更新清理版本无效');
    }
  }

  Future<void> _checkCompletion(
    Directory transaction,
    Map<String, String> fields,
  ) async {
    final status = File(p.join(transaction.path, 'status.txt'));
    final ack = File(p.join(transaction.path, 'ack.txt'));
    await _safe(status.path);
    await _safe(ack.path);
    final value = await status.readAsString();
    if (!(value == 'complete' || value.startsWith('complete;')) ||
        await ack.readAsString() != fields['nonce']) {
      throw const FormatException('更新尚未确认成功');
    }
  }

  Future<Map<String, dynamic>> _identity(
    Directory transaction,
    Map<String, String> fields,
  ) async => {
    'schema': 1,
    'nonce': fields['nonce'],
    'root': fields['root'],
    'build': fields['build'],
    for (final name in ['plan.txt', 'old-files.tsv', 'new-files.tsv'])
      name: await _hash(File(p.join(transaction.path, name))),
  };

  Future<void> _writeReceipt(File file, Map<String, dynamic> value) async {
    final pending = File('${file.path}.writing');
    await _safe(pending.path);
    await pending.writeAsString(jsonEncode(value), flush: true);
    await pending.rename(file.path);
  }

  Map<String, String> _storedRecords(Object? value) {
    if (value is! Map || value.isEmpty || value.length > 2048) {
      throw const FormatException('更新清理文件记录无效');
    }
    final result = <String, String>{};
    final aliases = <String>{};
    for (final entry in value.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value as String)) {
        throw const FormatException('更新清理文件记录无效');
      }
      final name = windowsPackagePath(entry.key as String);
      if (!aliases.add(name.toLowerCase())) {
        throw const FormatException('更新清理文件记录重复');
      }
      result[name] = entry.value as String;
    }
    return result;
  }

  Future<void> _validateTree(
    Directory directory,
    Map<String, String> records, {
    required bool allowMissing,
  }) async {
    await _safe(directory.path);
    if (!await directory.exists()) {
      if (allowMissing) return;
      throw const FormatException('更新程序目录缺失');
    }
    final directories = <String>{};
    for (final name in records.keys) {
      for (
        var parent = p.posix.dirname(name);
        parent != '.';
        parent = p.posix.dirname(parent)
      ) {
        directories.add(parent);
      }
    }
    var count = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      await _safe(entry.path);
      final name = p
          .relative(entry.path, from: directory.path)
          .replaceAll('\\', '/');
      if (entry is Directory) {
        if (!directories.contains(name)) {
          throw const FormatException('旧版目录含不属于更新的目录');
        }
      } else if (entry is File && records.containsKey(name)) {
        if (await _hash(entry) != records[name]) {
          throw const FormatException('旧版文件已变化，保留以待确认');
        }
        count++;
      } else {
        throw const FormatException('旧版目录含不属于更新的文件');
      }
    }
    if (!allowMissing && count != records.length) {
      throw const FormatException('程序文件不完整');
    }
  }

  Future<bool> authorize(Directory transaction) async {
    final fields = await _plan(transaction);
    if (fields['build'] != '$build') return false;
    await _checkCompletion(transaction, fields);
    final oldRecords = File(p.join(transaction.path, 'old-files.tsv'));
    final newRecords = File(p.join(transaction.path, 'new-files.tsv'));
    await _safe(oldRecords.path);
    await _safe(newRecords.path);
    final old = await _records(oldRecords);
    final next = await _records(newRecords);
    await _validateTree(Directory(fields['root']!), next, allowMissing: false);
    final receipt = File(p.join(transaction.path, receiptName));
    await _safe(receipt.path);
    if (!await receipt.exists()) {
      await _writeReceipt(receipt, {
        'schema': 1,
        'phase': 'authorized',
        'fields': fields,
        'identity': await _identity(transaction, fields),
        'old': old,
        'next': next,
      });
    }
    return true;
  }

  Future<void> _deleteTree(
    Directory directory,
    Map<String, String> records,
  ) async {
    await _validateTree(directory, records, allowMissing: true);
    if (!await directory.exists()) return;
    for (final entry in records.entries) {
      final file = File(
        p.joinAll([directory.path, ...p.posix.split(entry.key)]),
      );
      await _safe(file.path);
      if (await file.exists()) {
        if (await _hash(file) != entry.value) {
          throw const FormatException('旧版文件在清理前发生变化');
        }
        await file.delete();
      }
    }
    final children = await directory
        .list(recursive: true, followLinks: false)
        .toList();
    children.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final entry in children) {
      await _safe(entry.path);
      if (entry is Directory) await entry.delete();
    }
    await directory.delete();
  }

  Future<bool> _matchingPackage(
    File package,
    Map<String, String> fields,
    Map<String, String> records,
  ) async {
    if (fields.containsKey('packageSha256')) {
      return p.equals(fields['package'] ?? '', package.path) &&
          fields['packageBytes'] == '${await package.length()}' &&
          fields['packageSha256'] == await _hash(package);
    }
    if (await package.length() > 512 * 1024 * 1024) return false;
    final zip = ZipDirectory()
      ..read(InputMemoryStream(await package.readAsBytes()));
    if (zip.fileHeaders.length != records.length) return false;
    final names = <String>{};
    var total = 0;
    for (final header in zip.fileHeaders) {
      final name = windowsPackagePath(header.filename);
      total += header.uncompressedSize;
      if (!names.add(name) ||
          !records.containsKey(name) ||
          header.file == null ||
          header.file!.filename != name ||
          header.uncompressedSize > 256 * 1024 * 1024 ||
          total > 1024 * 1024 * 1024 ||
          header.uncompressedSize > (header.compressedSize + 1) * 500 ||
          header.generalPurposeBitFlag & 1 != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        return false;
      }
      final raw = header.file!.getRawContent();
      Stream<List<int>> chunks() async* {
        for (var index = 0; index < raw.length; index += 65536) {
          yield raw.sublist(index, (index + 65536).clamp(0, raw.length));
        }
      }

      final stream = header.compressionMethod == 8
          ? chunks().transform(io.ZLibDecoder(raw: true))
          : chunks();
      var received = 0;
      Stream<List<int>> limited() async* {
        await for (final chunk in stream) {
          received += chunk.length;
          if (received > header.uncompressedSize) {
            throw const FormatException('更新压缩包解压大小不匹配');
          }
          yield chunk;
        }
      }

      final digest = (await sha256.bind(limited()).first).toString();
      if (received != header.uncompressedSize || digest != records[name]) {
        return false;
      }
    }
    return true;
  }

  Future<bool> retry(Directory transaction) async {
    final lockFile = File(p.join(transaction.path, 'cleanup.lock'));
    RandomAccessFile? lock;
    RandomAccessFile? cacheLock;
    var complete = false;
    final report = <String, dynamic>{
      'nonce': p.basename(transaction.path),
      'build': build,
      'root': p.dirname(executable),
      'complete': false,
    };
    try {
      await _location(transaction);
      await _safe(lockFile.path);
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final receipt = File(p.join(transaction.path, receiptName));
      await _safe(receipt.path);
      if (await receipt.length() > 2 * 1024 * 1024) {
        throw const FormatException('更新清理授权记录过大');
      }
      final recorded =
          jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
      if (recorded['schema'] != 1 ||
          !['authorized', 'finalizing'].contains(recorded['phase'])) {
        throw const FormatException('更新清理授权记录不匹配');
      }
      final fields = Map<String, String>.from(recorded['fields'] as Map);
      await _fields(transaction, fields);
      if (int.parse(fields['build']!) > build) {
        throw const FormatException('当前版本不能清理较新版本的事务');
      }
      final identity = recorded['identity'] as Map;
      if (identity['schema'] != 1 ||
          identity['nonce'] != fields['nonce'] ||
          identity['root'] != fields['root'] ||
          identity['build'] != fields['build']) {
        throw const FormatException('更新清理授权目录不匹配');
      }
      final finalizing = recorded['phase'] == 'finalizing';
      for (final name in ['plan.txt', 'old-files.tsv', 'new-files.tsv']) {
        final file = File(p.join(transaction.path, name));
        await _safe(file.path);
        if (await file.exists()) {
          if (await _hash(file) != identity[name]) {
            throw const FormatException('更新清理原始记录已变化');
          }
        } else if (!finalizing) {
          throw const FormatException('更新清理原始记录缺失');
        }
      }
      final old = _storedRecords(recorded['old']);
      final next = _storedRecords(recorded['next']);
      if (!finalizing) {
        if (jsonEncode(old) !=
                jsonEncode(
                  await _records(
                    File(p.join(transaction.path, 'old-files.tsv')),
                  ),
                ) ||
            jsonEncode(next) !=
                jsonEncode(
                  await _records(
                    File(p.join(transaction.path, 'new-files.tsv')),
                  ),
                )) {
          throw const FormatException('更新清理文件清单不匹配');
        }
        await _checkCompletion(transaction, fields);
        await _deleteTree(Directory(fields['backup']!), old);
        await _deleteTree(Directory(fields['stage']!), next);
        final package = File(p.join(transaction.parent.path, 'pending.zip'));
        await _safe(package.path);
        cacheLock = await lockWindowsUpdateCache(transaction.parent);
        if (await package.exists() &&
            await _matchingPackage(package, fields, next)) {
          await package.delete();
          report['downloadRemoved'] = true;
        }
        await cacheLock.unlock();
        await cacheLock.close();
        cacheLock = null;
      }
      report['backupRemoved'] = true;
      report['stageRemoved'] = true;
      final retained = {
        'plan.txt',
        'old-files.tsv',
        'new-files.tsv',
        'ack.txt',
        'status.txt',
        receiptName,
        'cleanup.lock',
      };
      final owned = {
        ...retained,
        'ready.txt',
        'commit.txt',
        'preferences-backup.json',
        'resume.json',
        'resume-${fields['build']}.txt',
        'startup-${fields['build']}.json',
        'client-diagnostics.jsonl',
        'helper-diagnostics.jsonl',
        'startup-processes.log',
        'started-pids.txt',
        'HongguoTV-updater.exe',
      };
      final entries = await transaction.list(followLinks: false).toList();
      for (final entry in entries) {
        final name = p.basename(entry.path);
        final base = name.endsWith('.writing')
            ? name.substring(0, name.length - '.writing'.length)
            : name;
        await _safe(entry.path);
        if (entry is! File || !owned.contains(base)) {
          throw const FormatException('事务目录含无归属内容，保留以待确认');
        }
        if (retained.contains(name)) continue;
        if (name == 'HongguoTV-updater.exe') {
          final digest = await _hash(entry);
          if (digest != old[name] && digest != next[name]) {
            throw const FormatException('更新助手已变化，保留以待确认');
          }
        }
        await entry.delete();
      }
      if (!finalizing) {
        recorded['phase'] = 'finalizing';
        await _writeReceipt(receipt, recorded);
      }
      await lock.unlock();
      await lock.close();
      lock = null;
      await lockFile.delete();
      for (final name in retained.where(
        (name) => name != 'cleanup.lock' && name != receiptName,
      )) {
        final file = File(p.join(transaction.path, name));
        await _safe(file.path);
        if (await file.exists()) await file.delete();
      }
      await receipt.delete();
      try {
        await transaction.delete();
      } catch (_) {
        if (await transaction.exists() && !await receipt.exists()) {
          await _writeReceipt(receipt, recorded);
        }
        rethrow;
      }
      complete = true;
      report['complete'] = true;
    } catch (error) {
      report['pending'] = error.toString();
    } finally {
      if (cacheLock != null) {
        try {
          await cacheLock.unlock();
        } catch (_) {}
        await cacheLock.close();
      }
      if (lock != null) {
        try {
          await lock.unlock();
        } catch (_) {}
        await lock.close();
      }
      try {
        final file = File(p.join(support.path, 'windows-update-cleanup.json'));
        await _safe(file.path);
        await _writeReceipt(file, report);
      } catch (_) {}
    }
    return complete;
  }
}
