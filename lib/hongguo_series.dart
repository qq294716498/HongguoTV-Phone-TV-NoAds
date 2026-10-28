import 'catalog_sort.dart';
import 'follow_state.dart';
import 'models.dart';

const _hongguoSeriesLimit = 200;

final _seasonSuffix = RegExp(
  r'(?:第\s*)?([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

class HongguoSeriesInfo {
  const HongguoSeriesInfo({
    required this.baseTitle,
    required this.key,
    required this.season,
    required this.unit,
    required this.explicit,
  });

  final String baseTitle;
  final String key;
  final int season;
  final String unit;
  final bool explicit;
}

class HongguoSeriesEntry {
  const HongguoSeriesEntry({
    required this.drama,
    required this.season,
    required this.unit,
  });

  final Drama drama;
  final int season;
  final String unit;

  String get label => '第 $season $unit';
}

int? _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) {
    return numeric >= 1 && numeric <= _hongguoSeriesLimit ? numeric : null;
  }
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  if (!label.contains(RegExp('[十百]'))) {
    for (final rune in label.runes) {
      final digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      number = number * 10 + digit;
      if (number > _hongguoSeriesLimit) return null;
    }
    return number >= 1 ? number : null;
  }
  var digit = 0;
  var previous = 1000;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    final value = digits[character];
    if (value != null) {
      digit = digit * 10 + value;
      continue;
    }
    final multiplier = character == '百' ? 100 : 10;
    if (multiplier >= previous || digit > 9) return null;
    number += (digit == 0 ? 1 : digit) * multiplier;
    digit = 0;
    previous = multiplier;
  }
  number += digit;
  return number >= 1 && number <= _hongguoSeriesLimit ? number : null;
}

HongguoSeriesInfo? hongguoSeriesInfo(Drama drama, {String? unit}) {
  if (drama.source != SourceSite.hongguo.id) return null;
  final title = drama.title.trim();
  final match =
      _seasonSuffix.firstMatch(title) ??
      RegExp(r'(?<=[^0-9])([0-9]{1,3})$').firstMatch(title);
  if (match == null) {
    if (unit == null || title.isEmpty) return null;
    return HongguoSeriesInfo(
      baseTitle: title,
      key: normalizedSearchText(title),
      season: 1,
      unit: unit,
      explicit: false,
    );
  }
  final base = title
      .substring(0, match.start)
      .replaceFirst(RegExp(r'[\s\u3000·:：\-_/（(【\[]+$'), '')
      .trim();
  final season = _seasonNumber(match[1]!);
  if (base.isEmpty || season == null) return null;
  return HongguoSeriesInfo(
    baseTitle: base,
    key: normalizedSearchText(base),
    season: season,
    unit: match.groupCount >= 2 ? match[2]! : '季',
    explicit: true,
  );
}

List<HongguoSeriesEntry> hongguoSeriesEntries(
  Drama anchor,
  Iterable<Drama> candidates,
) {
  if (anchor.source != SourceSite.hongguo.id) return const [];
  var anchorInfo = hongguoSeriesInfo(anchor);
  String unit;
  int anchorSeason;
  if (anchorInfo == null) {
    final groups = <String, List<HongguoSeriesInfo>>{};
    for (final drama in candidates) {
      final info = hongguoSeriesInfo(drama);
      if (info != null && hongguoSameSeries(anchor, drama)) {
        (groups[info.unit] ??= []).add(info);
      }
    }
    if (groups.isEmpty) return const [];
    final best = groups.entries.toList()
      ..sort((a, b) {
        final count = b.value.length.compareTo(a.value.length);
        if (count != 0) return count;
        final maxA = a.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        final maxB = b.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        return maxB.compareTo(maxA);
      });
    unit = best.first.key;
    anchorSeason = 1;
    anchorInfo = hongguoSeriesInfo(anchor, unit: unit);
  } else {
    unit = anchorInfo.unit;
    anchorSeason = anchorInfo.season;
  }
  if (anchorInfo == null) return const [];
  final byId = <String, HongguoSeriesEntry>{};
  for (final drama in [anchor, ...candidates]) {
    if (drama.source != SourceSite.hongguo.id) continue;
    final info = hongguoSeriesInfo(drama, unit: unit);
    if (info == null ||
        !hongguoSameSeries(anchor, drama) ||
        info.unit != unit) {
      continue;
    }
    byId[drama.id] = HongguoSeriesEntry(
      drama: drama,
      season: drama.id == anchor.id ? anchorSeason : info.season,
      unit: unit,
    );
  }
  final entries = byId.values.toList()
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0
          ? season
          : naturalTitleCompare(a.drama.title, b.drama.title);
    });
  return entries.length > 1 ? entries : const [];
}

