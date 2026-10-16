import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:duanju_app/windows_update_package.dart';
import 'package:duanju_app/windows_update_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pe() {
  final bytes = Uint8List(512);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 77;
  bytes[1] = 90;
  data.setUint32(60, 128, Endian.little);
  data.setUint32(128, 0x4550, Endian.little);
  data.setUint16(132, 0x8664, Endian.little);
  data.setUint16(152, 0x20b, Endian.little);
  return bytes;
}

void main() {
  for (final name in [
    '../a',
    '/a',
    'a\\b',
    'c:/a',
    'a:ads',
    'a/../b',
    'a/./b',
    'NUL.txt',
    'COM1',
    'LPT9.dat',
    'a.',
    'a ',
    'a//b',
    'a\nb',
  ]) {
    test('reject unsafe ZIP path ${jsonEncode(name)}', () {
      expect(() => windowsPackagePath(name), throwsFormatException);
    });
  }

  late Directory temporary;
  late Map<String, List<int>> files;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'hongguo-update-package-',
    );
    files = {
      'HongguoTV.exe': pe(),
      'HongguoTV-updater.exe': pe(),
      for (final name in [
        'flutter_windows.dll',
        'duanju_core.dll',
        'libmpv-2.dll',
        'libffmpegkit.dll',
        'data/app.so',
        'data/icudtl.dat',
      ])
        name: [1, 2, 3],
    };
  });
  tearDown(() async {
    WindowsUpdateRuntime.playing = null;
    WindowsUpdateRuntime.restarting = false;
    await temporary.delete(recursive: true);
  });
  Future<void> package({
    String version = '0.1.15-preview.1',
    int build = 39,
    String architecture = 'x64',
    void Function(Archive)? change,
  }) async {
    final manifest = {
      'schema': 1,
      'version': version,
      'build': build,
      'architecture': architecture,
      'files': {
        for (final entry in files.entries)
          entry.key: {
            'bytes': entry.value.length,
            'sha256': sha256.convert(entry.value).toString(),
          },
      },
    };
    final archive = Archive();
    for (final entry in files.entries)
      archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
    archive.add(
      ArchiveFile.string('windows-package.json', jsonEncode(manifest)),
    );
    change?.call(archive);
    await File(
      '${temporary.path}/pending.zip',
    ).writeAsBytes(ZipEncoder().encode(archive, level: 9));
  }

  Future<Map<String, dynamic>> extract() => extractWindowsPackage(
    zipPath: '${temporary.path}/pending.zip',
    stagePath: '${temporary.path}/stage',
    version: '0.1.15-preview.1',
    build: 39,
  );

  test('extracts complete manifest and checks every file', () async {
    await package();
    final result = await extract();
    expect(result['build'], 39);
    expect(await File('${temporary.path}/stage/data/app.so').readAsBytes(), [
      1,
      2,
      3,
    ]);
  });
  test(
    'rejects wrong version, build and architecture and removes staging files',
    () async {
      for (final args in [0, 1, 2]) {
        await package(
          version: args == 0 ? '0.1.14-preview.1' : '0.1.15-preview.1',
          build: args == 1 ? 38 : 39,
          architecture: args == 2 ? 'arm64' : 'x64',
        );
        await expectLater(extract(), throwsFormatException);
        expect(await Directory('${temporary.path}/stage').exists(), isFalse);
      }
    },
  );
  test(
    'rejects symlinks, case aliases, unowned files and content tampering',
    () async {
      for (var kind = 0; kind < 4; kind++) {
        await package(
          change: (archive) {
            final file = ArchiveFile.string(
              kind == 1 ? 'hongguotv.exe' : 'extra.txt',
              'x',
            );
            if (kind == 0) file.mode = 0xa1ff;
            if (kind == 3) archive.find('data/app.so')!.content[0] = 9;
            archive.add(file);
          },
        );
        await expectLater(extract(), throwsFormatException);
        expect(await Directory('${temporary.path}/stage').exists(), isFalse);
      }
    },
  );
  test('rejects compressed bomb before extracting', () async {
    files['bomb'] = List.filled(2 * 1024 * 1024, 0);
    await package();
    await expectLater(extract(), throwsFormatException);
  });
  test('rejects wrong PE machine and missing runtime dependency', () async {
    files['HongguoTV.exe']![132] = 0x4c;
    await package();
    await expectLater(extract(), throwsFormatException);
    files['HongguoTV.exe'] = pe();
    files.remove('libmpv-2.dll');
    await package();
    await expectLater(extract(), throwsFormatException);
  });
  test(
    'playing defers installation without filesystem or process side effects',
    () async {
      WindowsUpdateRuntime.playing = () => true;
      expect(
        await WindowsUpdateRuntime.install(
          zipPath: 'nonexistent.zip',
          version: '0.1.15-preview.1',
          build: 39,
        ),
        'playing',
      );
      expect(WindowsUpdateRuntime.restarting, isFalse);
    },
  );
}
