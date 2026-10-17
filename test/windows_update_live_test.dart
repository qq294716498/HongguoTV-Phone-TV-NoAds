import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_update_transport_test.dart'
    show TestClient, TestRequest, TestResponse;

class RateLimitedWindowsClient extends TestClient {
  RateLimitedWindowsClient(this.delegate) : super([]);
  final HttpClient delegate;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (url.toString() == windowsUpdateApi) {
      return TestRequest(TestResponse([], statusCode: 403));
    }
    return delegate.getUrl(url);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

void main() {
  test(
    'public Windows ZIP downloads through updater and Android latest stays isolated',
    () async {
      HttpOverrides.global = null;
      HttpClient client() =>
          HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
      final windows = GithubUpdateTransport(
        windows: true,
        clientFactory: client,
      );
      final metadata = await windows.latest();
      final expectedTag = Platform.environment['EXPECTED_WINDOWS_TAG']!;
      expect(metadata['tag_name'], expectedTag);
      final release = AppRelease.parseWindows(
        metadata,
        const InstalledApp(version: '0.1.15', code: 40, abi: 'windows-x64'),
      )!;
      final fallback = await GithubUpdateTransport(
        windows: true,
        clientFactory: () => RateLimitedWindowsClient(client()),
      ).latest();
      expect(fallback['tag_name'], expectedTag);
      final fallbackRelease = AppRelease.parseWindows(
        fallback,
        const InstalledApp(version: '0.1.15', code: 40, abi: 'windows-x64'),
      )!;
      expect(fallbackRelease.validation, release.validation);
      expect(release.code, int.parse(expectedTag.split('-').last));
      expect(metadata['prerelease'], false);
      expect(
        AppRelease.parseWindows(
          metadata,
          InstalledApp(
            version: release.version,
            code: release.code,
            abi: 'windows-x64',
          ),
        ),
        isNull,
      );
      for (final abi in updateAbiOffsets.keys) {
        final installed = InstalledApp(
          version: '0.1.16',
          code: updateAbiOffsets[abi]! + 41,
          abi: abi,
        );
        expect(
          () => AppRelease.parse(metadata, installed),
          throwsFormatException,
        );
        expect(
          () => AppRelease.parse({...metadata, 'prerelease': false}, installed),
          throwsFormatException,
        );
      }
      final directory = Directory('dist/windows');
      await directory.create(recursive: true);
      final file = File('${directory.path}/updater-download.zip');
      await windows.download(release, file, (_) {});
      expect(await file.length(), release.bytes);
      final digest = (await sha256.bind(file.openRead()).first).toString();
      expect(digest, release.sha256);
      final android = await GithubUpdateTransport(
        clientFactory: client,
      ).latest();
      expect(android['tag_name'], Platform.environment['EXPECTED_ANDROID_TAG']);
      expect(android['prerelease'], false);
      for (final abi in updateAbiOffsets.keys) {
        expect(
          AppRelease.parse(
            android,
            InstalledApp(
              version: '0.1.16',
              code: updateAbiOffsets[abi]! + 41,
              abi: abi,
            ),
          ),
          isNull,
        );
      }
      await File('${directory.path}/Windows-update-check.json').writeAsString(
        jsonEncode({
          'ok': true,
          'windowsTag': expectedTag,
          'androidLatest': android['tag_name'],
          'downloadBytes': release.bytes,
          'downloadSha256': digest,
          'sameBuildIgnored': true,
          'androidRejectsWindowsTag': true,
          'windowsPrerelease': false,
          'rateLimitFallbackVerified': true,
          'realCrossVersionInstallationTested': false,
        }),
      );
      await file.delete();
    },
    skip: Platform.environment['CHECK_WINDOWS_UPDATE'] != 'true',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
