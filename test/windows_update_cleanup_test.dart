import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:duanju_app/windows_update_cleanup.dart';

typedef _CreateFileNative =
    Pointer<Void> Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    );
typedef _CreateFileDart =
    Pointer<Void> Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    );
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);

class CleanupFixture {
  CleanupFixture(this.base);
  final Directory base;
  static const nonce = '0123456789abcdef0123456789abcdef';
  late final support = Directory(p.join(base.path, 'support 中文'));
  late final root = Directory(p.join(base.path, 'program space 中文'));
  late final transaction = Directory(
    p.join(support.path, 'windows-updates', nonce),
  );
  late final backup = Directory(p.join(base.path, '.hongguo-backup-$nonce'));
  late final stage = Directory(p.join(base.path, '.hongguo-stage-$nonce'));
  late final package = File(p.join(transaction.parent.path, 'pending.zip'));
  late final worker = WindowsUpdateCleanup(
    support: support,
    executable: p.join(root.path, 'HongguoTV.exe'),
    build: 62,
  );
  final oldFiles = {
    'HongguoTV.exe': utf8.encode('old application'),
    'HongguoTV-updater.exe': utf8.encode('old updater'),
    'data/app.so': utf8.encode('old snapshot'),
    'windows-package.json': utf8.encode('old manifest'),
  };
  final newFiles = {
    'HongguoTV.exe': utf8.encode('new application'),
    'HongguoTV-updater.exe': utf8.encode('new updater'),
    'data/app.so': utf8.encode('new snapshot'),
    'windows-package.json': utf8.encode('new manifest'),
  };

  Future<void> writeTree(
    Directory directory,
    Map<String, List<int>> files,
  ) async {
    await directory.create(recursive: true);
    for (final entry in files.entries) {
      final file = File(p.join(directory.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value);
    }
  }

  Future<void> initialize({bool legacy = false}) async {
    await writeTree(root, newFiles);
    await writeTree(backup, oldFiles);
    await transaction.create(recursive: true);
    final archive = Archive();
    for (final entry in newFiles.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    await package.writeAsBytes(ZipEncoder().encode(archive));
    await File(
      p.join(support.path, 'shared_preferences.json'),
    ).writeAsString('personal settings and history');
    final fields = {
      'root': root.path,
      'stage': stage.path,
      'backup': backup.path,
      'nonce': nonce,
      'build': '62',
      'oldBuild': '61',
      'config': p.join(support.path, 'shared_preferences.json'),
      if (!legacy) ...{
        'package': package.path,
        'packageBytes': '${await package.length()}',
        'packageSha256': sha256.convert(await package.readAsBytes()).toString(),
      },
    };
    await File(p.join(transaction.path, 'plan.txt')).writeAsString(
      fields.entries.map((entry) => '${entry.key}=${entry.value}').join('\n'),
    );
    for (final (name, files) in [
      ('old-files.tsv', oldFiles),
      ('new-files.tsv', newFiles),
    ]) {
      await File(p.join(transaction.path, name)).writeAsString(
        files.entries
            .map((entry) => '${sha256.convert(entry.value)}\t${entry.key}\n')
            .join(),
      );
    }
    await File(p.join(transaction.path, 'ack.txt')).writeAsString(nonce);
    await File(
      p.join(transaction.path, 'status.txt'),
    ).writeAsString('complete; accepted');
    await File(
      p.join(transaction.path, 'HongguoTV-updater.exe'),
    ).writeAsBytes(oldFiles['HongguoTV-updater.exe']!);
    await File(
      p.join(transaction.path, 'preferences-backup.json'),
    ).writeAsString('old settings');
    await File(
      p.join(transaction.path, 'startup-processes.log'),
    ).writeAsString('startup evidence');
  }

  Future<void> expectUserData() async {
    expect(
      await File(
        p.join(support.path, 'shared_preferences.json'),
      ).readAsString(),
      'personal settings and history',
    );
    expect(
      await File(p.join(root.path, 'HongguoTV.exe')).readAsBytes(),
      newFiles['HongguoTV.exe'],
    );
  }
}

void main() {
  late Directory temporary;
  late CleanupFixture fixture;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('update-cleanup-');
    fixture = CleanupFixture(temporary);
  });
  tearDown(() async => temporary.delete(recursive: true));

