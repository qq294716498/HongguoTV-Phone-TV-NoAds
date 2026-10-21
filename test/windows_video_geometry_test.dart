import 'package:flutter_test/flutter_test.dart';

import '../integration_test/windows_video_layout_test.dart'
    show geometryChainFailures;

Map<String, Object?> snapshot({double dpr = 1, bool fullscreen = true}) => {
  'fullscreen': fullscreen,
  'devicePixelRatio': dpr,
  'viewPhysicalSize': [1920, 1080],
  'page': [0, 0, 1920 / dpr, 1080 / dpr],
  'scaffold': [0, 0, 1920 / dpr, 1080 / dpr],
  'pane': [0, 0, 1920 / dpr, 1080 / dpr],
  'native': <String, Object?>{
    'geometryAvailable': true,
    'clientBounds': [-1920, 0, 1920, 1080],
    'flutterChildClientBounds': [-1920, 0, 1920, 1080],
    'monitorBounds': [-1920, 0, 1920, 1080],
    'dpi': 96 * dpr,
  },
};

void main() {
  test(
    'full client matches monitor and Flutter at negative monitor origins and DPI scaling',
    () {
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        expect(geometryChainFailures(snapshot(dpr: dpr)), isEmpty);
      }
    },
  );
  test(
    'a self-consistent contained texture cannot hide a shortened Flutter video pane',
    () {
      final sample = snapshot()..['pane'] = [0, 0, 1920, 1013];
      expect(
        geometryChainFailures(sample).single,
        startsWith('fullscreen video viewport'),
      );
    },
  );
  test(
    'a smaller native client is detected even when every Flutter layer agrees with it',
    () {
      final sample = snapshot();
      final native = sample['native'] as Map;
      native['clientBounds'] = [-1920, 0, 1920, 1013];
      native['flutterChildClientBounds'] = [-1920, 0, 1920, 1013];
      sample['viewPhysicalSize'] = [1920, 1013];
      for (final field in ['page', 'scaffold', 'pane']) {
        sample[field] = [0, 0, 1920, 1013];
      }
      expect(
        geometryChainFailures(sample).single,
        startsWith('fullscreen client / monitor'),
      );
    },
  );
  test(
    'native Flutter child clipping is detected before video aspect calculations',
    () {
      final sample = snapshot();
      (sample['native'] as Map)['flutterChildClientBounds'] = [
        -1920,
        0,
        1920,
        1013,
      ];
      expect(
        geometryChainFailures(sample).single,
        startsWith('Flutter child client'),
      );
    },
  );
  test(
    'Flutter render surface and Scaffold underfill are reported separately',
    () {
      final sample = snapshot();
      sample['viewPhysicalSize'] = [1920, 1013];
      expect(
        geometryChainFailures(
          sample,
        ).any((s) => s.startsWith('Flutter physical view')),
        isTrue,
      );
      final scaffold = snapshot()..['scaffold'] = [0, 0, 1920, 1013];
      expect(geometryChainFailures(scaffold).single, startsWith('Scaffold'));
    },
  );
  test(
    'ordinary window toolbar/sidebar space is permitted and unavailable native data never passes silently',
    () {
      final sample = snapshot(fullscreen: false)
        ..['pane'] = [0, 56, 1608, 1024];
      expect(geometryChainFailures(sample), isEmpty);
      (sample['native'] as Map)['geometryAvailable'] = false;
      expect(geometryChainFailures(sample), ['native geometry unavailable']);
    },
  );
  test(
    'a DPI units mismatch cannot be treated as matching view dimensions',
    () {
      final sample = snapshot();
      (sample['native'] as Map)['dpi'] = 144;
      expect(geometryChainFailures(sample), [
        'native DPI / Flutter DPR mismatch',
      ]);
    },
  );
}
