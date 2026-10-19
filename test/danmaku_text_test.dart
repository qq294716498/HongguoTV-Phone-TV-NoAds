import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/danmaku_text.dart';
import 'package:flutter_test/flutter_test.dart';

const officialDouyinExpressionNames = <String>[
  '微笑',
  '色',
  '发呆',
  '酷拽',
  '抠鼻',
  '流泪',
  '捂脸',
  '发怒',
  '呲牙',
  '尬笑',
  '害羞',
  '调皮',
  '舔屏',
  '看',
  '爱心',
  '比心',
  '赞',
  '鼓掌',
  '感谢',
  '抱抱你',
  '玫瑰',
  '尴尬流汗',
  '戳手手',
  '星星眼',
  '杀马特',
  '黄脸干杯',
  '抱紧自己',
  '拜拜',
  '热化了',
  '黄脸祈祷',
  '懵',
  '举手',
  '加功德',
  '摊手',
  '无语流汗',
  '续火花吧',
  '点火',
  '哭哭',
  '吐舌小狗',
  '送花',
  '爱心手',
  '贴贴',
  '灵机一动',
  '耶',
  '打脸',
  '大笑',
  '机智',
  '送心',
  '666',
  '闭嘴',
  '来看我',
  '一起加油',
  '哈欠',
  '震惊',
  '晕',
  '衰',
  '困',
  '疑问',
  '泣不成声',
  '小鼓掌',
  '大金牙',
  '偷笑',
  '石化',
  '思考',
  '吐血',
  '可怜',
  '嘘',
  '撇嘴',
  '笑哭',
  '奸笑',
  '得意',
  '憨笑',
  '坏笑',
  '抓狂',
  '泪奔',
  '钱',
  '恐惧',
  '愉快',
  '快哭了',
  '翻白眼',
  '互粉',
  '我想静静',
  '委屈',
  '鄙视',
  '飞吻',
  '再见',
  '紫薇别走',
  '听歌',
  '求抱抱',
  '绝望的凝视',
  '不失礼貌的微笑',
  '不看',
  '裂开',
  '干饭人',
  '庆祝',
  '吐舌',
  '呆无辜',
  '白眼',
  '猪头',
  '冷漠',
  '暗中观察',
  '二哈',
  '菜狗',
  '黑脸',
  '展开说说',
  '蜜蜂狗',
  '柴犬',
  '摸头',
  '皱眉',
  '擦汗',
  '红脸',
  '做鬼脸',
  '强',
  '如花',
  '吐',
  '惊喜',
  '敲打',
  '奋斗',
  '吐彩虹',
  '大哭',
  '嘿哈',
  '惊恐',
  '囧',
  '难过',
  '斜眼',
  '阴险',
  '悠闲',
  '咒骂',
  '吃瓜群众',
  '绿帽子',
  '敢怒不敢言',
  '求求了',
  '眼含热泪',
  '叹气',
  '好开心',
  '不是吧',
  '鞠躬',
  '躺平',
  '九转大肠',
  '不你不想',
  '一头乱麻',
  'kisskiss',
  '你不大行',
  '噢买尬',
  '宕机',
  '苦涩',
  '逞强落泪',
  '求机位-黄脸',
  '求机位3',
  '点赞',
  '精选',
  '强壮',
  '碰拳',
  'OK',
  '击掌',
  '左上',
  '握手',
  '抱拳',
  '勾引',
  '拳头',
  '弱',
  '胜利',
  '右边',
  '左边',
  '嘴唇',
  '心碎',
  '凋谢',
  '愤怒',
  '垃圾',
  '啤酒',
  '咖啡',
  '蛋糕',
  '礼物',
  '撒花',
  '加一',
  '减一',
  'okk',
  'V5',
  '绝',
  '给力',
  '红包',
  '屎',
  '发',
  '18禁',
  '炸弹',
  '西瓜',
  '加鸡腿',
  '握爪',
  '太阳',
  '月亮',
  '给跪了',
  '蕉绿',
  '扎心',
  '胡瓜',
  '打call',
  '栓Q',
  '雪花',
  '圣诞树',
  '平安果',
  '圣诞帽',
  '气球',
  '烟花',
  '福',
  'candy',
  '糖葫芦',
  '鞭炮',
  '元宝',
  '灯笼',
  '锦鲤',
  '巧克力',
  '戒指',
  '棒棒糖',
  '纸飞机',
  '粽子',
];

