import 'package:duanju_app/lan_sync_models.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = Drama(
  id: 'hongguo:priority-s1',
  source: 'hongguo',
  title: '合成进度 第一季',
  seriesGroupId: '100',
  episodes: 100,
);
const _second = Drama(
  id: 'hongguo:priority-s2',
  source: 'hongguo',
  title: '合成进度 第二季',
  seriesGroupId: '100',
  episodes: 100,
);
const _third = Drama(
  id: 'hongguo:priority-s3',
  source: 'hongguo',
  title: '合成进度 第三季',
  seriesGroupId: '100',
  episodes: 100,
);

WatchEntry _watch(
  Drama drama,
  int episode, {
  int minute = 1,
  double position = 17,
  double duration = 120,
}) => WatchEntry(
  drama: drama,
  episode: episode,
  position: position,
  duration: duration,
  updatedAt: DateTime.utc(2026, 11, 2, 12, minute),
);

LanCell _cell(Object? value, String replica, int revision) => LanCell([
  LanValue(LanVersion({replica: revision}), value),
]);

LanRecord _record(
  WatchEntry? watch, {
  Drama anchor = _first,
  String replica = '11111111111111111111111111111111',
  int revision = 1,
  bool followed = true,
  Iterable<String> cleared = const [],
}) => LanRecord(
  drama: anchor,
  member: _cell(followed, replica, revision),
  status: _cell({'status': 'watching', 'manual': false}, replica, revision),
  progress: _cell(lanProgress(watch, cleared: cleared), replica, revision),
  known: anchor.episodes,
);

LanDocument _writer() =>
    LanDocument(replica: 'cccccccccccccccccccccccccccccccc');

LanRecord _resolve(LanRecord a, LanRecord b, LanDocument writer) =>
    lanResolveProgress(a.merge(b), [a, b], writer);

