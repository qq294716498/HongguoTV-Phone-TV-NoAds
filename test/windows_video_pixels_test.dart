import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/windows_video_pixels.dart';

Uint8List frame({required Rect content, bool greenPadding = false}) {
  const width = 204, height = 116;
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      if (content.contains(Offset(x.toDouble(), y.toDouble()))) {
        bytes.setRange(offset, offset + 4, [107, 202, 222, 255]);
      } else {
        bytes.setRange(offset, offset + 4, [0, greenPadding ? 96 : 0, 0, 255]);
      }
    }
  }
  return bytes;
}

void main() {
  const expected = Rect.fromLTWH(6, 4, 192, 108);

  test('valid decoded image bounds exclude the normal letterbox', () {
    final bounds = syntheticVideoBounds(frame(content: expected), 204, 116);
    expect(bounds, expected);
    expect(decodedVideoPixelFailures(bounds, expected), isEmpty);
  });

  test(
    'right and bottom decoder padding fails despite correct texture bounds',
    () {
      const content = Rect.fromLTWH(6, 4, 180, 101);
      final bounds = syntheticVideoBounds(
        frame(content: content, greenPadding: true),
        204,
        116,
      );
      expect(bounds, content);
      expect(decodedVideoPixelFailures(bounds, expected), [
        'decoded right edge -12.0',
        'decoded bottom edge -7.0',
      ]);
    },
  );

  test(
    'missing decoded pixels cannot pass as a matching texture rectangle',
    () {
      final bounds = syntheticVideoBounds(Uint8List(204 * 116 * 4), 204, 116);
      expect(bounds, isNull);
      expect(decodedVideoPixelFailures(bounds, expected), [
        'decoded synthetic video pixels unavailable',
      ]);
    },
  );

  test('known encoded bottom black is preserved rather than cropped away', () {
    const content = Rect.fromLTWH(6, 4, 192, 101);
    final bounds = syntheticVideoBounds(frame(content: content), 204, 116);
    expect(decodedVideoPixelFailures(bounds, content), isEmpty);
    expect(decodedVideoPixelFailures(bounds, expected), [
      'decoded bottom edge -7.0',
    ]);
  });
}
