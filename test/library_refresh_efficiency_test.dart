import 'dart:collection';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _ObservedStore extends LocalStore {
  _ObservedStore(super.preferences);
  int historyReads = 0;
  @override
  List<WatchEntry> get history {
    historyReads++;
    return super.history;
  }
}

class _ObservedKeys extends ListBase<String> {
  _ObservedKeys(this.values);
  final List<String> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('fixed');
  @override
  String operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, String value) => throw UnsupportedError('fixed');
}

void main() {
  testWidgets(
    'favorites do not materialize sorted history, while filtered history keeps correct resume',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = _ObservedStore(await SharedPreferences.getInstance());
      const complete = Drama(
        id: 'hongguo:complete',
        source: 'hongguo',
        title: '合成记录甲',
        episodes: 2,
      );
      const unfinished = Drama(
        id: 'hongguo:unfinished',
        source: 'hongguo',
        title: '合成记录乙',
        episodes: 2,
      );
      await store.saveWatch(
        WatchEntry(
          drama: complete,
          episode: 2,
          position: 120,
          duration: 120,
          updatedAt: DateTime(2026, 10, 16),
        ),
      );
      await store.saveWatch(
        WatchEntry(
          drama: unfinished,
          episode: 1,
          position: 10,
          duration: 120,
          updatedAt: DateTime(2026, 10, 15),
        ),
      );
      await store.toggleSeriesFavorite(unfinished);
      final repository = FixtureRepository();
      String? resumed;
      Widget page(bool history) => MaterialApp(
        home: Scaffold(
          body: SavedLibrary(
            repository: repository,
            store: store,
            history: history,
            onOpen: (_) {},
            onContinue: (drama) => resumed = drama.id,
          ),
        ),
      );
      store.historyReads = 0;
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('favorites-search')),
        '合成',
      );
      await tester.pumpAndSettle();
      expect(store.historyReads, 0);
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(store.historyReads, greaterThan(0));
      await tester.enterText(
        find.byKey(const ValueKey('history-search')),
        '合成记录',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('continue-watching')));
      expect(resumed, unfinished.id);
      await tester.enterText(find.byKey(const ValueKey('history-search')), '甲');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('continue-watching')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await store.flushPendingWrites();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'large reordered grid refresh has linear key reads and preserves activation',
    (tester) async {
      final initial = List.generate(1200, (index) => 'key-$index');
      String? activated;
      Widget grid(List<String> keys) => MaterialApp(
        home: Scaffold(
          body: RemoteGrid(
            itemKeys: keys,
            columns: 4,
            itemExtent: 80,
            itemBuilder: (_, index, node, onFocus) => RemoteTarget(
              key: ValueKey('tile-${keys[index]}'),
              child: Text(keys[index]),
              focusNode: node,
              onFocus: onFocus,
              onPressed: () => activated = keys[index],
            ),
          ),
        ),
      );
      await tester.pumpWidget(grid(initial));
      await tester.pumpAndSettle();
      final updated = _ObservedKeys(initial.reversed.toList());
      await tester.pumpWidget(grid(updated));
      await tester.pumpAndSettle();
      expect(updated.reads, lessThan(updated.length * 3));
      await tester.tap(find.byKey(const ValueKey('tile-key-1199')));
      expect(activated, 'key-1199');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
