import 'danmaku_text.dart';

const danmakuBaselineSpeed = 1.15;

const danmakuWindowMs = 30000;
const danmakuLifetimeMs = 8000;
const danmakuMaxDurationMs = 86400000;
const danmakuMergeWindowMs = 3000;

/// 弹幕字号档位。TV 端默认小号（历史上的 14 号字）。
enum DanmakuFontSize {
  small('小', 1),
  medium('中', 1.28),
  large('大', 1.62);

  const DanmakuFontSize(this.label, this.scale);

  final String label;
  final double scale;

  static DanmakuFontSize parse(Object? value) => values.firstWhere(
    (size) => size.name == value,
    orElse: () => DanmakuFontSize.small,
  );
}

/// 弹幕密度档位。少量模式仅保留两条轨道，正常模式铺满可用安全区。
enum DanmakuDensity {
  normal('正常'),
  sparse('少量');

  const DanmakuDensity(this.label);

  final String label;

  static DanmakuDensity parse(Object? value) => values.firstWhere(
    (density) => density.name == value,
    orElse: () => DanmakuDensity.normal,
  );
}

class DanmakuItem {
  const DanmakuItem({
    required this.id,
    required this.text,
    required this.timeMs,
    this.repeatCount = 1,
  });
  final String id;
  final String text;
  final int timeMs;
  final int repeatCount;
}

List<DanmakuItem> mergeDanmaku(Iterable<DanmakuItem> items) {
  final sorted = items.toList()
    ..sort((a, b) {
      final time = a.timeMs.compareTo(b.timeMs);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
  final seen = <String>{};
  final latest = <String, int>{};
  final merged = <DanmakuItem>[];
  for (final item in sorted) {
    if (item.id.isEmpty || item.timeMs < 0 || !seen.add(item.id)) continue;
    final original = item.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = danmakuDisplayText(original);
    if (text.isEmpty) continue;
    final index = latest[text];
    if (index != null &&
        item.timeMs - merged[index].timeMs <= danmakuMergeWindowMs) {
      final previous = merged[index];
      merged[index] = DanmakuItem(
        id: previous.id,
        text: previous.text,
        timeMs: previous.timeMs,
        repeatCount: previous.repeatCount + item.repeatCount,
      );
    } else {
      latest[text] = merged.length;
      merged.add(
        DanmakuItem(
          id: item.id,
          text: original,
          timeMs: item.timeMs,
          repeatCount: item.repeatCount,
        ),
      );
    }
  }
  return List.unmodifiable(merged);
}

class DanmakuPage {
  const DanmakuPage({
    required this.episodeId,
    required this.startMs,
    required this.nextMs,
    required this.items,
  });
  final String episodeId;
  final int startMs;
  final int nextMs;
  final List<DanmakuItem> items;

  factory DanmakuPage.fromJson(
    Map<String, dynamic> json, {
    required String episodeId,
    required int startMs,
    required int durationMs,
  }) {
    final next = json['nextMs'];
    final rows = json['items'];
    if (json['episodeId'] != episodeId ||
        json['startMs'] != startMs ||
        next is! int ||
        next <= startMs ||
        next > durationMs ||
        rows is! List) {
      throw const FormatException('弹幕分集或时间范围不符');
    }
    final items = <DanmakuItem>[];
    final seen = <String>{};
    for (final row in rows.take(90)) {
      if (row is! Map) continue;
      final id = row['id'], text = row['text'], time = row['timeMs'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 120 ||
          text is! String ||
          time is! int ||
          time < startMs ||
          time >= next ||
          seen.contains(id)) {
        continue;
      }
      final cleaned = text
          .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
          .trim();
      if (cleaned.isEmpty) continue;
      seen.add(id);
      items.add(
        DanmakuItem(
          id: id,
          text: String.fromCharCodes(cleaned.runes.take(181)),
          timeMs: time,
        ),
      );
    }
    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return DanmakuPage(
      episodeId: episodeId,
      startMs: startMs,
      nextMs: next,
      items: List.unmodifiable(items),
    );
  }
}
