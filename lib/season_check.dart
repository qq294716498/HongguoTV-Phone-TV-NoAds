import 'hongguo_series.dart';
import 'models.dart';

class SeasonCheck {
  const SeasonCheck({
    required this.anchorId,
    required this.anchorTitle,
    required this.anchorSeason,
    required this.anchorUnit,
    required this.anchorGroupId,
    required this.checkedAt,
    required this.nextId,
    required this.complete,
    this.retryAt,
    this.blocked = false,
  });

  factory SeasonCheck.observed(
    Drama anchor, {
    required DateTime checkedAt,
    required String? nextId,
    required bool complete,
  }) {
    final info = hongguoSeriesInfo(anchor);
    return SeasonCheck(
      anchorId: anchor.id,
      anchorTitle: anchor.title,
      anchorSeason: info?.season ?? 1,
      anchorUnit: info?.unit ?? '',
      anchorGroupId: anchor.seriesGroupId,
      checkedAt: checkedAt.toUtc(),
      nextId: nextId,
      complete: complete,
    );
  }

  final String anchorId;
  final String anchorTitle;
  final int anchorSeason;
  final String anchorUnit;
  final String anchorGroupId;
  final DateTime checkedAt;
  final String? nextId;
  final bool complete;
  final DateTime? retryAt;
  final bool blocked;

  bool matches(Drama anchor) {
    final info = hongguoSeriesInfo(anchor);
    return anchor.source == SourceSite.hongguo.id &&
        anchor.id == anchorId &&
        anchor.title == anchorTitle &&
        (info?.season ?? 1) == anchorSeason &&
        (info?.unit ?? '') == anchorUnit &&
        anchor.seriesGroupId == anchorGroupId;
  }

  bool isFresh(DateTime now) {
    final age = now.toUtc().difference(checkedAt);
    if (age.isNegative) return false;
    if (retryAt != null && now.isBefore(retryAt!)) return true;
    if (nextId == null && !complete) return false;
    return age < Duration(minutes: nextId == null ? 10 : 30);
  }

  bool hasFreshPositive(DateTime now) {
    final age = now.toUtc().difference(checkedAt);
    return nextId != null &&
        retryAt == null &&
        !age.isNegative &&
        age < const Duration(minutes: 30);
  }

  bool isBlocked(DateTime now) =>
      blocked &&
      !now.isBefore(checkedAt) &&
      retryAt != null &&
      now.isBefore(retryAt!);

  SeasonCheck retrying({required DateTime retryAt, required bool blocked}) =>
      SeasonCheck(
        anchorId: anchorId,
        anchorTitle: anchorTitle,
        anchorSeason: anchorSeason,
        anchorUnit: anchorUnit,
        anchorGroupId: anchorGroupId,
        checkedAt: checkedAt,
        nextId: nextId,
        complete: complete,
        retryAt: retryAt.toUtc(),
        blocked: blocked,
      );

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'anchorId': anchorId,
    'anchorTitle': anchorTitle,
    'anchorSeason': anchorSeason,
    'anchorUnit': anchorUnit,
    'anchorGroupId': anchorGroupId,
    'checkedAt': checkedAt.millisecondsSinceEpoch,
    'nextId': nextId,
    'complete': complete,
    if (retryAt != null) 'retryAt': retryAt!.millisecondsSinceEpoch,
    if (blocked) 'blocked': true,
  };

  factory SeasonCheck.fromJson(Map<String, dynamic> json) {
    final id = json['anchorId'];
    final title = json['anchorTitle'];
    final season = json['anchorSeason'];
    final unit = json['anchorUnit'];
    final group = json['anchorGroupId'];
    final time = json['checkedAt'];
    final next = json['nextId'];
    final complete = json['complete'];
    final retry = json['retryAt'];
    final blocked = json['blocked'] ?? false;
    bool validId(Object? value) =>
        value is String &&
        value.startsWith('${SourceSite.hongguo.id}:') &&
        value.length > SourceSite.hongguo.id.length + 1 &&
        value.length <= 512;
    if (json['schema'] != 1 ||
        !validId(id) ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 300 ||
        season is! int ||
        season < 1 ||
        season > 200 ||
        unit is! String ||
        !{'', '季', '部'}.contains(unit) ||
        group is! String ||
        group.isNotEmpty &&
            (!RegExp(r'^[0-9]{1,32}$').hasMatch(group) ||
                !group.contains(RegExp(r'[1-9]'))) ||
        time is! int ||
        time < 0 ||
        time > 7258118400000 ||
        next != null && (!validId(next) || next == id) ||
        complete is! bool ||
        retry != null &&
            (retry is! int || retry < 0 || retry > 7258118400000) ||
        blocked is! bool ||
        next == null && complete != true && retry == null) {
      throw const FormatException('续季检查缓存无效');
    }
    return SeasonCheck(
      anchorId: id as String,
      anchorTitle: title,
      anchorSeason: season,
      anchorUnit: unit,
      anchorGroupId: group,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
      nextId: next as String?,
      complete: complete,
      retryAt: retry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(retry as int, isUtc: true),
      blocked: blocked,
    );
  }
}