void main() {
  test(
    'all 214 official catalog names convert with all three bracket pairs',
    () {
      expect(officialDouyinExpressionNames.toSet(), hasLength(214));
      for (final name in officialDouyinExpressionNames) {
        final ascii = danmakuDisplayText('[$name]');
        expect(ascii, isNotEmpty, reason: name);
        expect(ascii, isNot(contains(name)), reason: name);
        expect(ascii, isNot(matches(r'[\[\]【】［］]')), reason: name);
        expect(danmakuDisplayText('【$name】'), ascii, reason: name);
        expect(danmakuDisplayText('［$name］'), ascii, reason: name);
        expect(danmakuDisplayText(ascii), ascii, reason: name);
        expect(danmakuDisplayText('前[$name]后'), '前$ascii后', reason: name);
      }
    },
  );

  test('previous aliases and six user-reported names convert', () {
    const aliases = {
      '捂嘴笑': '🤭',
      '惊讶': '😮',
      '惊呆': '😲',
      '灵光一闪': '💡',
      '爱慕': '😍',
      '酷': '😎',
      '睡': '😴',
      '睡觉': '😴',
      '流汗': '😓',
      '冷汗': '😰',
      '亲亲': '😘',
      '拥抱': '🤗',
      '祈祷': '🙏',
      '加油': '💪',
      '狗头': '🐶',
      '爽': '😆',
      '怒': '😠',
      '笑': '😄',
      '哭': '😢',
      '什么': '❓',
      '敬礼': '🫡',
    };
    expect({...officialDouyinExpressionNames, ...aliases.keys}, hasLength(235));
    for (final entry in aliases.entries) {
      for (final pair in [('[', ']'), ('【', '】'), ('［', '］')]) {
        expect(
          danmakuDisplayText('${pair.$1}${entry.key}${pair.$2}'),
          entry.value,
        );
      }
    }
  });

  test(
    'new expressions mix with text and existing Unicode without losing text',
    () {
      expect(
        danmakuDisplayText('爽文[爽][怒]【发呆】［疑问］[送心][戳手手][加鸡腿]👍[未知表情]'),
        '爽文😆😠😶❓💝👉👈🍗👍[未知表情]',
      );
      expect(danmakuDisplayText('[666][给力][绝][抱抱你][热化了]'), '🤙💪🤩🤗🥵');
      expect(danmakuDisplayText('[求机位-黄脸][不失礼貌的微笑]'), '📍🙂');
      expect(danmakuDisplayText('[爽]【怒】［撇嘴］'), '😆😠😒');
      expect(danmakuDisplayText('[撇嘴]【撇嘴】［撇嘴］'), '😒😒😒');
    },
  );

  test('ordinary words and emoji stay byte-for-byte unchanged', () {
    const text = '看着真爽 爽文 太爽了 怒 怒气 撇嘴 大笑 OK 666 微笑【剧情发展】👩🏽‍💻 ❤️ 🥺';
    expect(danmakuDisplayText(text), text);
    expect(danmakuDisplayText(''), '');
    expect(danmakuDisplayText('  爽 \n'), '  爽 \n');
  });

  test('unknown, mismatched, spaced and incomplete tags are retained', () {
    const values = [
      '[未收录的新表情]',
      '【未收录的新表情】',
      '［未收录的新表情］',
      '[爽】',
      '【爽]',
      '［爽]',
      '[爽',
      '爽]',
      '[爽\n]',
      '[ 爽 ]',
      '[]【】［］',
      '[aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]',
      '(爽)（爽）',
    ];
    for (final text in values) {
      expect(danmakuDisplayText(text), text);
    }
    expect(danmakuDisplayText('[未知][爽]【另一个未知】'), '[未知]😆【另一个未知】');
  });

  test(
    'Latin tag aliases accept case differences without changing ordinary words',
    () {
      expect(
        danmakuDisplayText('[OK]【ok】［Ok］[oK][OKK][v5][KissKiss][CANDY][打CALL]'),
        '👌👌👌👌👌💪😘🍬📣',
      );
      expect(
        danmakuDisplayText('OK ok V5 kisskiss candy 打call [unknown]'),
        'OK ok V5 kisskiss candy 打call [unknown]',
      );
    },
  );

  test('conversion is idempotent with mixed aliases and compound emoji', () {
    const source = '前[爽][偷笑]【戳手手】［送心］[未知]👩🏽‍💻后';
    final once = danmakuDisplayText(source);
    expect(danmakuDisplayText(once), once);
    expect(once, contains('👩🏽‍💻'));
  });

  test(
    'source IDs, text and timeline are preserved when parsing and displaying',
    () {
      final page = DanmakuPage.fromJson(
        {
          'episodeId': 'one',
          'startMs': 0,
          'nextMs': 30000,
          'items': [
            {'id': 'source-id', 'text': '爽文[爽]【送心】[未知]', 'timeMs': 1234},
          ],
        },
        episodeId: 'one',
        startMs: 0,
        durationMs: 60000,
      );
      final item = page.items.single;
      expect(danmakuFlightText(item), '爽文[爽]【送心】[未知]');
      expect(item.id, 'source-id');
      expect(item.timeMs, 1234);
      expect(item.repeatCount, 1);
      expect(item.text, '爽文[爽]【送心】[未知]');
      expect(page.nextMs, 30000);
    },
  );

  test(
    'bracket aliases and Unicode merge once within existing timing window',
    () {
      const original = [
        DanmakuItem(id: 'first', text: '好看[爽]', timeMs: 1000, repeatCount: 2),
        DanmakuItem(id: 'first', text: '好看[爽]', timeMs: 1000),
        DanmakuItem(id: 'second', text: '好看【爽】', timeMs: 2000),
        DanmakuItem(id: 'third', text: '好看［爽］', timeMs: 3000),
        DanmakuItem(id: 'fourth', text: '好看😆', timeMs: 4000),
        DanmakuItem(id: 'outside', text: '好看[爽]', timeMs: 4001),
      ];
      final merged = mergeDanmaku(original);
      expect(merged.map((item) => item.id), ['first', 'outside']);
      expect(merged.map((item) => item.timeMs), [1000, 4001]);
      expect(merged.map((item) => item.repeatCount), [5, 1]);
      expect(danmakuFlightText(merged.first), '好看[爽]  ♥ 5');
      expect(danmakuFlightText(merged.last), '好看[爽]');
      expect(original.first.text, '好看[爽]');
    },
  );

  test(
    'ordinary and unknown bracket text do not become expression duplicates',
    () {
      final merged = mergeDanmaku(const [
        DanmakuItem(id: 'a', text: '爽', timeMs: 0),
        DanmakuItem(id: 'b', text: '[爽]', timeMs: 0),
        DanmakuItem(id: 'c', text: '[新表情甲]', timeMs: 0),
        DanmakuItem(id: 'd', text: '[新表情乙]', timeMs: 0),
      ]);
      expect(merged, hasLength(4));
      expect(merged.map((item) => item.text), ['爽', '[爽]', '[新表情甲]', '[新表情乙]']);
      expect(merged.every((item) => item.repeatCount == 1), isTrue);
    },
  );

  test(
    'layout measures lossless expression content once including the unchanged heart count',
    () {
      final measured = <String>[];
      const item = DanmakuItem(
        id: 'one',
        text: '爽文[爽]【戳手手】[未知]',
        timeMs: 1234,
        repeatCount: 3,
      );
      final flights = planDanmaku(
        [item],
        width: 800,
        rows: 2,
        measure: (text) {
          measured.add(text);
          return 180;
        },
      );
      expect(flights.single.text, '爽文[爽]【戳手手】[未知]  ♥ 3');
      expect(measured, [flights.single.text]);
      expect(flights.single.width, 188);
      expect(flights.single.item, same(item));
      expect(flights.single.lifetimeMs, danmakuLifetimeMs);
    },
  );

  test(
    'long expression lines keep whole graphemes and existing clipping limit',
    () {
      final text = '${List.filled(99, '字').join()}👩🏽‍💻[爽]';
      final rendered = danmakuFlightText(
        DanmakuItem(id: 'long', text: text, timeMs: 0),
      );
      expect(rendered, '${List.filled(99, '字').join()}👩🏽‍💻…');
      final aliases = List.filled(100, '[敬礼]').join();
      expect(
        danmakuFlightText(DanmakuItem(id: 'aliases', text: aliases, timeMs: 0)),
        aliases,
      );
      expect(
        danmakuFlightText(
          DanmakuItem(
            id: 'overflow',
            text: '${List.filled(99, '字').join()}[戳手手]',
            timeMs: 0,
          ),
        ),
        '${List.filled(99, '字').join()}…',
      );
    },
  );
}