void main() {
  test(
    'a higher season retains its whole progress despite a newer lower season',
    () {
      final high = _record(_watch(_third, 1, position: 23, duration: 123));
      final low = _record(
        _watch(_second, 99, minute: 9, position: 81, duration: 181),
        replica: '22222222222222222222222222222222',
      );

      final result = _resolve(high, low, _writer());

      expect(result.progress.conflict, false);
      expect(result.progress.value, high.progress.value);
      expect(result.watch!.drama.id, _third.id);
      expect(result.watch!.episode, 1);
      expect(result.watch!.position, 23);
      expect(result.watch!.duration, 123);
      expect(result.watch!.updatedAt, high.watch!.updatedAt);
    },
  );

  test(
    'a higher episode wins over newer lower progress within the same season',
    () {
      final high = _record(_watch(_third, 20));
      final low = _record(
        _watch(_third, 19, minute: 9, position: 99),
        replica: '22222222222222222222222222222222',
      );

      expect(
        _resolve(high, low, _writer()).progress.value,
        high.progress.value,
      );
    },
  );

  test('the newest same-episode seek keeps its smaller position', () {
    final old = _record(_watch(_third, 20, position: 90));
    final seek = _record(
      _watch(_third, 20, minute: 9, position: 4, duration: 121),
      replica: '22222222222222222222222222222222',
    );

    expect(_resolve(old, seek, _writer()).progress.value, seek.progress.value);
  });

  test(
    'an exact timestamp tie prefers the larger position as a whole value',
    () {
      final low = _record(_watch(_third, 20, position: 20, duration: 122));
      final high = _record(
        _watch(_third, 20, position: 40, duration: 144),
        replica: '22222222222222222222222222222222',
      );

      expect(
        _resolve(low, high, _writer()).progress.value,
        high.progress.value,
      );
    },
  );

  test(
    'equal visible progress resolves deterministically without mixing values',
    () {
      final a = _record(_watch(_third, 20, duration: 122));
      final b = _record(
        _watch(_third, 20, duration: 144),
        replica: '22222222222222222222222222222222',
      );

      final forward = _resolve(a, b, _writer());
      final reverse = _resolve(b, a, _writer());

      expect(forward.progress.conflict, false);
      expect(forward.progress.value, reverse.progress.value);
      expect([
        lanJSON(a.progress.value),
        lanJSON(b.progress.value),
      ], contains(lanJSON(forward.progress.value)));
    },
  );

  test('causally newer lower progress needs a fresh resolution event', () {
    final high = _record(_watch(_third, 20));
    final low = _record(_watch(_third, 19, minute: 9), revision: 2);
    final merged = high.merge(low);
    expect(merged.progress.value, low.progress.value);

    final writer = _writer();
    final result = lanResolveProgress(merged, [high, low], writer);

    expect(result.progress.value, high.progress.value);
    expect(result.progress.version.includes(high.progress.version), true);
    expect(result.progress.version.includes(low.progress.version), true);
    expect(
      lanJSON(result.progress.version.toJson()),
      isNot(lanJSON(low.progress.version.toJson())),
    );
    expect(
      low.progress.merge(result.progress).toJson(),
      result.progress.toJson(),
    );
    expect(writer.counter, 1);
  });

  test(
    'already selected progress stays stable without advancing the writer',
    () {
      final low = _record(_watch(_third, 19));
      final high = _record(_watch(_third, 20, minute: 9), revision: 2);
      final merged = low.merge(high);
      final writer = _writer();

      final result = lanResolveProgress(merged, [low, high], writer);

      expect(result.toJson(), merged.toJson());
      expect(writer.counter, 0);
    },
  );

  test('a repeated resolution stays stable after convergence', () {
    final a = _record(_watch(_third, 20));
    final b = _record(
      _watch(_third, 19, minute: 9),
      replica: '22222222222222222222222222222222',
    );
    final writer = _writer();
    final first = _resolve(a, b, writer);
    final counter = writer.counter;

    final next = lanResolveProgress(first, [first, a, b], writer);

    expect(next.toJson(), first.toJson());
    expect(writer.counter, counter);
  });

  test('an effective null conflict keeps existing clear semantics', () {
    final clear = _record(null);
    final watched = _record(
      _watch(_third, 20),
      replica: '22222222222222222222222222222222',
    );
    final merged = clear.merge(watched);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [clear, watched], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test('a causally effective clear is not revived by an old high season', () {
    final high = _record(_watch(_third, 20));
    final clear = _record(null, revision: 2);
    final writer = _writer();

    final result = _resolve(high, clear, writer);

    expect(result.progress.value, isNull);
    expect(writer.counter, 0);
  });

  test('an unfollowed record is not changed by progress priority', () {
    final high = _record(_watch(_third, 20));
    final low = _record(
      _watch(_third, 19, minute: 9),
      revision: 2,
      followed: false,
    );
    final merged = high.merge(low);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [high, low], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test('an effective cleared season excludes its stale high progress', () {
    final high = _record(_watch(_third, 20));
    final remaining = _record(
      _watch(_second, 19, minute: 9),
      revision: 2,
      cleared: [_third.id],
    );
    final writer = _writer();

    expect(_resolve(high, remaining, writer).toJson(), remaining.toJson());
    expect(writer.counter, 0);
  });

  test('a high season preserves an effective unrelated season deletion', () {
    final high = _record(_watch(_third, 20, position: 33, duration: 133));
    final lowerWithClear = _record(
      _watch(_second, 19, minute: 9, position: 55, duration: 155),
      revision: 2,
      cleared: [_first.id],
    );

    final result = _resolve(high, lowerWithClear, _writer());
    final value = Map<String, dynamic>.of(lanMap(result.progress.value));
    final cleared = value.remove('cleared');

    expect(value, high.progress.value);
    expect(cleared, [_first.id]);
    expect(result.watch!.drama.id, _third.id);
    expect(result.watch!.episode, 20);
    expect(result.watch!.position, 33);
    expect(result.watch!.duration, 133);
    expect(result.watch!.updatedAt, high.watch!.updatedAt);
  });

  test(
    'superseded cleared IDs do not return after an intentional new watch',
    () {
      final oldClear = _record(_watch(_second, 19), cleared: [_third.id]);
      final resumed = _record(_watch(_third, 20, minute: 9), revision: 2);
      final result = _resolve(oldClear, resumed, _writer());

      expect(result.progress.value, resumed.progress.value);
      expect(result.clearedProgressIds, isEmpty);
    },
  );

  test(
    'an oversized effective cleared union keeps the original valid conflict',
    () {
      final high = _record(
        _watch(_third, 20),
        cleared: List.generate(1000, (index) => 'hongguo:cleared-$index'),
      );
      final low = _record(
        _watch(_second, 19, minute: 9),
        replica: '22222222222222222222222222222222',
        cleared: List.generate(
          1000,
          (index) => 'hongguo:cleared-${index + 500}',
        ),
      );
      final merged = LanRecord.fromJson(
        high.toJson(),
      ).merge(LanRecord.fromJson(low.toJson()));
      final writer = _writer();

      final result = lanResolveProgress(merged, [high, low], writer);

      expect(result.toJson(), merged.toJson());
      expect(LanRecord.fromJson(result.toJson()).progress.conflict, true);
      expect(writer.counter, 0);
    },
  );

  test(
    'a legacy winner with effective clears receives its actual anchor identity',
    () {
      final high = _record(_watch(_third, 20), anchor: _third);
      final legacyValue = Map<String, dynamic>.of(lanMap(high.progress.value))
        ..remove('drama');
      final legacy = high.withField(
        'progress',
        _cell(legacyValue, '11111111111111111111111111111111', 1),
      );
      final low = _record(
        _watch(_second, 19, minute: 9),
        anchor: _third,
        revision: 2,
        cleared: [_first.id],
      );

      final result = _resolve(legacy, low, _writer());
      final checked = LanRecord.fromJson(result.toJson());

      expect(checked.progress.value, {
        ...legacyValue,
        'drama': _third.toJson(),
        'cleared': [_first.id],
      });
      expect(checked.watch!.drama.id, _third.id);
      expect(checked.watch!.episode, 20);
      expect(checked.watch!.position, high.watch!.position);
      expect(checked.watch!.duration, high.watch!.duration);
      expect(checked.watch!.updatedAt, high.watch!.updatedAt);
    },
  );

  test(
    'disjoint identified characters keep a same-title cross-season conflict',
    () {
      const anchor = Drama(
        id: 'hongguo:characters-s1',
        source: 'hongguo',
        title: '角色合成 第一季',
      );
      const second = Drama(
        id: 'hongguo:characters-s2',
        source: 'hongguo',
        title: '角色合成 第二季',
        description: '主角林川在城市重生。',
      );
      const third = Drama(
        id: 'hongguo:characters-s3',
        source: 'hongguo',
        title: '角色合成 第三季',
        description: '主角陈默在异界觉醒。',
      );
      final a = _record(_watch(second, 99), anchor: anchor);
      final b = _record(
        _watch(third, 1),
        anchor: anchor,
        replica: '22222222222222222222222222222222',
      );
      final merged = LanRecord.fromJson(
        a.toJson(),
      ).merge(LanRecord.fromJson(b.toJson()));
      final writer = _writer();

      expect(
        lanResolveProgress(merged, [a, b], writer).toJson(),
        merged.toJson(),
      );
      expect(writer.counter, 0);
    },
  );

  test('different official groups remain unresolved', () {
    const otherFirst = Drama(
      id: 'hongguo:priority-s1',
      source: 'hongguo',
      title: '合成进度 第一季',
      seriesGroupId: '200',
    );
    const otherThird = Drama(
      id: 'hongguo:other-s3',
      source: 'hongguo',
      title: '合成进度 第三季',
      seriesGroupId: '200',
    );
    final a = _record(_watch(_second, 99));
    final b = _record(
      _watch(otherThird, 1),
      anchor: otherFirst,
      replica: '22222222222222222222222222222222',
    );
    final merged = a.merge(b);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [a, b], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test('different IDs for the same season retain edition ambiguity', () {
    const edition = Drama(
      id: 'hongguo:priority-s3-edition',
      source: 'hongguo',
      title: '合成进度 第三季',
      seriesGroupId: '100',
    );
    final a = _record(_watch(_third, 20));
    final b = _record(
      _watch(edition, 99, minute: 9),
      replica: '22222222222222222222222222222222',
    );
    final merged = a.merge(b);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [a, b], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test('edition ambiguity is checked between every surviving candidate', () {
    const secondEdition = Drama(
      id: 'hongguo:priority-s2-edition',
      source: 'hongguo',
      title: '合成进度 第二季',
      seriesGroupId: '100',
    );
    final high = _record(_watch(_third, 1));
    final low = _record(
      _watch(_second, 19),
      replica: '22222222222222222222222222222222',
    );
    final edition = _record(
      _watch(secondEdition, 99),
      replica: '33333333333333333333333333333333',
    );
    final merged = high.merge(low).merge(edition);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [high, low, edition], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test(
    'a planner can retain ambiguity absent from a receiver candidate subset',
    () {
      const priorEdition = Drama(
        id: 'hongguo:priority-s3-prior-edition',
        source: 'hongguo',
        title: '合成进度 第三季',
        seriesGroupId: '100',
      );
      final old = _record(_watch(priorEdition, 1));
      LanRecord successor(int episode, String replica) =>
          _record(_watch(_third, episode), replica: replica).withField(
            'progress',
            LanCell([
              LanValue(
                LanVersion({'11111111111111111111111111111111': 1, replica: 1}),
                lanProgress(_watch(_third, episode)),
              ),
            ]),
          );
      final high = successor(20, '22222222222222222222222222222222');
      final low = successor(19, '33333333333333333333333333333333');
      final receiverOld = high.merge(low);
      final merged = old.merge(receiverOld);

      final planned = lanResolveProgress(merged, [old, receiverOld], _writer());
      final receiverReevaluation = lanResolveProgress(planned, [
        receiverOld,
        planned,
      ], _writer());

      expect(planned.progress.conflict, true);
      expect(receiverReevaluation.progress.conflict, false);
      expect(receiverReevaluation.watch!.episode, 20);
      expect(planned.hash, isNot(receiverOld.hash));
    },
  );

  test('the same actual drama with an unknown season still ranks episodes', () {
    const unknown = Drama(
      id: 'hongguo:priority-unknown',
      source: 'hongguo',
      title: '合成未知篇章',
    );
    final high = _record(_watch(unknown, 20), anchor: unknown);
    final low = _record(
      _watch(unknown, 19, minute: 9),
      anchor: unknown,
      replica: '22222222222222222222222222222222',
    );

    expect(_resolve(high, low, _writer()).progress.value, high.progress.value);
  });

  test('two distinct dramas without trustworthy seasons stay unresolved', () {
    const aDrama = Drama(
      id: 'hongguo:priority-unknown-a',
      source: 'hongguo',
      title: '合成未知篇章',
      seriesGroupId: '100',
    );
    const bDrama = Drama(
      id: 'hongguo:priority-unknown-b',
      source: 'hongguo',
      title: '合成未知篇章',
      seriesGroupId: '100',
    );
    final a = _record(_watch(aDrama, 20));
    final b = _record(
      _watch(bDrama, 99, minute: 9),
      replica: '22222222222222222222222222222222',
    );
    final merged = a.merge(b);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [a, b], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test('a matching bare first-season title follows trusted series parsing', () {
    const bare = Drama(
      id: 'hongguo:priority-bare',
      source: 'hongguo',
      title: '合成进度',
      seriesGroupId: '100',
    );
    final first = _record(_watch(bare, 99, minute: 9));
    final third = _record(
      _watch(_third, 1),
      replica: '22222222222222222222222222222222',
    );

    expect(
      _resolve(first, third, _writer()).progress.value,
      third.progress.value,
    );
  });

  test('an unrelated bare title is not assigned a season from group alone', () {
    const unrelated = Drama(
      id: 'hongguo:priority-unrelated-bare',
      source: 'hongguo',
      title: '另一合成篇章',
      seriesGroupId: '100',
    );
    final a = _record(_watch(unrelated, 99, minute: 9));
    final b = _record(
      _watch(_third, 1),
      replica: '22222222222222222222222222222222',
    );
    final merged = a.merge(b);
    final writer = _writer();

    expect(
      lanResolveProgress(merged, [a, b], writer).toJson(),
      merged.toJson(),
    );
    expect(writer.counter, 0);
  });

  test(
    'legacy progress uses its actual anchor without inventing watch fields',
    () {
      final high = _record(_watch(_third, 20), anchor: _third);
      final legacyValue = Map<String, dynamic>.of(lanMap(high.progress.value))
        ..remove('drama');
      final legacy = high.withField(
        'progress',
        _cell(legacyValue, '11111111111111111111111111111111', 1),
      );
      final low = _record(
        _watch(_third, 19, minute: 9),
        anchor: _third,
        replica: '22222222222222222222222222222222',
      );

      final result = _resolve(legacy, low, _writer());

      expect(result.progress.value, legacyValue);
      expect(result.watch!.drama.id, _third.id);
      expect(result.watch!.episode, 20);
    },
  );

  test(
    'different content at an identical clock still fails before resolution',
    () {
      final a = _record(_watch(_third, 20));
      final b = _record(_watch(_third, 19, minute: 9));

      expect(() => a.merge(b), throwsFormatException);
    },
  );
}