  for (final legacy in [false, true]) {
    test(
      'completed update removes only owned payload legacy=$legacy',
      () async {
        await fixture.initialize(legacy: legacy);
        final personal = File(
          p.join(temporary.path, 'unknown.back', 'notes.txt'),
        );
        await personal.parent.create();
        await personal.writeAsString('keep');
        expect(await fixture.worker.authorize(fixture.transaction), isTrue);
        expect(await fixture.worker.retry(fixture.transaction), isTrue);
        expect(await fixture.backup.exists(), isFalse);
        expect(await fixture.package.exists(), isFalse);
        expect(await fixture.transaction.exists(), isFalse);
        expect(await personal.readAsString(), 'keep');
        await fixture.expectUserData();
      },
    );
  }

  test(
    'failure and missing acknowledgement cannot authorize cleanup',
    () async {
      await fixture.initialize();
      for (final status in ['starting', 'failed: startup crash']) {
        await File(
          p.join(fixture.transaction.path, 'status.txt'),
        ).writeAsString(status);
        await expectLater(
          fixture.worker.authorize(fixture.transaction),
          throwsFormatException,
        );
        expect(await fixture.backup.exists(), isTrue);
        expect(await fixture.package.exists(), isTrue);
      }
      await File(
        p.join(fixture.transaction.path, 'status.txt'),
      ).writeAsString('complete');
      await File(
        p.join(fixture.transaction.path, 'ack.txt'),
      ).writeAsString('wrong');
      await expectLater(
        fixture.worker.authorize(fixture.transaction),
        throwsFormatException,
      );
      await fixture.expectUserData();
    },
  );

  test('unowned or modified backup files withhold backup deletion', () async {
    await fixture.initialize();
    await fixture.worker.authorize(fixture.transaction);
    final personal = File(p.join(fixture.backup.path, 'personal.txt'));
    await personal.writeAsString('keep');
    expect(await fixture.worker.retry(fixture.transaction), isFalse);
    expect(await personal.readAsString(), 'keep');
    expect(await fixture.package.exists(), isTrue);
    await personal.delete();
    await File(
      p.join(fixture.backup.path, 'HongguoTV.exe'),
    ).writeAsString('changed');
    expect(await fixture.worker.retry(fixture.transaction), isFalse);
    expect(
      await File(p.join(fixture.backup.path, 'HongguoTV.exe')).readAsString(),
      'changed',
    );
    await fixture.expectUserData();
  });

  test(
    'replacement download and next partial download are preserved',
    () async {
      await fixture.initialize();
      await fixture.worker.authorize(fixture.transaction);
      await fixture.package.writeAsString('next version package');
      final partial = File('${fixture.package.path}.part');
      await partial.writeAsString('next download');
      expect(await fixture.worker.retry(fixture.transaction), isTrue);
      expect(await fixture.package.readAsString(), 'next version package');
      expect(await partial.readAsString(), 'next download');
      await fixture.expectUserData();
    },
  );

  test(
    'changed plan, wrong namespace and unowned transaction are retained',
    () async {
      await fixture.initialize();
      await fixture.worker.authorize(fixture.transaction);
      final plan = File(p.join(fixture.transaction.path, 'plan.txt'));
      await plan.writeAsString('${await plan.readAsString()}\nextra=changed');
      expect(await fixture.worker.retry(fixture.transaction), isFalse);
      expect(await fixture.backup.exists(), isTrue);
      final outside = Directory(p.join(temporary.path, CleanupFixture.nonce));
      await outside.create();
      await expectLater(
        fixture.worker.authorize(outside),
        throwsFormatException,
      );
      await fixture.expectUserData();
    },
  );

  test('a later client can resume an existing authorized receipt', () async {
    await fixture.initialize();
    await fixture.worker.authorize(fixture.transaction);
    await File(
      p.join(fixture.root.path, 'HongguoTV.exe'),
    ).writeAsString('later application');
    final later = WindowsUpdateCleanup(
      support: fixture.support,
      executable: p.join(fixture.root.path, 'HongguoTV.exe'),
      build: 63,
    );
    expect(await later.retry(fixture.transaction), isTrue);
    expect(
      await File(p.join(fixture.root.path, 'HongguoTV.exe')).readAsString(),
      'later application',
    );
    expect(
      await File(
        p.join(fixture.support.path, 'shared_preferences.json'),
      ).readAsString(),
      'personal settings and history',
    );
  });

