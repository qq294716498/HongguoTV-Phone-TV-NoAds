import 'dart:async';
import 'dart:io';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/app_update_screen.dart';
import 'package:duanju_app/app_updates.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'app_updates_test.dart'
    show FakeUpdatePlatform, FakeUpdateTransport, installed, releaseJson;
import 'windows_updates_test.dart' show windowsRelease;

const _androidSkipped = 'app_update_android_stable_skipped_release_v1';
const _windowsSkipped = 'app_update_windows_stable_skipped_release_v1';
const _windowsInstalled = InstalledApp(
  version: '0.1.13-preview.1',
  code: 37,
  abi: 'windows-x64',
);

Map<String, dynamic> _androidRelease({
  String version = '0.1.6',
  int build = 28,
}) {
  final tag = 'app-v$version-$build';
  return {
    ...releaseJson(build: build),
    'tag_name': tag,
    'assets': [
      for (final abi in updateAbiOffsets.keys)
        {
          ...(releaseJson(abi: abi, build: build)['assets'] as List).single
              as Map,
          'name': 'HongguoTV-$version-$abi.apk',
          'browser_download_url':
              'https://github.com/$updateRepository/releases/download/$tag/HongguoTV-$version-$abi.apk',
        },
    ],
  };
}

class _ReleaseTransport extends FakeUpdateTransport {
  _ReleaseTransport(this.data);
  Map<String, dynamic> data;

  @override
  Future<Map<String, dynamic>> latest() async {
    checks++;
    if (failure != null) throw failure!;
    return lookup?.future ?? data;
  }
}

class _RecordingPlatform extends FakeUpdatePlatform {
  _RecordingPlatform(super.path);
  final validatedCodes = <int>[];
  final installedCodes = <int>[];

  @override
  Future<void> validate(AppRelease release) async {
    await super.validate(release);
    validatedCodes.add(release.code);
  }

  @override
  Future<String> install(AppRelease release) {
    installedCodes.add(release.code);
    return super.install(release);
  }
}

