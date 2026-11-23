import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 搜索输入现在是两步流程：先弹屏上键盘，选择「系统输入法」后才进入真实编辑态。
/// 依赖系统输入法的用例在打开搜索框后调用本函数，直接进入编辑态。
Future<void> chooseTelevisionSystemIme(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final systemIme = find.widgetWithText(TextButton, '系统输入法');
  expect(systemIme, findsOneWidget, reason: 'TV 搜索应先弹出屏上键盘');
  await tester.tap(systemIme);
  await tester.pumpAndSettle();
}
