import 'dart:async';
import 'dart:io';

import 'package:duanju_app/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const installed = InstalledApp(version: '0.1.5', code: 2027, abi: 'arm64-v8a');
Map<String, dynamic> releaseJson({
  String abi = 'arm64-v8a',
  int build = 28,
}) => {
  'draft': false,
  'prerelease': false,
  'tag_name': 'app-v0.1.6-$build',
  'body': '修复与安全更新',
  'assets': [
    {
      'name': 'HongguoTV-0.1.6-$abi.apk',
      'size': 4,
      'state': 'uploaded',
      'digest': 'sha256:${'a' * 64}',
      'browser_download_url':
          'https://github.com/$updateRepository/releases/download/app-v0.1.6-$build/HongguoTV-0.1.6-$abi.apk',
    },
  ],
};

class FakeUpdateTransport implements UpdateTransport {
  int checks = 0;
  int downloads = 0;
  int cancellations = 0;
  int progressBurst = 0;
  Object? failure;
  Completer<void>? gate;
  Completer<Map<String, dynamic>>? lookup;
  @override
  Future<Map<String, dynamic>> latest() async {
    checks++;
    if (failure != null) throw failure!;
    return lookup?.future ?? releaseJson();
  }

  @override
  Future<void> download(
    AppRelease release,
    File output,
    void Function(int) progress,
  ) async {
    downloads++;
    for (var i = 0; i < progressBurst; i++) {
      progress(1);
    }
    progress(2);
    await gate?.future;
    if (failure != null) throw failure!;
    await output.writeAsBytes([1, 2, 3, 4]);
    progress(4);
  }

  @override
  void cancel() {
    cancellations++;
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }
}

class FakeUpdatePlatform implements UpdatePlatform {
  FakeUpdatePlatform(this.path);
  final String path;
  int validations = 0;
  int installs = 0;
  int permissions = 0;
  bool allowed = false;
  Object? validationFailure;
  String installResult = 'cancelled';
  InstalledApp app = const InstalledApp(
    version: '0.1.5',
    code: 2027,
    abi: 'arm64-v8a',
  );
  Completer<InstalledApp>? installedGate;
  Completer<String>? directoryGate;
  Completer<void>? validationGate;
  Completer<bool>? permissionGate;
  @override
  Future<InstalledApp> installed() async => installedGate?.future ?? app;
  @override
  Future<String> directory() async => directoryGate?.future ?? path;
  @override
  Future<void> validate(AppRelease release) async {
    validations++;
    await validationGate?.future;
    if (validationFailure != null) throw validationFailure!;
  }

  @override
  Future<bool> canInstall() async => permissionGate?.future ?? allowed;
  @override
  Future<void> openPermission() async {
    permissions++;
  }

