import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['CHECK_LIVE_UPDATE'] == 'true';
  test(
    'published update metadata and downloads match every installed ABI',
    () async {
      HttpOverrides.global = null;
      final metadataPath = Platform.environment['UPDATE_METADATA_FILE'];
      final transport = GithubUpdateTransport();
      final data = metadataPath == null
          ? await transport.latest()
          : jsonDecode(await File(metadataPath).readAsString())
                as Map<String, dynamic>;
      final staging = Platform.environment['CHECK_STAGED_UPDATE'] == 'true';
      expect(data['draft'], false);
      expect(data['prerelease'], staging);
      final expectedTag = Platform.environment['EXPECTED_UPDATE_TAG']!;
      expect(data['tag_name'], expectedTag);
      final expected = RegExp(
        r'^app-v(\d+\.\d+\.\d+)-(\d+)$',
      ).firstMatch(expectedTag)!;
      final stableData = Map<String, dynamic>.of(data)..['prerelease'] = false;
      final download = Platform.environment['CHECK_UPDATE_DOWNLOAD'] == 'true';
      final directory = Directory('dist/update-check');
      await directory.create(recursive: true);
      final results = <Map<String, Object>>[];
      for (final entry in updateAbiOffsets.entries) {
        final installed = InstalledApp(
          version: '0.1.11',
          code: entry.value + 35,
          abi: entry.key,
        );
        final release = AppRelease.parse(stableData, installed);
        expect(release, isNotNull);
        expect(release!.version, expected[1]);
        expect(release.code, entry.value + int.parse(expected[2]!));
        expect(
          AppRelease.parse(
            stableData,
            InstalledApp(
              version: release.version,
              code: release.code,
              abi: entry.key,
            ),
          ),
          isNull,
        );
        if (download) {
          final file = File(
            '${directory.path}/HongguoTV-${release.version}-${entry.key}.apk',
          );
          await transport.download(release, file, (_) {});
          expect(await file.length(), release.bytes);
          final digest = await sha256.bind(file.openRead()).first;
          expect(digest.toString(), release.sha256);
        }
        results.add({
          'abi': entry.key,
          'code': release.code,
          'url': release.url.toString(),
          'bytes': release.bytes,
          'sha256': release.sha256,
          'downloadVerified': download,
        });
      }
      final report = File(
        '${directory.path}/${staging ? 'staged' : 'latest'}-update-check.json',
      );
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
