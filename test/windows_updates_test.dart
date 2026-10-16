import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_updates_test.dart'
    show FakeUpdatePlatform, FakeUpdateTransport, installed, releaseJson;
import 'app_update_transport_test.dart' show TestClient, TestResponse;

Map<String, dynamic> windowsRelease({int build = 38}) {
  const version = '0.1.13-preview.2';
  final tag = 'windows-v$version-$build';
  const name = 'HongguoTV-$version-windows-x64.zip';
  return {
    'draft': false,
    'prerelease': true,
    'tag_name': tag,
    'body': 'Windows 更新日志',
    'assets': [
      {
        'name': name,
        'size': 4,
        'state': 'uploaded',
        'digest': 'sha256:${sha256.convert([1, 2, 3, 4])}',
        'browser_download_url':
            'https://github.com/$updateRepository/releases/download/$tag/$name',
      },
    ],
  };
}

class DirectoryWindowsPlatform extends WindowsUpdatePlatform {
  DirectoryWindowsPlatform(this.path);
  final String path;
  @override
  Future<String> directory() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowsInstalled = InstalledApp(
    version: '0.1.13-preview.1',
    code: 37,
    abi: 'windows-x64',
  );
  test('Windows and Android refuse each other tags and release channels', () {
    final data = windowsRelease();
    expect(() => AppRelease.parse(data, installed), throwsFormatException);
    expect(
      () => AppRelease.parse({...data, 'prerelease': false}, installed),
      throwsFormatException,
    );
    expect(
      () => AppRelease.parseWindows(releaseJson(), windowsInstalled),
      throwsFormatException,
    );
    expect(
      () => AppRelease.parseWindows({
        ...data,
        'prerelease': false,
      }, windowsInstalled),
      throwsFormatException,
    );
    expect(AppRelease.parseWindows(data, windowsInstalled)!.code, 38);
    expect(
      AppRelease.parseWindows(windowsRelease(build: 37), windowsInstalled),
      isNull,
    );
    expect(
      AppRelease.parseWindows(windowsRelease(build: 36), windowsInstalled),
      isNull,
    );
    final assets = data['assets'] as List;
    for (final replacement in [
      {...assets.single as Map, 'name': 'HongguoTV.exe'},
      {
        ...assets.single as Map,
        'browser_download_url': 'https://evil.test/a.zip',
      },
      {...assets.single as Map, 'digest': 'sha256:bad'},
      {...assets.single as Map, 'state': 'new'},
      {...assets.single as Map, 'size': 0},
    ]) {
      expect(
        () => AppRelease.parseWindows({
          ...data,
          'assets': [replacement],
        }, windowsInstalled),
        throwsFormatException,
      );
    }
    expect(
      () => AppRelease.parseWindows({
        ...data,
        'assets': [assets.single, assets.single],
      }, windowsInstalled),
      throwsFormatException,
    );
  });
  test(
    'release listing selects newest Windows build regardless of ordering',
    () async {
      final newest = windowsRelease(build: 40);
      final data = [
        windowsRelease(),
        releaseJson(build: 99),
        {...windowsRelease(build: 41), 'draft': true},
        newest,
      ];
      expect(selectWindowsRelease(data)['tag_name'], newest['tag_name']);
      expect(
        () => selectWindowsRelease([releaseJson()]),
        throwsFormatException,
      );
      final client = TestClient([
        TestResponse([utf8.encode(jsonEncode(data))]),
      ]);
      final transport = GithubUpdateTransport(
        windows: true,
        clientFactory: () => client,
      );
      expect((await transport.latest())['tag_name'], newest['tag_name']);
      expect(client.urls.single.toString(), windowsUpdateApi);
    },
  );
  test(
    'Windows uses separate cache, ZIP downloads and manual folder action',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'windows-update-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        'app_update_stable_cache_v1': jsonEncode(releaseJson()),
      });
      final preferences = await SharedPreferences.getInstance();
      final transport = FakeUpdateTransport();
      final platform = FakeUpdatePlatform(temporary.path)
        ..app = windowsInstalled;
      final lookup = windowsRelease();
      final updates = AppUpdates(
        preferences: preferences,
        windows: true,
        supportedEdition: true,
        transport: _WindowsTransport(transport, lookup),
        platform: platform,
      );
      addTearDown(updates.dispose);
      await updates.check();
      expect(updates.stage, UpdateStage.available);
      expect(
        preferences.getString('app_update_stable_cache_v1'),
        jsonEncode(releaseJson()),
      );
      await updates.download();
      expect(updates.stage, UpdateStage.ready);
      expect(await File('${temporary.path}/pending.zip').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(await File('${temporary.path}/pending.apk').exists(), isFalse);
      await updates.install();
      expect(updates.stage, UpdateStage.ready);
      expect(platform.installs, 1);
      expect(platform.permissions, 0);
      expect(preferences.getInt('app_update_installing_code'), isNull);
    },
  );
  test(
    'Windows rejects ZIP corruption before exposing download location',
    () async {
      final temporary = await Directory.systemTemp.createTemp('windows-hash-');
      addTearDown(() => temporary.delete(recursive: true));
      final platform = DirectoryWindowsPlatform(temporary.path);
      final release = AppRelease.parseWindows(
        windowsRelease(),
        windowsInstalled,
      )!;
      final file = File('${temporary.path}/pending.zip');
      await file.writeAsBytes([1, 2, 3, 4]);
      await platform.validate(release);
      await file.writeAsBytes([4, 3, 2, 1]);
      await expectLater(platform.validate(release), throwsFormatException);
      await file.writeAsBytes([1, 2]);
      await expectLater(platform.validate(release), throwsFormatException);
    },
  );
}

class _WindowsTransport implements UpdateTransport {
  _WindowsTransport(this.delegate, this.data);
  final FakeUpdateTransport delegate;
  final Map<String, dynamic> data;
  @override
  Future<Map<String, dynamic>> latest() async => data;
  @override
  Future<void> download(
    AppRelease release,
    File output,
    void Function(int) progress,
  ) => delegate.download(release, output, progress);
  @override
  void cancel() => delegate.cancel();
}
