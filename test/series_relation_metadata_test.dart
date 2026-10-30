import 'dart:convert';

import 'package:duanju_app/lan_sync_models.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const drama = Drama(
    id: 'hongguo:12345',
    source: 'hongguo',
    sourceId: '12345',
    title: '合成系列第二季',
    seriesGroupId: '7674918785786072088',
    relatedAlbumId: '7640040862889544729',
  );

  test('official group and album IDs round trip as distinct strings', () {
    final restored = Drama.fromJson(jsonDecode(jsonEncode(drama.toJson())));
    expect(restored.id, drama.id);
    expect(restored.sourceId, drama.sourceId);
    expect(restored.seriesGroupId, drama.seriesGroupId);
    expect(restored.relatedAlbumId, drama.relatedAlbumId);
    expect(restored.seriesGroupId, isNot(restored.relatedAlbumId));
  });

  test('old drama metadata keeps relation fields unknown', () {
    final restored = Drama.fromJson({
      'id': drama.id,
      'source': 'hongguo',
      'title': drama.title,
    });
    expect(restored.seriesGroupId, isEmpty);
    expect(restored.relatedAlbumId, isEmpty);
    expect(restored.toJson(), isNot(contains('seriesGroupId')));
    expect(restored.toJson(), isNot(contains('relatedAlbumId')));
  });

  test('sparse metadata does not erase verified relation IDs', () {
    final fresh = Drama(id: drama.id, source: 'hongguo', title: '补充元数据');
    final merged = drama.merge(fresh);
    expect(merged.seriesGroupId, drama.seriesGroupId);
    expect(merged.relatedAlbumId, drama.relatedAlbumId);
  });

  test('compact metadata preserves watch identity and playback state', () {
    final original = WatchEntry(
      drama: lanCompactDrama(drama),
      episode: 3,
      position: 43.5,
      duration: 120,
      updatedAt: DateTime.utc(2026, 10, 30, 12),
    );
    final restored = WatchEntry.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(restored.drama.id, drama.id);
    expect(restored.drama.sourceId, drama.sourceId);
    expect(restored.drama.seriesGroupId, drama.seriesGroupId);
    expect(restored.drama.relatedAlbumId, drama.relatedAlbumId);
    expect(restored.episode, original.episode);
    expect(restored.position, original.position);
    expect(restored.duration, original.duration);
    expect(restored.updatedAt, original.updatedAt);
  });

  test('fresh relations replace known values only on the same drama', () {
    final changed = drama.merge(
      Drama(
        id: drama.id,
        source: 'hongguo',
        title: drama.title,
        seriesGroupId: '100',
        relatedAlbumId: '200',
      ),
    );
    expect(changed.seriesGroupId, '100');
    expect(changed.relatedAlbumId, '200');
    const other = Drama(id: 'hongguo:54321', source: 'hongguo', title: '另一部剧');
    final separate = drama.merge(other);
    expect(separate.id, other.id);
    expect(separate.seriesGroupId, isEmpty);
    expect(separate.relatedAlbumId, isEmpty);
  });

  test(
    'untrusted relation values cannot become official identity evidence',
    () {
      for (final value in [
        null,
        100,
        false,
        <String, dynamic>{},
        '',
        '0',
        '000',
        '-1',
        '1e3',
        '1.5',
        'https://example.test/100',
        '1' * 33,
      ]) {
        final restored = Drama.fromJson({
          ...drama.toJson(),
          'seriesGroupId': value,
          'relatedAlbumId': value,
        });
        expect(restored.seriesGroupId, isEmpty, reason: '$value');
        expect(restored.relatedAlbumId, isEmpty, reason: '$value');
      }
    },
  );
}
