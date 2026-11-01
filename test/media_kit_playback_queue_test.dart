import 'dart:async';

import 'package:duanju_app/media_kit_playback_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_queue_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';

class QueueTransportFixture implements MediaKitQueueTransport {
  final controller = StreamController<MediaKitQueueNativeEvent>.broadcast(
    sync: true,
  );
  List<MediaKitQueueItem> queue = [
    const MediaKitQueueItem(1, '/old.mp4', current: true),
  ];
  final added = <Media>[];
  final selected = <(int, bool)>[];
  final properties = <(String, String)>[];
  String prefetch = 'no';
  bool optionSupported = true;
  bool ignorePrefetchWrite = false;
  bool rejectAppend = false;
  bool closed = false;
  int keepCalls = 0;
  int _nextId = 2;
  Completer<void>? initializeHold;
  Completer<void>? appendHold;
  Completer<void>? appendStarted;
  Completer<void>? keepHold;
  void Function()? beforeKeep;
  void Function()? afterKeep;

  @override
  bool get supported => !closed;
  @override
  Stream<MediaKitQueueNativeEvent> get events => controller.stream;
  @override
  Future<bool> initialize() async {
    await initializeHold?.future;
    return !closed;
  }

  @override
  Future<String> read(String property) async => optionSupported ? prefetch : '';
  @override
  Future<void> write(String property, String value) async {
    properties.add((property, value));
    if (!ignorePrefetchWrite) prefetch = value;
  }

  @override
  Future<List<MediaKitQueueItem>> items() async => List.of(queue);
  @override
  Future<void> append(Media media) async {
    appendStarted?.complete();
    await appendHold?.future;
    added.add(media);
    if (!rejectAppend) queue.add(MediaKitQueueItem(_nextId++, media.uri));
  }

  @override
  Future<void> select(int entryId, {required bool play}) async {
    if (!queue.any((item) => item.entryId == entryId)) {
      throw StateError('missing');
    }
    selected.add((entryId, play));
  }

  void start(int id) {
    queue = [
      for (final item in queue)
        MediaKitQueueItem(item.entryId, item.uri, current: item.entryId == id),
    ];
    controller.add(
      MediaKitQueueNativeEvent(MediaKitQueueNativeEventKind.started, id),
    );
  }

  void loaded(int id) => controller.add(
    MediaKitQueueNativeEvent(MediaKitQueueNativeEventKind.loaded, id),
  );
  void failed(int id) => controller.add(
    MediaKitQueueNativeEvent(MediaKitQueueNativeEventKind.failed, id),
  );
  @override
  Future<void> keepCurrent() async {
    keepCalls++;
    await keepHold?.future;
    beforeKeep?.call();
    beforeKeep = null;
    queue = queue.where((item) => item.current).toList();
    afterKeep?.call();
    afterKeep = null;
  }

  @override
  Future<void> dispose() async {
    closed = true;
    await controller.close();
  }
}