  test('a link inside the backup cannot delete its target', () async {
    await fixture.initialize();
    await fixture.worker.authorize(fixture.transaction);
    final personal = File(p.join(temporary.path, 'personal.txt'));
    await personal.writeAsString('keep');
    final link = Link(p.join(fixture.backup.path, 'external'));
    try {
      await link.create(personal.path);
    } on FileSystemException catch (error) {
      markTestSkipped('当前环境不能创建符号链接：$error');
      return;
    }
    expect(await fixture.worker.retry(fixture.transaction), isFalse);
    expect(await personal.readAsString(), 'keep');
  });

  test('unowned transaction contents are never deleted', () async {
    await fixture.initialize();
    await fixture.worker.authorize(fixture.transaction);
    final personal = File(p.join(fixture.transaction.path, 'personal.txt'));
    await personal.writeAsString('keep');
    expect(await fixture.worker.retry(fixture.transaction), isFalse);
    expect(await personal.readAsString(), 'keep');
    await personal.delete();
    expect(await fixture.worker.retry(fixture.transaction), isTrue);
  });

  test(
    'locked core metadata resumes after partial finalization on Windows',
    () async {
      await fixture.initialize();
      await fixture.worker.authorize(fixture.transaction);
      final kernel = DynamicLibrary.open('kernel32.dll');
      final create = kernel.lookupFunction<_CreateFileNative, _CreateFileDart>(
        'CreateFileW',
      );
      final close = kernel.lookupFunction<_CloseNative, _CloseDart>(
        'CloseHandle',
      );
      final path = p
          .join(fixture.transaction.path, 'old-files.tsv')
          .toNativeUtf16();
      final handle = create(path, 0x80000000, 1, nullptr, 3, 0, nullptr);
      calloc.free(path);
      expect(handle.address, isNot(-1));
      try {
        expect(await fixture.worker.retry(fixture.transaction), isFalse);
        expect(await fixture.backup.exists(), isFalse);
        final receipt =
            jsonDecode(
                  await File(
                    p.join(
                      fixture.transaction.path,
                      WindowsUpdateCleanup.receiptName,
                    ),
                  ).readAsString(),
                )
                as Map;
        expect(receipt['phase'], 'finalizing');
        expect(
          await File(p.join(fixture.transaction.path, 'plan.txt')).exists(),
          isFalse,
        );
      } finally {
        close(handle);
      }
      expect(await fixture.worker.retry(fixture.transaction), isTrue);
      expect(await fixture.transaction.exists(), isFalse);
      await fixture.expectUserData();
    },
    skip: !Platform.isWindows,
  );

  test(
    'Windows download lease withholds cleanup until download releases it',
    () async {
      await fixture.initialize();
      await fixture.worker.authorize(fixture.transaction);
      final lease = await lockWindowsUpdateCache(fixture.transaction.parent);
      try {
        expect(await fixture.worker.retry(fixture.transaction), isFalse);
        expect(await fixture.package.exists(), isTrue);
      } finally {
        await lease.unlock();
        await lease.close();
      }
      expect(await fixture.worker.retry(fixture.transaction), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'locked transaction directory retains finalization authorization',
    () async {
      await fixture.initialize();
      await fixture.worker.authorize(fixture.transaction);
      final kernel = DynamicLibrary.open('kernel32.dll');
      final create = kernel.lookupFunction<_CreateFileNative, _CreateFileDart>(
        'CreateFileW',
      );
      final close = kernel.lookupFunction<_CloseNative, _CloseDart>(
        'CloseHandle',
      );
      final path = fixture.transaction.path.toNativeUtf16();
      final handle = create(
        path,
        0x80000000,
        3,
        nullptr,
        3,
        0x02000000,
        nullptr,
      );
      calloc.free(path);
      expect(handle.address, isNot(-1));
      try {
        expect(await fixture.worker.retry(fixture.transaction), isFalse);
        expect(
          await File(
            p.join(fixture.transaction.path, WindowsUpdateCleanup.receiptName),
          ).exists(),
          isTrue,
        );
      } finally {
        close(handle);
      }
      expect(await fixture.worker.retry(fixture.transaction), isTrue);
      expect(await fixture.transaction.exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