FollowState observeHongguoSeriesSeasons({
  required Drama anchor,
  required FollowState state,
  required Iterable<Drama> candidates,
  required Set<String> favoriteIds,
}) {
  final entries = hongguoSeriesEntries(anchor, candidates);
  if (entries.isEmpty) return state;
  final anchorSeason = entries
      .where((entry) => entry.drama.id == anchor.id)
      .firstOrNull
      ?.season;
  if (anchorSeason == null) return state;
  var seasons = state.seriesSeasons;
  for (final id in seasons.keys.toList()) {
    if (id == anchor.id || favoriteIds.contains(id)) {
      seasons = Map.of(seasons)..remove(id);
    }
  }
  for (final entry in entries) {
    if (entry.drama.id == anchor.id ||
        favoriteIds.contains(entry.drama.id) ||
        entry.season <= anchorSeason) {
      continue;
    }
    final previous = seasons[entry.drama.id];
    final notice = SeriesSeasonNotice(
      id: entry.drama.id,
      title: entry.drama.title,
      season: entry.season,
      unit: entry.unit,
      read: previous?.read ?? false,
    );
    if (previous?.title == notice.title &&
        previous?.season == notice.season &&
        previous?.unit == notice.unit &&
        previous?.read == notice.read) {
      continue;
    }
    seasons = Map.of(seasons)..[notice.id] = notice;
  }
  return identical(seasons, state.seriesSeasons)
      ? state
      : state.copyWith(seriesSeasons: seasons);
}

List<String> hongguoNextSeasonQueries(Drama anchor) {
  final info = hongguoSeriesInfo(anchor);
  final base = info?.baseTitle ?? anchor.title.trim();
  final next = (info?.season ?? 1) + 1;
  final unit = info?.unit ?? '季';
  if (base.isEmpty || next > _hongguoSeriesLimit) return const [];
  const digits = '零一二三四五六七八九';
  String chinese(int value) {
    if (value < 10) return digits[value];
    if (value < 100) {
      return '${value < 20 ? '' : digits[value ~/ 10]}十${value % 10 == 0 ? '' : digits[value % 10]}';
    }
    final rest = value % 100;
    return '${digits[value ~/ 100]}百${rest == 0 ? '' : '${rest < 10 ? '零' : ''}${chinese(rest)}'}';
  }

  return [
    '$base 第${chinese(next)}$unit',
    RegExp(r'[0-9]$').hasMatch(anchor.title.trim())
        ? '$base$next'
        : '$base 第$next$unit',
  ];
}

final _seriesTitleKeys = Expando<String>();

String _seriesTitleKey(Drama drama) => _seriesTitleKeys[drama] ??=
    normalizedSearchText(hongguoSeriesInfo(drama)?.baseTitle ?? drama.title);

bool hongguoSameSeries(Drama anchor, Drama candidate) {
  if (anchor.source != candidate.source ||
      anchor.source != SourceSite.hongguo.id) {
    return false;
  }
  final left = _seriesTitleKey(anchor);
  final right = _seriesTitleKey(candidate);
  if (left.isEmpty || right.isEmpty) return false;
  if (left != right && !hongguoSimilarSeriesTitles(anchor, candidate)) {
    return false;
  }
  final leftNames = hongguoSeriesCharacters(anchor.description);
  final rightNames = hongguoSeriesCharacters(candidate.description);
  final sharedNames = leftNames.intersection(rightNames);
  if (left == right && left.isNotEmpty) {
    return leftNames.isEmpty || rightNames.isEmpty || sharedNames.isNotEmpty;
  }
  return sharedNames.isNotEmpty;
}

bool hongguoSimilarSeriesTitles(Drama anchor, Drama candidate) {
  if (anchor.source != candidate.source ||
      anchor.source != SourceSite.hongguo.id)
    return false;
  final left = _seriesTitleKey(anchor);
  final right = _seriesTitleKey(candidate);
  if (left == right && left.isNotEmpty) return true;
  Set<String> pairs(String text) => {
    for (var i = 0; i + 1 < text.length; i++) text.substring(i, i + 2),
  };
  final a = pairs(left), b = pairs(right);
  if (a.isEmpty ||
      b.isEmpty ||
      2 * a.intersection(b).length / (a.length + b.length) < 0.72) {
    return false;
  }
  return true;
}

final _seriesCharacterPattern = RegExp(
  r'(?:主角|男主角?|女主角?|主人公|少年|少女|青年|[。！？；，]|^)[：:、\s]*([\u4e00-\u9fff]{2,3}?)(?=在|是|被|因|为|与|和|从|本|意外|重生|穿越|觉醒|获得|发现|遭|踏|带|凭|，|。|、|\s|$)',
);
Set<String> hongguoSeriesCharacters(String text) {
  const generic = {
    '一个',
    '一位',
    '他们',
    '她们',
    '自己',
    '故事',
    '为了',
    '后来',
    '然而',
    '最终',
    '少年',
    '少女',
    '青年',
  };
  return _seriesCharacterPattern
      .allMatches(text)
      .map((m) => m[1]!)
      .where(
        (name) => !generic.contains(name) && _seriesSurnames.contains(name[0]),
      )
      .toSet();
}

const _seriesSurnames =
    '赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳唐罗薛雷贺倪汤滕殷毕郝邬安常乐于傅皮齐康伍余元顾孟平黄和穆萧尹姚邵湛汪祁毛狄米贝明臧计伏成戴宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯管卢莫经房裘缪干解应宗丁宣邓单洪包左石崔吉龚程嵇邢裴陆荣翁荀羊甄封芮储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯全秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍桑桂濮牛寿通边扈燕冀浦尚农温别庄晏柴瞿阎连茹习艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷辛阚简饶曾毋沙乜养鞠须丰巢关蒯相查荆红游竺权逯盖益桓公墨楚洛秦许陆顾萧夜楚风唐白玄慕南北西';
