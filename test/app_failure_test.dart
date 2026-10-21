import 'package:duanju_app/core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native rate limit preserves its server retry deadline', () {
    final failure = AppFailure.fromResponse({
      'ok': false,
      'error': 'HTTP 429',
      'code': 'source_blocked',
      'retryAt': '2026-10-20T14:30:00+08:00',
    });
    expect(failure.code, 'source_blocked');
    expect(failure.retryAt, DateTime.utc(2026, 10, 20, 6, 30));
    expect(failure.toString(), 'HTTP 429');
  });

  test('missing or malformed retry deadline remains absent', () {
    for (final retryAt in [null, 'invalid', 123]) {
      final failure = AppFailure.fromResponse({'retryAt': retryAt});
      expect(failure.retryAt, isNull);
      expect(failure.code, isEmpty);
      expect(failure.message, '读取失败，请重试');
    }
  });
}