class _SkipStore extends InMemorySharedPreferencesStore {
  _SkipStore() : super.empty();
  String failure = '';
  Completer<bool>? gate;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('_skipped_release_v1')) {
      if (gate != null && !await gate!.future) return false;
      if (failure == 'false') return false;
      if (failure == 'throw') throw StateError('synthetic skip write failure');
      if (failure == 'after') {
        await super.setValue(valueType, key, value);
        throw StateError('synthetic skip acknowledgement failure');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;
  late DateTime clock;
  final subjects = <AppUpdates>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('update-skip-中文 ');
    clock = DateTime.utc(2026, 10, 20, 8);
  });
  tearDown(() async {
    AppUpdates.current = null;
    for (final subject in subjects) {
      subject.dispose();
    }
    subjects.clear();
    await directory.delete(recursive: true);
  });
  (AppUpdates, _RecordingPlatform, _ReleaseTransport) create({
    bool windows = false,
    bool supported = true,
    InstalledApp? app,
  }) {
    final transport = _ReleaseTransport(
      windows ? windowsRelease() : _androidRelease(),
    );
    final platform = _RecordingPlatform(directory.path)
      ..app = app ?? (windows ? _windowsInstalled : installed)
      ..allowed = true;
    final updates = AppUpdates(
      preferences: preferences,
      windows: windows,
      supportedEdition: supported,
      transport: transport,
      platform: platform,
      now: () => clock,
    );
    subjects.add(updates);
    return (updates, platform, transport);
  }

  Future<void> restartPreferences() async {
    SharedPreferences.resetStatic();
    preferences = await SharedPreferences.getInstance();
  }

  for (final windows in [false, true]) {
    final name = windows ? 'Windows' : 'Android';
    final skippedKey = windows ? _windowsSkipped : _androidSkipped;
    test(
      '$name skip persists across restart without changing installed code',
      () async {
        final (updates, platform, transport) = create(windows: windows);
        await updates.check();
        final installedCode = updates.installedApp!.code;
        final releaseCode = updates.release!.code;
        expect(updates.showAutomaticPrompt, isTrue);
        await updates.skipCurrentVersion();
        expect(updates.currentVersionSkipped, isTrue);
        expect(updates.showAutomaticPrompt, isFalse);
        expect(updates.hasUpdate, isTrue);
        expect(updates.release!.code, releaseCode);
        expect(updates.installedApp!.code, installedCode);
        expect(platform.app.code, installedCode);
        expect(transport.downloads, 0);
        expect(platform.installs, 0);
        expect(
          preferences.getString(skippedKey),
          contains('+${windows ? 38 : 28}'),
        );
        await restartPreferences();
        final (restarted, restartedPlatform, restartedTransport) = create(
          windows: windows,
        );
        await restarted.check();
        expect(restarted.currentVersionSkipped, isTrue);
        expect(restarted.showAutomaticPrompt, isFalse);
        expect(restartedPlatform.app.code, installedCode);
        expect(restartedTransport.checks, 0);
        expect(preferences.getBool('app_update_automatic'), isNot(false));
      },
    );

    test(
      '$name manual check bypasses skip and cache while preserving the record',
      () async {
        final (updates, platform, transport) = create(windows: windows);
        await updates.check();
        await updates.skipCurrentVersion();
        await updates.setAutomatic(false);
        await updates.check();
        expect(transport.checks, 1);
        await updates.check(manual: true);
        expect(transport.checks, 2);
        expect(updates.release, isNotNull);
        expect(updates.currentVersionSkipped, isTrue);
        expect(updates.message, contains('仍可手动更新'));
        await updates.download();
        expect(updates.stage, UpdateStage.ready);
        expect(platform.installs, 0);
        expect(transport.downloads, 1);
        await updates.install();
        expect(platform.installs, 1);
        expect(platform.installedCodes, [updates.release!.code]);
      },
    );

    test(
      '$name higher build is prompted after the normal automatic interval',
      () async {
        final (updates, _, transport) = create(windows: windows);
        await updates.check();
        await updates.skipCurrentVersion();
        transport.data = windows
            ? windowsRelease(build: 39)
            : _androidRelease(build: 29);
        clock = clock.add(const Duration(hours: 13));
        await updates.check();
        expect(transport.checks, 2);
        expect(updates.showAutomaticPrompt, isTrue);
        expect(updates.currentVersionSkipped, isFalse);
        expect(updates.release!.code, windows ? 39 : 2029);
      },
    );

    test(
      '$name READY package survives skip and same-release manual refresh',
      () async {
        final (updates, platform, transport) = create(windows: windows);
        await updates.check();
        await updates.download();
        final file = File(
          '${directory.path}/pending.${windows ? 'zip' : 'apk'}',
        );
        final bytes = await file.readAsBytes();
        final candidate = updates.release!;
        await updates.check(manual: true);
        expect(updates.stage, UpdateStage.ready);
        expect(await file.readAsBytes(), bytes);
        await updates.skipCurrentVersion();
        expect(updates.stage, UpdateStage.ready);
        transport.data = {...transport.data, 'body': '同一版本的更新说明已补充'};
        await updates.check(manual: true);
        expect(updates.stage, UpdateStage.ready);
        expect(updates.release!.validation, candidate.validation);
        expect(updates.release!.notes, '同一版本的更新说明已补充');
        expect(await file.readAsBytes(), bytes);
        expect(transport.downloads, 1);
        await updates.install();
        expect(platform.installedCodes, [candidate.code]);
      },
    );

    test(
      '$name skipped READY still discovers new versions and cannot install old bytes',
      () async {
        final (updates, platform, transport) = create(windows: windows);
        await updates.check();
        await updates.download();
        await updates.skipCurrentVersion();
        transport.data = windows
            ? windowsRelease(build: 39)
            : _androidRelease(build: 29);
        clock = clock.add(const Duration(hours: 13));
        await updates.check();
        expect(transport.checks, 2);
        expect(updates.currentVersionSkipped, isFalse);
        expect(updates.showAutomaticPrompt, isTrue);
        expect(updates.stage, UpdateStage.available);
        await updates.install();
        expect(platform.installs, 0);
        await updates.download();
        expect(updates.stage, UpdateStage.ready);
        await updates.install();
        expect(platform.installedCodes, [windows ? 39 : 2029]);
        expect(transport.downloads, 2);
      },
    );
  }

  test(
    'higher semantic version with the same build is a distinct skipped release',
    () async {
      final (updates, _, transport) = create();
      await updates.check();
      await updates.skipCurrentVersion();
      transport.data = _androidRelease(version: '0.1.7');
      await updates.check(manual: true);
      expect(updates.release!.version, '0.1.7');
      expect(updates.release!.code, 2028);
      expect(updates.currentVersionSkipped, isFalse);
      expect(updates.showAutomaticPrompt, isTrue);
    },
  );

  test(
    'higher Windows semantic version is not hidden by the same-build skip',
    () async {
      final (updates, _, transport) = create(windows: true);
      await updates.check();
      await updates.skipCurrentVersion();
      const version = '0.1.15';
      const tag = 'windows-v$version-38';
      const name = 'HongguoTV-$version-windows-x64.zip';
      transport.data = {
        ...transport.data,
        'tag_name': tag,
        'assets': [
          {
            ...(transport.data['assets'] as List).single as Map,
            'name': name,
            'browser_download_url':
                'https://github.com/$updateRepository/releases/download/$tag/$name',
          },
        ],
      };
      clock = clock.add(const Duration(hours: 13));
      await updates.check();
      expect(updates.release!.version, version);
      expect(updates.release!.code, 38);
      expect(updates.showAutomaticPrompt, isTrue);
    },
  );

  test('skipped records are isolated between Windows and Android', () async {
    final (android, _, _) = create();
    final (windows, _, _) = create(windows: true);
    await android.check();
    await windows.check();
    await android.skipCurrentVersion();
    expect(windows.showAutomaticPrompt, isTrue);
    expect(preferences.getString(_windowsSkipped), isNull);
    await windows.skipCurrentVersion();
    expect(preferences.getString(_androidSkipped), 'android:0.1.6+28');
    expect(preferences.getString(_windowsSkipped), 'windows:0.1.14+38');
    await restartPreferences();
    final (restoredAndroid, _, _) = create();
    final (restoredWindows, _, _) = create(windows: true);
    await restoredAndroid.check();
    await restoredWindows.check();
    expect(restoredAndroid.currentVersionSkipped, isTrue);
    expect(restoredWindows.currentVersionSkipped, isTrue);
  });

  test(
    'Android skip identity ignores ABI offset while asset selection remains exact',
    () async {
      final (arm64, _, _) = create();
      await arm64.check();
      await arm64.skipCurrentVersion();
      for (final entry in updateAbiOffsets.entries) {
        final (updates, platform, _) = create(
          app: InstalledApp(
            version: '0.1.5',
            code: entry.value + 27,
            abi: entry.key,
          ),
        );
        await updates.check(manual: true);
        expect(updates.currentVersionSkipped, isTrue);
        expect(updates.release!.code, entry.value + 28);
        expect(updates.release!.abi, entry.key);
        expect(updates.release!.url.path, endsWith('-${entry.key}.apk'));
        await updates.download();
        expect(platform.validatedCodes, [entry.value + 28]);
      }
    },
  );

  test(
    'a changed Android ABI cannot reuse a READY package from the old ABI',
    () async {
      final (updates, platform, _) = create();
      await updates.check();
      await updates.download();
      await updates.skipCurrentVersion();
      platform.app = const InstalledApp(
        version: '0.1.5',
        code: 4027,
        abi: 'x86_64',
      );
      await updates.check(manual: true);
      expect(updates.currentVersionSkipped, isTrue);
      expect(updates.release!.abi, 'x86_64');
      expect(updates.stage, UpdateStage.available);
      await updates.install();
      expect(platform.installs, 0);
      await updates.download();
      await updates.install();
      expect(platform.installedCodes, [4028]);
    },
  );

  test(
    'a failed refresh preserves a valid READY package without reviving stale offers',
    () async {
      final (updates, platform, transport) = create();
      await updates.check();
      await updates.download();
      await updates.skipCurrentVersion();
      transport.failure = const SocketException('synthetic offline');
      await updates.check(manual: true);
      expect(updates.stage, UpdateStage.ready);
      expect(updates.currentVersionSkipped, isTrue);
      expect(updates.message, contains('已校验的安装包保留'));
      await updates.install();
      expect(platform.installedCodes, [2028]);
      platform.app = const InstalledApp(
        version: '0.1.6',
        code: 2028,
        abi: 'arm64-v8a',
      );
      await updates.check(manual: true);
      expect(updates.release, isNull);
      expect(updates.stage, UpdateStage.failed);
      await updates.install();
      expect(platform.installs, 1);
    },
  );

  test(
    'changed hash under the same version invalidates READY without changing the skip',
    () async {
      final (updates, platform, transport) = create();
      await updates.check();
      await updates.download();
      await updates.skipCurrentVersion();
      final assets = transport.data['assets'] as List;
      transport.data = {
        ...transport.data,
        'assets': [
          for (final asset in assets)
            {...asset as Map, 'digest': 'sha256:${'b' * 64}'},
        ],
      };
      await updates.check(manual: true);
      expect(updates.currentVersionSkipped, isTrue);
      expect(updates.stage, UpdateStage.available);
      await updates.install();
      expect(platform.installs, 0);
    },
  );

  for (final failure in ['false', 'throw', 'after']) {
    test(
      'skip persistence $failure never suppresses prompts or poisons restart cache',
      () async {
        final storage = _SkipStore()..failure = failure;
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = storage;
        preferences = await SharedPreferences.getInstance();
        final (updates, _, _) = create();
        await updates.check();
        await updates.skipCurrentVersion();
        expect(updates.currentVersionSkipped, isFalse);
        expect(updates.showAutomaticPrompt, isTrue);
        expect(updates.message, contains('无法保存跳过记录'));
        expect(preferences.getString(_androidSkipped), isNull);
        await restartPreferences();
        final (restarted, _, _) = create();
        await restarted.check();
        expect(restarted.currentVersionSkipped, isFalse);
        storage.failure = '';
        await restarted.skipCurrentVersion();
        expect(restarted.currentVersionSkipped, isTrue);
      },
    );
  }

  test('failed replacement keeps the earlier skipped version intact', () async {
    final storage = _SkipStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    preferences = await SharedPreferences.getInstance();
    final (updates, _, transport) = create();
    await updates.check();
    await updates.skipCurrentVersion();
    transport.data = _androidRelease(build: 29);
    await updates.check(manual: true);
    storage.failure = 'after';
    await updates.skipCurrentVersion();
    expect(updates.currentVersionSkipped, isFalse);
    expect(preferences.getString(_androidSkipped), 'android:0.1.6+28');
    await restartPreferences();
    final (restarted, _, restartedTransport) = create();
    await restarted.check(manual: true);
    expect(restarted.currentVersionSkipped, isTrue);
    restartedTransport.data = _androidRelease(build: 29);
    await restarted.check(manual: true);
    expect(restarted.showAutomaticPrompt, isTrue);
  });

  test(
    'pending persistence is not treated as skipped and serializes user actions',
    () async {
      final storage = _SkipStore()..gate = Completer<bool>();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = storage;
      preferences = await SharedPreferences.getInstance();
      final (updates, platform, transport) = create();
      await updates.check();
      await updates.download();
      final saving = updates.skipCurrentVersion();
      expect(updates.busy, isTrue);
      expect(updates.currentVersionSkipped, isFalse);
      expect(updates.showAutomaticPrompt, isTrue);
      await updates.check(manual: true);
      await updates.download();
      await updates.install();
      expect(transport.checks, 1);
      expect(transport.downloads, 1);
      expect(platform.installs, 0);
      storage.gate!.complete(true);
      await saving;
      expect(updates.busy, isFalse);
      expect(updates.currentVersionSkipped, isTrue);
      await updates.install();
      expect(platform.installs, 1);
    },
  );

  test('unsupported editions cannot save skipped records', () async {
    final (updates, _, _) = create(supported: false);
    updates.release = AppRelease.parse(_androidRelease(), installed);
    updates.stage = UpdateStage.available;
    await updates.skipCurrentVersion();
    expect(preferences.getString(_androidSkipped), isNull);
    expect(updates.currentVersionSkipped, isFalse);
  });

  test(
    'skipping a Windows release never hides the previous installation failure',
    () async {
      final (updates, _, _) = create(windows: true);
      await updates.check();
      updates.reportWindowsStartupFailure(
        'failed: phase=backup-current-directory; Win32=5',
      );
      await updates.skipCurrentVersion();
      expect(updates.installationFailure, contains('Win32=5'));
      expect(updates.showAutomaticPrompt, isFalse);
    },
  );

  testWidgets(
    'TV arrows reach skip and select activates it while manual downloads remain reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 540));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late AppUpdates updates;
      late _RecordingPlatform platform;
      await tester.runAsync(() async {
        (updates, platform, _) = create();
        await updates.check();
      });
      AppUpdates.current = updates;
      await tester.pumpWidget(
        MaterialApp(
          theme: televisionTheme(ThemeData()),
          home: AppLayout(
            television: true,
            child: Scaffold(
              appBar: AppBar(actions: const [AppUpdateIndicator()]),
              body: AppUpdateScreen(updates: updates),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsOneWidget);
      final check = find.byKey(const ValueKey('check-app-update'));
      final skip = find.byKey(const ValueKey('skip-app-update'));
      expect(
        Focus.of(
          tester.element(
            find.descendant(of: check, matching: find.byType(Text)).first,
          ),
        ).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        Focus.of(
          tester.element(
            find.descendant(of: skip, matching: find.byType(Text)).first,
          ),
        ).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(updates.currentVersionSkipped, isTrue);
      expect(find.byType(Badge), findsNothing);
      expect(find.text('已跳过此版本自动提示'), findsOneWidget);
      expect(platform.installs, 0);
      expect(find.byKey(const ValueKey('download-app-update')), findsOneWidget);
      final download = tester.widget<FilledButton>(
        find.byKey(const ValueKey('download-app-update')),
      );
      expect(download.onPressed, isNotNull);
      await tester.runAsync(() async {
        download.onPressed!();
        for (var i = 0; i < 50 && updates.stage != UpdateStage.ready; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(updates.stage, UpdateStage.ready, reason: updates.message);
      expect(find.byKey(const ValueKey('install-app-update')), findsOneWidget);
      expect(updates.currentVersionSkipped, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
