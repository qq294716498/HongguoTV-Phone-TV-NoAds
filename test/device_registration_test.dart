import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RegistrationRepository extends NativeRepository {
  final attempts = <Completer<void>>[];
  int initializations = 0;

  @override
  Future<void> initialize() async {
    initializations++;
  }

  @override
  Future<void> registerDevice() {
    final attempt = Completer<void>();
    attempts.add(attempt);
    return attempt.future;
  }
}

Future<void> waitForRegistration(
  WidgetTester tester,
  RegistrationRepository repository,
  int attempts,
) async {
  for (
    var tick = 0;
    tick < 80 && repository.attempts.length < attempts;
    tick++
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
  expect(repository.attempts, hasLength(attempts));
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppDevice.channel, (call) async {
          if (call.method == 'deviceInfo') {
            return {'television': false, 'version': '0.1.25'};
          }
          return null;
        });
  });

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('registration blocks app entry until success at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = RegistrationRepository();
      var ready = false;
      await tester.pumpWidget(
        AppBootstrap(repository: repository, onReady: () => ready = true),
      );
      await waitForRegistration(tester, repository, 1);
      expect(find.text('正在注册设备'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(ready, isFalse);
      expect(repository.attempts, hasLength(1));
      repository.attempts.single.complete();
      await tester.pump();
      expect(find.text('设备注册成功，正在进入应用'), findsOneWidget);
      expect(ready, isFalse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(ready, isTrue);
      expect(find.text('正在注册设备'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed registration stays blocked and retry registers again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    final repository = RegistrationRepository();
    var ready = false;
    await tester.pumpWidget(
      AppBootstrap(repository: repository, onReady: () => ready = true),
    );
    await waitForRegistration(tester, repository, 1);
    repository.attempts.single.completeError(AppFailure('网络暂不可用'));
    await tester.pumpAndSettle();
    expect(find.text('设备注册失败：网络暂不可用'), findsOneWidget);
    expect(find.text('重新注册'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(ready, isFalse);
    await tester.tap(find.text('重新注册'));
    await waitForRegistration(tester, repository, 2);
    expect(repository.attempts, hasLength(2));
    expect(find.text('正在注册设备'), findsOneWidget);
    expect(ready, isFalse);
    repository.attempts.last.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(ready, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
