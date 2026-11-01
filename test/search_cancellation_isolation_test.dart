import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'season_lookup_session_test.dart' show SessionTransport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'suggestion cancellation leaves catalog, season and prefetch active',
    () async {
      final transport = SessionTransport();
      final repository = NativeRepository.test(transport: transport.call);
      final season = repository.seasonLookup();
      final ordinary = repository.catalog('hongguo', query: '合成搜索');
      final related = season.catalog('hongguo', query: '合成第二季');
      final prefetch = repository.preload(
        const Drama(id: 'hongguo:123', source: 'hongguo', title: '合成'),
        Episode({'id': '1', 'currentEpisode': 1}, 1),
      );
      final suggestions = repository.suggestions('合成');
      await transport.waitFor(4);
      await repository.cancelSuggestions();
      expect(transport.cancelled, hasLength(1));
      expect(transport.cancelled.single['session'], transport.reads[3].session);
      expect(
        transport.cancelled.single['sequence'],
        transport.reads[3].sequence,
      );
      transport.reads[0].complete({'items': []});
      transport.reads[1].complete({'items': []});
      transport.reads[2].complete({
        'url': 'file:///synthetic-next.mp4',
        'session': 'next-cache',
      });
      transport.reads[3].complete({
        'items': ['合成结果'],
      });
      await ordinary;
      await related;
      expect((await prefetch)?.session, 'next-cache');
      expect(await suggestions, ['合成结果']);
      await season.dispose();
      expect(transport.cancelled, hasLength(1));
    },
  );

  test(
    'leaving catalog and cancelling a season do not cancel suggestions',
    () async {
      final transport = SessionTransport();
      final repository = NativeRepository.test(transport: transport.call);
      final season = repository.seasonLookup();
      final suggestions = repository.suggestions('新输入');
      final ordinary = repository.catalog('hongguo');
      final related = season.catalog('hongguo', query: '合成第二季');
      final relatedResult = expectLater(related, throwsA(isA<AppFailure>()));
      await transport.waitFor(3);
      await repository.cancelCatalog();
      await season.cancelPending();
      expect(transport.cancelled, hasLength(2));
      expect(transport.cancelled.map((input) => input['session']), [
        transport.reads[1].session,
        transport.reads[2].session,
      ]);
      transport.reads[0].complete({
        'items': ['新输入结果'],
      });
      transport.reads[1].complete({'items': []});
      transport.reads[2].complete({'items': []});
      expect(await suggestions, ['新输入结果']);
      await ordinary;
      await relatedResult;
      await season.dispose();
    },
  );

  test(
    'delayed cancellation carries the old sequence rather than a new query',
    () async {
      final transport = SessionTransport();
      final cancelAcknowledged = Completer<Map<String, dynamic>>();
      final repository = NativeRepository.test(
        transport: (input) {
          if (input['action'] == 'cancelRead') {
            transport.cancelled.add(Map.of(input));
            return cancelAcknowledged.future;
          }
          return transport.call(input);
        },
      );
      final old = repository.suggestions('旧输入');
      await transport.waitFor(1);
      final cancellation = repository.cancelSuggestions();
      final latest = repository.suggestions('新输入');
      await transport.waitFor(2);
      expect(transport.cancelled, hasLength(1));
      expect(transport.reads[0].session, transport.reads[1].session);
      expect(
        transport.cancelled.single['sequence'],
        transport.reads[0].sequence,
      );
      expect(
        transport.cancelled.single['sequence'],
        isNot(transport.reads[1].sequence),
      );
      cancelAcknowledged.complete({'ok': true, 'data': true});
      await cancellation;
      transport.reads[0].complete({
        'items': ['旧结果'],
      });
      transport.reads[1].complete({
        'items': ['新结果'],
      });
      await old;
      expect(await latest, ['新结果']);
      await repository.cancelSuggestions();
      expect(transport.cancelled, hasLength(1));
    },
  );
}