void main() {
  const current = PlaybackPlan(
    url: 'file:///old.mp4',
    local: true,
    mediaType: 'mp4',
  );
  const next = PlaybackPlan(
    url: 'file:///next.mp4',
    local: true,
    mediaType: 'mp4',
    session: 'next',
  );

  Future<void> settle() async {
    for (var index = 0; index < 8; index++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  (
    MediaKitPlaybackQueueDriver,
    QueueTransportFixture,
    ScriptedPlayer,
    List<PlaybackQueueEvent>,
  )
  create({
    Duration timeout = const Duration(seconds: 8),
    Duration cleanupTimeout = const Duration(seconds: 2),
  }) {
    final transport = QueueTransportFixture();
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    final driver = MediaKitPlaybackQueueDriver(
      player,
      transport: transport,
      activationTimeout: timeout,
      cleanupTimeout: cleanupTimeout,
    );
    final events = <PlaybackQueueEvent>[];
    driver.events.listen(events.add);
    addTearDown(() async {
      await driver.dispose();
      await platform.dispose();
    });
    return (driver, transport, platform, events);
  }

  Future<bool> stage(
    MediaKitPlaybackQueueDriver driver, {
    PlaybackPlan before = current,
    PlaybackPlan after = next,
    String identity = 'next',
    int generation = 1,
  }) => driver.stage(
    current: before,
    next: after,
    identity: identity,
    generation: generation,
  );

  test(
    'append does not announce activation or ready and never opens another player',
    () async {
      final (driver, transport, platform, events) = create();
      expect(await stage(driver), isTrue);
      expect(transport.added.single.httpHeaders, isEmpty);
      expect(transport.queue, hasLength(2));
      expect(events, isEmpty);
      expect(platform.opened, isEmpty);
      expect(platform.disposed, isFalse);
      transport.start(2);
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
      ]);
      transport.loaded(2);
      await settle();
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
      ]);
      expect(
        events.every(
          (event) =>
              event.identity == 'next' &&
              event.generation == 1 &&
              !event.firstFrame,
        ),
        isTrue,
      );
      expect(transport.queue.single.entryId, 2);
      expect(transport.prefetch, 'no');
    },
  );

  test('duplicate prepared notifications append once', () async {
    final (driver, transport, _, events) = create();
    expect(await stage(driver), isTrue);
    expect(await stage(driver), isTrue);
    expect(transport.added, hasLength(1));
    transport.start(2);
    transport.start(2);
    transport.loaded(2);
    transport.loaded(2);
    await settle();
    expect(events, hasLength(2));
  });

  test(
    'four consecutive items wait for native activation and ignore retired events',
    () async {
      final (driver, transport, platform, events) = create();
      const plans = [
        current,
        PlaybackPlan(
          url: 'file:///episode-b.mp4',
          local: true,
          mediaType: 'mp4',
        ),
        PlaybackPlan(
          url: 'file:///episode-c.mp4',
          local: true,
          mediaType: 'mp4',
        ),
        PlaybackPlan(
          url: 'file:///episode-d.mp4',
          local: true,
          mediaType: 'mp4',
        ),
      ];
      final retiredIds = <int>[];
      for (var generation = 1; generation < plans.length; generation++) {
        final currentId = transport.queue.single.entryId;
        final beforeEvents = events.length;
        expect(
          await stage(
            driver,
            before: plans[generation - 1],
            after: plans[generation],
            identity: 'episode-${generation + 1}',
            generation: generation,
          ),
          isTrue,
        );
        final nextId = transport.queue.last.entryId;
        expect(transport.queue, hasLength(2));
        expect(
          transport.queue.singleWhere((item) => item.current).entryId,
          currentId,
        );
        expect(events, hasLength(beforeEvents));
        expect(transport.selected, isEmpty);
        expect(platform.opened, isEmpty);
        for (final id in {...retiredIds, currentId}) {
          transport.controller.add(
            MediaKitQueueNativeEvent(MediaKitQueueNativeEventKind.started, id),
          );
          transport.loaded(id);
          transport.failed(id);
        }
        await settle();
        expect(events, hasLength(beforeEvents));
        expect(
          transport.queue.singleWhere((item) => item.current).entryId,
          currentId,
        );

        transport.start(nextId);
        expect(events, hasLength(beforeEvents + 1));
        expect(events.last.kind, PlaybackQueueEventKind.activated);
        expect(events.last.identity, 'episode-${generation + 1}');
        expect(events.last.generation, generation);
        transport.loaded(nextId);
        transport.loaded(nextId);
        await settle();
        expect(events, hasLength(beforeEvents + 2));
        expect(events.last.kind, PlaybackQueueEventKind.ready);
        expect(events.last.identity, 'episode-${generation + 1}');
        expect(events.last.generation, generation);
        expect(transport.queue.single.entryId, nextId);
        expect(
          transport.queue.single.uri,
          Media.normalizeURI(plans[generation].url),
        );
        expect(transport.selected, isEmpty);
        expect(platform.opened, isEmpty);
        retiredIds.add(currentId);
      }
      final completedEvents = List<PlaybackQueueEvent>.of(events);
      for (final id in retiredIds) {
        transport.loaded(id);
        transport.failed(id);
      }
      await settle();
      expect(events, completedEvents);
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
      ]);
      expect(transport.added, hasLength(3));
      expect(platform.opened, isEmpty);
      expect(platform.disposed, isFalse);
    },
  );

  test(
    'native loaded event is required even after advance command succeeds',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      expect(await driver.advance(identity: 'next', play: true), isTrue);
      expect(events, isEmpty);
      transport.start(2);
      await settle();
      expect(events.single.kind, PlaybackQueueEventKind.activated);
      transport.loaded(2);
      await settle();
      expect(events.last.kind, PlaybackQueueEventKind.ready);
    },
  );

  test(
    'paused advance remains paused and repeated advance does not select another item',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      expect(await driver.advance(identity: 'next', play: false), isTrue);
      expect(transport.selected.single, (2, false));
      transport.start(2);
      transport.loaded(2);
      await settle();
      expect(await driver.advance(identity: 'next', play: false), isTrue);
      expect(
        transport.selected.every((selection) => selection == (2, false)),
        isTrue,
      );
      expect(transport.queue.single.entryId, 2);
      expect(events, hasLength(2));
    },
  );

  test('suspend removes only candidate and resumes the same media', () async {
    final (driver, transport, _, events) = create();
    await stage(driver);
    await driver.suspend(true);
    expect(transport.queue.single.entryId, 1);
    expect(transport.prefetch, 'no');
    transport.start(2);
    expect(events, isEmpty);
    transport.queue = [const MediaKitQueueItem(1, '/old.mp4', current: true)];
    await driver.suspend(false);
    expect(transport.added.map((media) => media.uri), [
      '/next.mp4',
      '/next.mp4',
    ]);
    expect(transport.queue, hasLength(2));
    transport.start(3);
    transport.loaded(3);
    await settle();
    expect(events.map((event) => event.kind), [
      PlaybackQueueEventKind.activated,
      PlaybackQueueEventKind.ready,
    ]);
  });

  test(
    'failed resume removes optimistic candidate and restores original prefetch',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      await driver.suspend(true);
      transport.rejectAppend = true;
      await driver.suspend(false);
      expect(transport.queue.single.entryId, 1);
      expect(transport.prefetch, 'no');
      expect(events.single.kind, PlaybackQueueEventKind.failed);
      expect(await driver.advance(identity: 'next', play: true), isFalse);
      transport.rejectAppend = false;
      expect(await stage(driver), isTrue);
      expect(transport.queue, hasLength(2));
    },
  );

  test(
    'EOF racing suspension keeps newly active current and its ready event',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      transport.beforeKeep = () => transport.start(2);
      await driver.suspend(true);
      expect(transport.queue.single.entryId, 2);
      transport.loaded(2);
      await settle();
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
      ]);
      expect(transport.queue.single.entryId, 2);
    },
  );

  test(
    'suspension recognizes selected native item before delayed start callback',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      transport.beforeKeep = () {
        transport.queue = [
          const MediaKitQueueItem(1, '/old.mp4'),
          const MediaKitQueueItem(2, '/next.mp4', current: true),
        ];
      };
      transport.afterKeep = () {
        transport.queue = [const MediaKitQueueItem(2, '/next.mp4')];
      };
      await driver.suspend(true);
      expect(events.single.kind, PlaybackQueueEventKind.activated);
      expect(events.single.identity, 'next');
      transport.start(2);
      transport.loaded(2);
      await settle();
      expect(events.map((event) => event.kind), [
        PlaybackQueueEventKind.activated,
        PlaybackQueueEventKind.ready,
      ]);
      expect(transport.queue.single.entryId, 2);
    },
  );

  test(
    'identity clear cannot remove current after activation and ready remains observable',
    () async {
      final (driver, transport, _, events) = create();
      await stage(driver);
      transport.start(2);
      await driver.clear(identity: 'next');
      expect(
        transport.queue.any((item) => item.current && item.entryId == 2),
        isTrue,
      );
      transport.loaded(2);
      await settle();
      expect(events.last.kind, PlaybackQueueEventKind.ready);
      expect(transport.queue.single.entryId, 2);
    },
  );

  test('clear invalidates a stage still awaiting initialization', () async {
    final (driver, transport, _, events) = create();
    transport.initializeHold = Completer<void>();
    final prepared = stage(driver);
    await settle();
    final cleared = driver.clear(identity: 'next');
    transport.initializeHold!.complete();
    expect(await prepared, isFalse);
    await cleared;
    expect(transport.added, isEmpty);
    expect(transport.prefetch, 'no');
    transport.start(2);
    expect(events, isEmpty);
  });

  test('clear racing append never emits stale item events', () async {
    final (driver, transport, _, events) = create();
    transport.appendHold = Completer<void>();
    transport.appendStarted = Completer<void>();
    final prepared = stage(driver);
    await transport.appendStarted!.future;
    final cleared = driver.clear();
    transport.appendHold!.complete();
    expect(await prepared, isFalse);
    await cleared;
    transport.start(2);
    transport.loaded(2);
    await settle();
    expect(events, isEmpty);
    expect(transport.queue.where((item) => item.uri == '/next.mp4'), isEmpty);
  });

  test('new generation rejects old queued native events', () async {
    final (driver, transport, _, events) = create();
    await stage(driver);
    expect(
      await stage(
        driver,
        after: const PlaybackPlan(
          url: 'file:///other.mp4',
          local: true,
          mediaType: 'mp4',
        ),
        identity: 'other',
        generation: 2,
      ),
      isTrue,
    );
    transport.controller.add(
      const MediaKitQueueNativeEvent(MediaKitQueueNativeEventKind.started, 2),
    );
    transport.loaded(2);
    expect(events, isEmpty);
    transport.start(3);
    transport.loaded(3);
    await settle();
    expect(
      events.every(
        (event) => event.identity == 'other' && event.generation == 2,
      ),
      isTrue,
    );
  });

  test('source load failure is identified and does not become ready', () async {
    final (driver, transport, _, events) = create();
    await stage(driver);
    transport.start(2);
    transport.failed(2);
    transport.loaded(2);
    await settle();
    expect(events.map((event) => event.kind), [
      PlaybackQueueEventKind.activated,
      PlaybackQueueEventKind.failed,
    ]);
    expect(await driver.advance(identity: 'next', play: true), isFalse);
    transport.queue = [];
    await driver.clear();
    transport.loaded(2);
    expect(transport.queue, isEmpty);
    expect(transport.prefetch, 'no');
    expect(events.last.kind, PlaybackQueueEventKind.failed);
  });

  test('selected item that never loads has a bounded failure', () async {
    final (driver, transport, _, events) = create(
      timeout: const Duration(milliseconds: 20),
    );
    await stage(driver);
    transport.start(2);
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(events.last.kind, PlaybackQueueEventKind.failed);
    expect(events.last.message, contains('超时'));
  });

  test(
    'unsupported prefetch option and ignored setting fall back without appending',
    () async {
      for (final unsupported in [true, false]) {
        final (driver, transport, _, events) = create();
        transport.optionSupported = !unsupported;
        transport.ignorePrefetchWrite = !unsupported;
        expect(await stage(driver), isFalse);
        expect(transport.added, isEmpty);
        expect(events, isEmpty);
        expect(transport.prefetch, 'no');
      }
    },
  );

  test(
    'native append verification rejects a command that silently does nothing',
    () async {
      final (driver, transport, _, events) = create();
      transport.rejectAppend = true;
      expect(await stage(driver), isFalse);
      expect(transport.queue.single.entryId, 1);
      expect(transport.prefetch, 'no');
      expect(events, isEmpty);
    },
  );

  test(
    'only complete local or loopback unencrypted MP4 without per-item headers is eligible',
    () async {
      final (driver, transport, _, _) = create();
      for (final plan in [
        const PlaybackPlan(
          url: 'https://media.example/next.mp4',
          preloadComplete: true,
          mediaType: 'mp4',
        ),
        const PlaybackPlan(
          url: 'http://127.0.0.1:9000/next',
          startupReady: true,
          mediaType: 'mp4',
        ),
        const PlaybackPlan(
          url: 'file:///next.mp4',
          local: true,
          mediaType: 'hls',
        ),
        const PlaybackPlan(
          url: 'file:///next.mp4',
          local: true,
          mediaType: 'mp4',
          decryptionKey: 'synthetic',
        ),
        const PlaybackPlan(
          url: 'file:///next.mp4',
          local: true,
          mediaType: 'mp4',
          headers: {'Referer': 'synthetic'},
        ),
        const PlaybackPlan(
          url: 'file://remote/share/next.mp4',
          local: true,
          mediaType: 'mp4',
        ),
        const PlaybackPlan(
          url: 'file:///old.mp4',
          local: true,
          mediaType: 'mp4',
        ),
      ]) {
        expect(await stage(driver, after: plan), isFalse);
      }
      expect(transport.added, isEmpty);
      expect(await stage(driver), isTrue);
    },
  );

  test(
    'file-only current does not queue a network next under different protocol policy',
    () async {
      final (driver, transport, _, _) = create();
      expect(
        await stage(
          driver,
          after: const PlaybackPlan(
            url: 'http://127.0.0.1:9000/next',
            preloadComplete: true,
            mediaType: 'mp4',
          ),
        ),
        isFalse,
      );
      expect(transport.added, isEmpty);
    },
  );

  test('unsupported replacement removes the previous queued item', () async {
    final (driver, transport, _, events) = create();
    expect(await stage(driver), isTrue);
    expect(
      await stage(
        driver,
        after: const PlaybackPlan(
          url: 'https://media.example/replacement.mp4',
          preloadComplete: true,
          mediaType: 'mp4',
        ),
        identity: 'replacement',
        generation: 2,
      ),
      isFalse,
    );
    expect(transport.queue.single.entryId, 1);
    transport.loaded(2);
    expect(events, isEmpty);
    expect(transport.prefetch, 'no');
    expect(await driver.advance(identity: 'next', play: true), isFalse);
  });

  test('loopback fully cached next works without native local flag', () async {
    final (driver, transport, _, _) = create();
    transport.queue = [
      const MediaKitQueueItem(1, 'http://127.0.0.1:9000/old', current: true),
    ];
    expect(
      await stage(
        driver,
        before: const PlaybackPlan(
          url: 'http://127.0.0.1:9000/old',
          mediaType: 'mp4',
        ),
        after: const PlaybackPlan(
          url: 'http://127.0.0.1:9000/next',
          preloadComplete: true,
          mediaType: 'mp4',
        ),
      ),
      isTrue,
    );
    expect(transport.queue, hasLength(2));
  });

  test(
    'dispose during pending stage closes listener without disposing owning player',
    () async {
      final (driver, transport, platform, events) = create();
      transport.initializeHold = Completer<void>();
      final prepared = stage(driver);
      await settle();
      final closed = driver.dispose();
      transport.initializeHold!.complete();
      expect(await prepared, isFalse);
      await closed;
      expect(transport.closed, isTrue);
      expect(platform.disposed, isFalse);
      expect(await stage(driver), isFalse);
      expect(events, isEmpty);
    },
  );

  test('blocked native cleanup cannot retain the event client', () async {
    final (driver, transport, platform, events) = create(
      cleanupTimeout: const Duration(milliseconds: 20),
    );
    await stage(driver);
    transport.keepHold = Completer<void>();
    await driver.dispose().timeout(const Duration(milliseconds: 200));
    expect(transport.closed, isTrue);
    expect(platform.disposed, isFalse);
    expect(events, isEmpty);
    transport.keepHold!.complete();
    await settle();
  });
}
