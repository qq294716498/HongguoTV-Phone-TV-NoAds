import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/danmaku_emoji_assets.dart';
import 'package:duanju_app/danmaku_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'danmaku_text_test.dart' show officialDouyinExpressionNames;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all 236 named expression equivalents use bundled Fluent PNGs', () {
    final names = {
      ...officialDouyinExpressionNames,
      '捂嘴笑',
      '惊讶',
      '惊呆',
      '灵光一闪',
      '爱慕',
      '酷',
      '睡',
      '睡觉',
      '流汗',
      '冷汗',
      '亲亲',
      '拥抱',
      '祈祷',
      '加油',
      '狗头',
      '爽',
      '怒',
      '笑',
      '哭',
      '什么',
      '敬礼',
      '吃瓜',
    };
    expect(names, hasLength(236));
    final glyphs = <String>{};
    for (final name in names) {
      for (final glyph in danmakuDisplayText('[$name]').characters) {
        expect(DanmakuEmojiAssets.paths, contains(glyph), reason: name);
        glyphs.add(glyph);
      }
    }
    expect(glyphs, hasLength(145));
    expect(DanmakuEmojiAssets.paths.keys.toSet(), glyphs);
  });

  test(
    'every bundled original PNG matches immutable upstream provenance',
    () async {
      final manifest =
          jsonDecode(
                await rootBundle.loadString(
                  '${DanmakuEmojiAssets.directory}provenance.json',
                ),
              )
              as Map<String, dynamic>;
      expect(manifest['source'], 'https://github.com/microsoft/fluentui-emoji');
      expect(manifest['revision'], matches(r'^[a-f0-9]{40}$'));
      expect(manifest['license'], 'MIT');
      final rows = manifest['files'] as List;
      expect(rows, hasLength(145));
      for (final row in rows.cast<Map<String, dynamic>>()) {
        expect(DanmakuEmojiAssets.paths[row['glyph']], row['file']);
        final data = await rootBundle.load(
          '${DanmakuEmojiAssets.directory}${row['file']}',
        );
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(bytes.length, row['bytes']);
        expect(sha256.convert(bytes).toString(), row['sha256']);
        expect(
          sha1.convert([
            ...utf8.encode('blob ${bytes.length}\u0000'),
            ...bytes,
          ]).toString(),
          row['upstream_blob_sha1'],
        );
      }
    },
  );

  test(
    'Fluent MIT copyright is bundled and registered once for the license screen',
    () async {
      final license = await rootBundle.loadString(
        '${DanmakuEmojiAssets.directory}LICENSE.txt',
      );
      expect(license, contains('MIT License'));
      expect(license, contains('Copyright (c) Microsoft Corporation.'));
      expect(license, contains('permission notice shall be included'));
      DanmakuEmojiAssets.registerLicenses();
      DanmakuEmojiAssets.registerLicenses();
      final entries = await LicenseRegistry.licenses
          .where((entry) => entry.packages.contains('Microsoft Fluent Emoji'))
          .toList();
      expect(entries, hasLength(1));
      expect(
        entries.single.paragraphs.map((p) => p.text).join('\n'),
        contains('Copyright (c) Microsoft Corporation.'),
      );
    },
  );
}
