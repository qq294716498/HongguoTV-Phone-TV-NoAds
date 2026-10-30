import 'dart:typed_data';
import 'dart:ui';

Rect? syntheticVideoBounds(Uint8List bytes, int width, int height) {
  var left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      if (bytes[offset] < 155 &&
          bytes[offset + 1] > 175 &&
          bytes[offset + 2] > 195) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  if (right < left || bottom < top) return null;
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    (right + 1).toDouble(),
    (bottom + 1).toDouble(),
  );
}

List<String> decodedVideoPixelFailures(Rect? pixels, Rect expected) {
  if (pixels == null) return ['decoded synthetic video pixels unavailable'];
  final failures = <String>[];
  for (final edge in {
    'left': pixels.left - expected.left,
    'top': pixels.top - expected.top,
    'right': pixels.right - expected.right,
    'bottom': pixels.bottom - expected.bottom,
  }.entries) {
    if (edge.value.abs() > 3) {
      failures.add('decoded ${edge.key} edge ${edge.value}');
    }
  }
  return failures;
}
