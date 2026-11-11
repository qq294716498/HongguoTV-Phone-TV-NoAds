import 'package:duanju_app/portrait_video_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rows grow upwards from video and overflow below it', () {
    expect(
      portraitDanmakuLaneTops(
        const Rect.fromLTWH(0, 90, 400, 220),
        800,
        28,
        const EdgeInsets.only(top: 24),
      ),
      [62, 34, 310, 338],
    );
    expect(
      portraitDanmakuLaneTops(
        const Rect.fromLTWH(0, 300, 400, 220),
        800,
        28,
        EdgeInsets.zero,
      ),
      [272, 244, 216, 188],
    );
  });
  test('full height portrait keeps rows inside safe bottom', () {
    final tops = portraitDanmakuLaneTops(
      const Rect.fromLTWH(0, 0, 400, 800),
      800,
      32,
      const EdgeInsets.only(top: 24, bottom: 20),
    );
    expect(tops, [644, 676, 708, 740]);
  });
}
