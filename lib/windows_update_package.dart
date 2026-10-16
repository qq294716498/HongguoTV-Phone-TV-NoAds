import 'dart:convert';
import 'dart:io' hide ZLibDecoder;
import 'dart:io' as io show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String windowsPackagePath(String name) {
  final parts = name.split('/');
  if (name.isEmpty ||
      name.length > 230 ||
      name.contains('\\') ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(r'[<>:"|?*\x00-\x1f\x7f]').hasMatch(part) ||
            RegExp(
              r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw const FormatException('压缩包包含不安全的 Windows 路径');
  }
  return name;
}

void validateWindowsPe(Uint8List bytes) {
  if (bytes.length < 64 || bytes[0] != 77 || bytes[1] != 90) {
    throw const FormatException('更新程序不是 Windows PE');
  }
  final data = ByteData.sublistView(bytes);
  final offset = data.getUint32(60, Endian.little);
  if (offset + 26 > bytes.length ||
      data.getUint32(offset, Endian.little) != 0x4550 ||
      data.getUint16(offset + 4, Endian.little) != 0x8664 ||
      data.getUint16(offset + 24, Endian.little) != 0x20b) {
    throw const FormatException('更新程序架构必须为 Windows x64');
  }
}

Future<Map<String, dynamic>> extractWindowsPackage({
  required String zipPath,
  required String stagePath,
  required String version,
  required int build,
}) async {
  final stage = Directory(stagePath);
  if (await FileSystemEntity.type(stagePath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('更新暂存目录已存在');
  }
  final zip = File(zipPath);
  if (await zip.length() > 512 * 1024 * 1024) {
    throw const FormatException('更新压缩包过大');
  }
  final directory = ZipDirectory()
    ..read(InputMemoryStream(await zip.readAsBytes()));
  final names = <String>{};
  var total = 0;
  if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 2048) {
    throw const FormatException('更新压缩包文件数量异常');
  }
  for (final header in directory.fileHeaders) {
    final name = windowsPackagePath(header.filename);
    final mode = (header.externalFileAttributes >> 16) & 0xf000;
    total += header.uncompressedSize;
    if (!names.add(name.toLowerCase()) ||
        (mode != 0 && mode != 0x8000) ||
        header.externalFileAttributes & 0x410 != 0 ||
        header.generalPurposeBitFlag & 1 != 0 ||
        header.file == null ||
        header.file!.filename != name ||
        ![0, 8].contains(header.compressionMethod) ||
        header.uncompressedSize > 256 * 1024 * 1024 ||
        total > 1024 * 1024 * 1024 ||
        header.uncompressedSize > (header.compressedSize + 1) * 500) {
      throw const FormatException('更新压缩包含重复、链接、加密或过量内容');
    }
  }
  await stage.create();
  try {
    for (final header in directory.fileHeaders) {
      final file = File(p.join(stagePath, header.filename));
      await file.parent.create(recursive: true);
      final compressed = header.file!.getRawContent();
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < compressed.length; i += 65536) {
          yield Uint8List.sublistView(
            compressed,
            i,
            (i + 65536).clamp(0, compressed.length),
          );
        }
      }

      final stream = header.compressionMethod == 8
          ? chunks().transform(io.ZLibDecoder(raw: true))
          : chunks();
      var received = 0;
      var crc = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in stream) {
          received += chunk.length;
          if (received > header.uncompressedSize) {
            throw const FormatException('更新解压内容超出声明大小');
          }
          crc = getCrc32(chunk, crc);
          sink.add(chunk);
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
      if (received != header.uncompressedSize || crc != header.crc32) {
        throw const FormatException('更新压缩包 CRC 或大小错误');
      }
    }
    final manifest = await validateWindowsDirectory(stage, version, build);
    return manifest;
  } catch (_) {
    await stage.delete(recursive: true);
    rethrow;
  }
}

Future<Map<String, dynamic>> validateWindowsDirectory(
  Directory directory,
  String version,
  int build,
) async {
  final manifestFile = File(p.join(directory.path, 'windows-package.json'));
  if (await manifestFile.length() > 1024 * 1024) {
    throw const FormatException('更新清单过大');
  }
  final manifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final files = manifest['files'];
  if (manifest['schema'] != 1 ||
      manifest['version'] != version ||
      manifest['build'] != build ||
      manifest['architecture'] != 'x64' ||
      files is! Map<String, dynamic> ||
      files.isEmpty ||
      files.length > 2048) {
    throw const FormatException('更新版本、架构或清单不匹配');
  }
  final names = <String>{'windows-package.json'};
  for (final entry in files.entries) {
    final name = windowsPackagePath(entry.key);
    if (!names.add(name.toLowerCase()) || entry.value is! Map) {
      throw const FormatException('更新清单路径重复');
    }
    final record = entry.value as Map;
    final file = File(p.join(directory.path, name));
    if (record['bytes'] is! int ||
        record['sha256'] is! String ||
        await file.length() != record['bytes'] ||
        (await sha256.bind(file.openRead()).first).toString() !=
            record['sha256']) {
      throw FormatException('更新文件校验失败：$name');
    }
  }
  await for (final entry in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entry is Link ||
        (entry is File &&
            !names.contains(
              p
                  .relative(entry.path, from: directory.path)
                  .replaceAll('\\', '/')
                  .toLowerCase(),
            ))) {
      throw const FormatException('程序目录含不属于安装包的文件，请使用独立应用目录');
    }
  }
  for (final name in ['HongguoTV.exe', 'HongguoTV-updater.exe']) {
    if (!files.containsKey(name)) throw const FormatException('缺少更新启动程序');
    final file = File(p.join(directory.path, name));
    final handle = await file.open();
    try {
      validateWindowsPe(await handle.read(4096));
    } finally {
      await handle.close();
    }
  }
  for (final name in [
    'flutter_windows.dll',
    'duanju_core.dll',
    'libmpv-2.dll',
    'libffmpegkit.dll',
    'data/app.so',
    'data/icudtl.dat',
  ]) {
    if (!files.containsKey(name)) throw FormatException('更新包缺少运行依赖：$name');
  }
  return manifest;
}