  @override
  Future<String> install(AppRelease release) async {
    installs++;
    return installResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('release policy', () {
    test('selects exact installed ABI and increments actual code', () {
      for (final abi in updateAbiOffsets.keys) {
        final app = InstalledApp(
          version: '0.1.2-dev.1',
          code: updateAbiOffsets[abi]! + 27,
          abi: abi,
        );
        final candidate = AppRelease.parse(releaseJson(abi: abi), app)!;
        expect(candidate.abi, abi);
        expect(candidate.code, app.code + 1);
      }
    });
    test(
      'ignores same or lower actual version code regardless of displayed name',
      () {
        expect(AppRelease.parse(releaseJson(build: 27), installed), isNull);
        expect(AppRelease.parse(releaseJson(build: 26), installed), isNull);
      },
    );
    test('rejects draft, prerelease, unsupported tags and missing APK', () {
      for (final change in <Map<String, dynamic>>[
        {'draft': true},
        {'prerelease': true},
        {'draft': null},
        {'tag_name': 'v0.2.0'},
        {'tag_name': 'app-v0.2.0-1000'},
        {'assets': []},
        {'assets': null},
      ]) {
        expect(
          () => AppRelease.parse({...releaseJson(), ...change}, installed),
          throwsFormatException,
        );
      }
      expect(
        () => AppRelease.parse(releaseJson(abi: 'x86_64'), installed),
        throwsFormatException,
      );
    });
    test(
      'rejects missing/bad hash, wrong origin, name, size and duplicate assets',
      () {
        for (final change in <Map<String, dynamic>>[
          {'digest': null},
          {'digest': 'sha256:abc'},
          {'size': 0},
          {'size': updateMaximumBytes + 1},
          {'state': 'new'},
          {'name': 'fake.apk'},
          {
            'browser_download_url':
                'http://github.com/$updateRepository/releases/download/a/b.apk',
          },
          {
            'browser_download_url':
                'https://github.com/other/repo/releases/download/a/b.apk',
          },
        ]) {
          final json = releaseJson();
          json['assets'] = [
            {...(json['assets'] as List).single as Map, ...change},
          ];
          expect(
            () => AppRelease.parse(json, installed),
            throwsFormatException,
          );
        }
        final json = releaseJson();
        (json['assets'] as List).add((json['assets'] as List).single);
        expect(() => AppRelease.parse(json, installed), throwsFormatException);
      },
    );
    test(
      'TLS and redirect allowlist reject credentials, ports, local/private and foreign origins',
      () {
        final valid = AppRelease.parse(releaseJson(), installed)!.url;
        expect(trustedUpdateUrl(valid, metadata: false, initial: true), isTrue);
        expect(
          trustedUpdateUrl(Uri.parse(updateApi), metadata: true, initial: true),
          isTrue,
        );
        for (final url in [
          'http://release-assets.githubusercontent.com/a',
          'https://github.com.evil.test/a',
          'https://user@release-assets.githubusercontent.com/a',
          'https://release-assets.githubusercontent.com:444/a',
          'https://127.0.0.1/a',
          'https://192.168.1.1/a',
          'https://api.github.com/other',
          'https://github.com/other/repo/releases/download/a/b',
          'https://release-assets.githubusercontent.com/a#fragment',
        ]) {
          expect(
            trustedUpdateUrl(Uri.parse(url), metadata: false, initial: false),
            isFalse,
            reason: url,
          );
        }
        expect(
          trustedUpdateUrl(
            Uri.parse(
              'https://release-assets.githubusercontent.com/a?token=short',
            ),
            metadata: false,
            initial: false,
          ),
          isTrue,
        );
        expect(
          trustedUpdateUrl(
            Uri.parse('https://release-assets.githubusercontent.com/a'),
            metadata: false,
            initial: true,
          ),
          isFalse,
        );
      },
    );
  });

  group('update controller', () {
    late AppUpdates updater;
    late FakeUpdateTransport transport;
    late FakeUpdatePlatform platform;
    late Directory directory;
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      directory = await Directory.systemTemp.createTemp('hongguo-update-test-');
      transport = FakeUpdateTransport();
      platform = FakeUpdatePlatform(directory.path);
      updater = AppUpdates(
        supportedEdition: true,
        preferences: prefs,
        transport: transport,
        platform: platform,
      );
    });
    tearDown(() async {
      updater.dispose();
      await directory.delete(recursive: true);
    });

    test(
      'automatic checks are cached; manual bypasses; metadata never auto-downloads',
      () async {
        await updater.check();
        expect(updater.stage, UpdateStage.available);
        await updater.check();
        expect(transport.checks, 1);
        final second = AppUpdates(
          supportedEdition: true,
          preferences: prefs,
          transport: transport,
          platform: platform,
        );
        await second.check();
        expect(transport.checks, 1);
        second.dispose();
        await updater.check(manual: true);
        expect(transport.checks, 2);
        expect(transport.downloads, 0);
        expect(platform.installs, 0);
      },
    );
    test(
      'failed lookup is a retryable failure, never already latest; retry cooldown',
      () async {
        transport.failure = const SocketException('offline');
        await updater.check();
        expect(updater.stage, UpdateStage.failed);
        expect(updater.message, contains('无法检查'));
        await updater.check();
        expect(transport.checks, 1);
        transport.failure = null;
        await updater.check(manual: true);
        expect(updater.stage, UpdateStage.available);
      },
    );
    test(
      'automatic preference disables checks only, manual remains usable',
      () async {
        await updater.setAutomatic(false);
        await updater.check();
        expect(transport.checks, 0);
        await updater.check(manual: true);
        expect(transport.checks, 1);
      },
    );
    test(
      'successful download is verified and never installs automatically',
      () async {
        await updater.check();
        await updater.download();
        expect(updater.stage, UpdateStage.ready);
        expect(platform.validations, 1);
        expect(platform.installs, 0);
        expect(await File('${directory.path}/pending.apk').length(), 4);
        expect(
          await File('${directory.path}/pending.apk.part').exists(),
          isFalse,
        );
      },
    );
    test('download rechecks installed code and drops a stale update', () async {
      await updater.check();
      platform.app = const InstalledApp(
        version: '0.1.6',
        code: 2028,
        abi: 'arm64-v8a',
      );
      await updater.download();
      expect(transport.downloads, 0);
      expect(updater.release, isNull);
      expect(updater.stage, UpdateStage.idle);
      expect(updater.installedApp!.code, 2028);
    });

    test('install rechecks installed code after an external upgrade', () async {
      await updater.check();
      await updater.download();
      platform.app = const InstalledApp(
        version: '0.1.6',
        code: 2028,
        abi: 'arm64-v8a',
      );
      await updater.install();
      expect(platform.installs, 0);
      expect(platform.validations, 1);
      expect(updater.release, isNull);
      expect(await File('${directory.path}/pending.apk').exists(), isFalse);
    });

    test('failed recheck cannot keep an old download offer', () async {
      await updater.check();
      transport.failure = const SocketException('offline');
      await updater.check(manual: true);
      expect(updater.release, isNull);
      await updater.download();
      expect(transport.downloads, 0);
    });

    test(
      'download chunk bursts do not rebuild the page for every chunk',
      () async {
        await updater.check();
        transport.progressBurst = 4000;
        var notifications = 0;
        updater.addListener(() => notifications++);
        await updater.download();
        expect(updater.stage, UpdateStage.ready);
        expect(updater.downloaded, 4);
        expect(notifications, lessThan(20));
      },
    );

    test(
      'wrong hash/signature/ABI/version rejection deletes downloaded package',
      () async {
        await updater.check();
        for (final reason in [
          'hash',
          'signature',
          'abi',
          'version',
          'package',
        ]) {
          platform.validationFailure = StateError(reason);
          await updater.download();
          expect(updater.stage, UpdateStage.failed);
          expect(await File('${directory.path}/pending.apk').exists(), isFalse);
          expect(platform.installs, 0);
        }
      },
    );
    test(
      'repeat download clicks create one operation and cancel removes partial file',
      () async {
        await updater.check();
        transport.gate = Completer<void>();
        final pending = updater.download();
        while (transport.downloads == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await updater.download();
        updater.cancelDownload();
        await pending;
        expect(transport.downloads, 1);
        expect(updater.stage, UpdateStage.available);
        expect(await File('${directory.path}/pending.apk').exists(), isFalse);
        expect(
          await File('${directory.path}/pending.apk.part').exists(),
          isFalse,
        );
      },
    );
    test(
      'cancellation during directory lookup never starts transport',
      () async {
        await updater.check();
        platform.directoryGate = Completer<String>();
        final pending = updater.download();
        updater.cancelDownload();
        platform.directoryGate!.complete(directory.path);
        await pending;
        expect(transport.downloads, 0);
        expect(updater.stage, UpdateStage.available);
      },
    );
    test(
      'cancel during verification cannot leave an installable file',
      () async {
        await updater.check();
        platform.validationGate = Completer<void>();
        final pending = updater.download();
        while (platform.validations == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        updater.cancelDownload();
        platform.validationGate!.complete();
        await pending;
        expect(updater.stage, UpdateStage.available);
        expect(await File('${directory.path}/pending.apk').exists(), isFalse);
      },
    );
    test(
      'permission needs explicit action and return never starts installer',
      () async {
        await updater.check();
        await updater.download();
        await updater.install();
        expect(updater.stage, UpdateStage.permission);
        expect(platform.permissions, 0);
        await updater.openPermission();
        expect(platform.permissions, 1);
        await updater.returnedFromSettings();
        expect(updater.stage, UpdateStage.ready);
        expect(updater.message, contains('未开启'));
        expect(platform.installs, 0);
        await updater.install();
        await updater.openPermission();
        platform.allowed = true;
        await updater.returnedFromSettings();
        expect(updater.stage, UpdateStage.ready);
        expect(platform.installs, 0);
        await updater.install();
        expect(platform.installs, 1);
        expect(updater.stage, UpdateStage.ready);
        expect(updater.message, contains('取消'));
      },
    );
    test(
      'installer returned is not success and repeat install is serialized',
      () async {
        await updater.check();
        await updater.download();
        platform.allowed = true;
        platform.installResult = 'returned';
        platform.permissionGate = Completer<bool>();
        final pending = updater.install();
        await updater.install();
        platform.permissionGate!.complete(true);
        await pending;
        expect(platform.installs, 1);
        expect(updater.stage, UpdateStage.ready);
        expect(updater.message, contains('尚未确认'));
      },
    );
    test(
      'unsupported edition cannot check, download or install from all-source feed',
      () async {
        final unsupported = AppUpdates(
          preferences: prefs,
          transport: transport,
          platform: platform,
          supportedEdition: false,
        );
        await unsupported.check(manual: true);
        expect(transport.checks, 0);
        unsupported.release = AppRelease.parse(releaseJson(), installed);
        unsupported.stage = UpdateStage.available;
        await unsupported.download();
        unsupported.stage = UpdateStage.ready;
        await unsupported.install();
        expect(transport.downloads, 0);
        expect(platform.installs, 0);
        unsupported.dispose();
      },
    );
    test(
      'dispose during installed lookup never starts network or writes cache',
      () async {
        final subject = AppUpdates(
          preferences: prefs,
          transport: transport,
          platform: platform,
          supportedEdition: true,
        );
        platform.installedGate = Completer<InstalledApp>();
        final pending = subject.check();
        subject.dispose();
        platform.installedGate!.complete(installed);
        await pending;
        expect(transport.checks, 0);
        expect(prefs.getString('app_update_stable_cache_v1'), isNull);
      },
    );
    test(
      'dispose during download directory lookup never starts a download',
      () async {
        final subject = AppUpdates(
          preferences: prefs,
          transport: transport,
          platform: platform,
          supportedEdition: true,
        );
        await subject.check();
        platform.directoryGate = Completer<String>();
        final pending = subject.download();
        subject.dispose();
        platform.directoryGate!.complete(directory.path);
        await pending;
        expect(transport.downloads, 0);
        expect(platform.installs, 0);
      },
    );
    test('dispose while awaiting permission never opens installer', () async {
      final subject = AppUpdates(
        preferences: prefs,
        transport: transport,
        platform: platform,
        supportedEdition: true,
      );
      await subject.check();
      await subject.download();
      platform.permissionGate = Completer<bool>();
      final pending = subject.install();
      await Future<void>.delayed(Duration.zero);
      subject.dispose();
      platform.permissionGate!.complete(true);
      await pending;
      expect(platform.installs, 0);
    });
    test(
      'startup removes interrupted partial and APK after proven completed update',
      () async {
        await File('${directory.path}/pending.apk').writeAsBytes([1]);
        await File('${directory.path}/pending.apk.part').writeAsBytes([2]);
        await prefs.setInt('app_update_installing_code', installed.code);
        await updater.check();
        expect(await File('${directory.path}/pending.apk').exists(), isFalse);
        expect(
          await File('${directory.path}/pending.apk.part').exists(),
          isFalse,
        );
        expect(prefs.getInt('app_update_installing_code'), isNull);
      },
    );
    test(
      'startup retains pending installer APK while installed code has not advanced',
      () async {
        await File('${directory.path}/pending.apk').writeAsBytes([1]);
        await File('${directory.path}/pending.apk.part').writeAsBytes([2]);
        await prefs.setInt('app_update_installing_code', installed.code + 1);
        await updater.check();
        expect(await File('${directory.path}/pending.apk').exists(), isTrue);
        expect(
          await File('${directory.path}/pending.apk.part').exists(),
          isFalse,
        );
      },
    );
    test(
      'cancel permission leaves ready and grants no system permission',
      () async {
        await updater.check();
        await updater.download();
        await updater.install();
        updater.cancelPermission();
        expect(updater.stage, UpdateStage.ready);
        expect(platform.permissions, 0);
        expect(platform.installs, 0);
      },
    );
  });
}
