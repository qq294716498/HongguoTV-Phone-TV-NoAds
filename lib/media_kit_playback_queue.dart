import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'playback_queue_contract.dart';

enum MediaKitQueueNativeEventKind { started, loaded, failed, shutdown }

class MediaKitQueueNativeEvent {
  const MediaKitQueueNativeEvent(this.kind, this.entryId);
  final MediaKitQueueNativeEventKind kind;
  final int entryId;
}

class MediaKitQueueItem {
  const MediaKitQueueItem(this.entryId, this.uri, {this.current = false});
  final int entryId;
  final String uri;
  final bool current;
}

abstract class MediaKitQueueTransport {
  bool get supported;
  Stream<MediaKitQueueNativeEvent> get events;
  Future<bool> initialize();
  Future<String> read(String property);
  Future<void> write(String property, String value);
  Future<List<MediaKitQueueItem>> items();
  Future<void> append(Media media);
  Future<void> select(int entryId, {required bool play});
  Future<void> keepCurrent();
  Future<void> dispose();
}

class NativeMediaKitQueueTransport implements MediaKitQueueTransport {
  NativeMediaKitQueueTransport(this.player)
    : _owner = player.platform is NativePlayer
          ? player.platform as NativePlayer
          : null;
  final Player player;
  final NativePlayer? _owner;
  final _events = StreamController<MediaKitQueueNativeEvent>.broadcast(
    sync: true,
  );
  Pointer<mpv.mpv_handle> _client = nullptr;
  NativeCallable<Void Function(Pointer<Void>)>? _wakeup;
  int _startedId = -1;
  bool _closed = false;

  NativePlayer? get _native => _owner;

  @override
  bool get supported =>
      !_closed &&
      _native != null &&
      identical(player.platform, _native) &&
      !_native!.disposed;

  @override
  Stream<MediaKitQueueNativeEvent> get events => _events.stream;

  void _available() {
    if (!supported || _native!.ctx == nullptr) {
      throw StateError('播放器队列不可用');
    }
  }

  @override
  Future<bool> initialize() async {
    if (!supported) return false;
    if (_client != nullptr) return true;
    final native = _native!;
    await native.waitForPlayerInitialization;
    await native.waitForVideoControllerInitializationIfAttached;
    _available();
    if (native.mpv.mpv_client_api_version() < 0x1006c) return false;
    try {
      _client = native.mpv.mpv_create_weak_client(native.ctx, nullptr);
      if (_client == nullptr) return false;
      for (var id = 1; id < 64; id++) {
        native.mpv.mpv_request_event(
          _client,
          id,
          {
                mpv.mpv_event_id.MPV_EVENT_SHUTDOWN,
                mpv.mpv_event_id.MPV_EVENT_START_FILE,
                mpv.mpv_event_id.MPV_EVENT_END_FILE,
                mpv.mpv_event_id.MPV_EVENT_FILE_LOADED,
              }.contains(id)
              ? 1
              : 0,
        );
      }
      _wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener(
        _nativeWakeup,
      );
      native.mpv.mpv_set_wakeup_callback(
        _client,
        _wakeup!.nativeFunction,
        nullptr,
      );
      _drain();
      return true;
    } catch (_) {
      _destroyClient();
      return false;
    }
  }

  void _nativeWakeup(Pointer<Void> _) {
    if (!_closed && _client != nullptr) _drain();
  }

  void _drain() {
    final native = _native;
    if (_closed || native == null || _client == nullptr) return;
    for (var count = 0; count < 1024 && _client != nullptr; count++) {
      final event = native.mpv.mpv_wait_event(_client, 0).ref;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) return;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_SHUTDOWN) {
        _events.add(
          const MediaKitQueueNativeEvent(
            MediaKitQueueNativeEventKind.shutdown,
            -1,
          ),
        );
        _destroyClient();
        return;
      }
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_START_FILE &&
          event.data != nullptr) {
        _startedId = event.data
            .cast<mpv.mpv_event_start_file>()
            .ref
            .playlist_entry_id;
        _events.add(
          MediaKitQueueNativeEvent(
            MediaKitQueueNativeEventKind.started,
            _startedId,
          ),
        );
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_FILE_LOADED) {
        _events.add(
          MediaKitQueueNativeEvent(
            MediaKitQueueNativeEventKind.loaded,
            _startedId,
          ),
        );
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_END_FILE &&
          event.data != nullptr) {
        final end = event.data.cast<mpv.mpv_event_end_file>().ref;
        if (end.reason == mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR) {
          _events.add(
            MediaKitQueueNativeEvent(
              MediaKitQueueNativeEventKind.failed,
              end.playlist_entry_id,
            ),
          );
        }
      }
    }
    if (_client != nullptr) scheduleMicrotask(_drain);
  }

  @override
  Future<String> read(String property) async {
    _available();
    return _native!.getProperty(property);
  }

  @override
  Future<void> write(String property, String value) async {
    _available();
    final name = property.toNativeUtf8();
    final data = value.toNativeUtf8();
    try {
      if (_native!.mpv.mpv_set_property_string(
            _native!.ctx,
            name.cast(),
            data.cast(),
          ) <
          0) {
        throw StateError('播放器不支持队列属性 $property');
      }
    } finally {
      calloc.free(name);
      calloc.free(data);
    }
  }

  @override
  Future<List<MediaKitQueueItem>> items() async {
    final count = int.tryParse(await read('playlist-count'));
    if (count == null || count < 0 || count > 2) throw StateError('播放器队列已变化');
    final current = int.tryParse(await read('playlist-playing-pos')) ?? -1;
    final result = <MediaKitQueueItem>[];
    for (var index = 0; index < count; index++) {
      final id = int.tryParse(await read('playlist/$index/id'));
      final uri = await read('playlist/$index/filename');
      if (id == null || uri.isEmpty) throw StateError('播放器队列资料不完整');
      result.add(
        MediaKitQueueItem(
          id,
          Media.normalizeURI(uri),
          current: current == index,
        ),
      );
    }
    return result;
  }

  @override
  Future<void> append(Media media) async {
    _available();
    await player.add(media);
  }

  @override
  Future<void> select(int entryId, {required bool play}) async {
    final queue = await items();
    final index = queue.indexWhere((item) => item.entryId == entryId);
    if (index < 0) throw StateError('下一集队列已失效');
    await write('pause', play ? 'no' : 'yes');
    if (!queue[index].current &&
        int.tryParse(await read('playlist-pos')) != index) {
      await write('playlist-pos', '$index');
    }
    if (!play) await player.pause();
  }

  @override
  Future<void> keepCurrent() => NativePlayer.lock.synchronized(() async {
    _available();
    final native = _native!;
    final previous = native.isPlaylistStateChangeAllowed;
    native.isPlaylistStateChangeAllowed = false;
    try {
      await native.command(['playlist-clear']);
      final queue = await items();
      if (queue.length > 1) {
        throw StateError('当前播放项已变化');
      }
      final retained = <Media>[];
      if (queue.isNotEmpty) {
        final item = queue.single;
        final media = native.current
            .where((value) => value.uri == item.uri)
            .firstOrNull;
        if (media == null) throw StateError('当前播放项已更换');
        retained.add(media);
      }
      native.current = retained;
      final playlist = Playlist(retained);
      native.state = native.state.copyWith(playlist: playlist);
      // ignore: invalid_use_of_protected_member
      native.playlistController.add(playlist);
    } finally {
      native.isPlaylistStateChangeAllowed = previous;
    }
  });

  void _destroyClient() {
    final client = _client;
    _client = nullptr;
    if (client != nullptr) {
      _native!.mpv.mpv_set_wakeup_callback(client, nullptr, nullptr);
      _native!.mpv.mpv_destroy(client);
    }
    _wakeup?.close();
    _wakeup = null;
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _destroyClient();
    await _events.close();
  }
}

class _QueuedMedia {
  _QueuedMedia(this.current, this.next, this.identity, this.generation);
  final PlaybackPlan current;
  final PlaybackPlan next;
  final String identity;
  final int generation;
  int? nativeId;
  bool attached = false, activated = false, ready = false, failed = false;
  bool retired = false;
  bool? requestedPlay;
  Timer? timeout;
}

class MediaKitPlaybackQueueDriver implements PlaybackQueueDriver {
  MediaKitPlaybackQueueDriver(
    Player player, {
    MediaKitQueueTransport? transport,
    this.activationTimeout = const Duration(seconds: 8),
    this.cleanupTimeout = const Duration(seconds: 2),
  }) : _transport = transport ?? NativeMediaKitQueueTransport(player) {
    _subscription = _transport.events.listen(_nativeEvent);
  }

  final MediaKitQueueTransport _transport;
  final Duration activationTimeout;
  final Duration cleanupTimeout;
  final _events = StreamController<PlaybackQueueEvent>.broadcast(sync: true);
  late final StreamSubscription<MediaKitQueueNativeEvent> _subscription;
  final _earlyEvents = <MediaKitQueueNativeEvent>[];
  Future<void> _tail = Future<void>.value();
  _QueuedMedia? _next, _active;
  bool _closed = false,
      _suspended = false,
      _attaching = false,
      _disposing = false;
  Future<void>? _disposal;
  bool? _capable;
  String? _originalPrefetch;
  int _intent = 0;
  String? _wanted;
  int _wantedGeneration = 0;

  @override
  Stream<PlaybackQueueEvent> get events => _events.stream;

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.catchError((Object _) {}).then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  bool _safe(PlaybackPlan plan, {required bool complete}) {
    if (plan.url.isEmpty ||
        plan.headers.isNotEmpty ||
        plan.decryptionKey.isNotEmpty) {
      return false;
    }
    if (complete && !plan.local && !plan.preloadComplete) return false;
    final uri = Uri.tryParse(plan.url);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return false;
    final file =
        uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost') ||
        plan.local &&
            (uri.scheme.isEmpty && plan.url.startsWith('/') ||
                RegExp(r'^[A-Za-z]:[\\/]').hasMatch(plan.url));
    final loopback =
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        const {
          '127.0.0.1',
          '::1',
          'localhost',
        }.contains(uri.host.toLowerCase());
    if (!file && !loopback) return false;
    final type = plan.mediaType.toLowerCase();
    return type == 'mp4' ||
        type == 'video/mp4' ||
        type.isEmpty && uri.path.toLowerCase().endsWith('.mp4');
  }

  bool _fileOnlyToNetwork(PlaybackPlan current, PlaybackPlan next) {
    final before = Uri.tryParse(current.url);
    final after = Uri.tryParse(next.url);
    final networkBefore = before?.scheme == 'http' || before?.scheme == 'https';
    final networkAfter = after?.scheme == 'http' || after?.scheme == 'https';
    return !networkBefore && networkAfter;
  }

  Future<bool> _prefetch() async {
    if (_capable == false || !_transport.supported) return false;
    if (!await _transport.initialize()) {
      _capable = false;
      return false;
    }
    final value = await _transport.read('options/prefetch-playlist');
    if (value != 'yes' && value != 'no') {
      _capable = false;
      return false;
    }
    _originalPrefetch ??= value;
    await _transport.write('prefetch-playlist', 'yes');
    return _capable =
        await _transport.read('options/prefetch-playlist') == 'yes';
  }

  Future<void> _restorePrefetch() async {
    if (_next?.attached == true && !_suspended) return;
    final original = _originalPrefetch;
    if (original != null && _transport.supported) {
      try {
        await _transport.write('prefetch-playlist', original);
      } catch (_) {}
    }
  }

  @override
  Future<bool> stage({
    required PlaybackPlan current,
    required PlaybackPlan next,
    required String identity,
    required int generation,
  }) {
    final ticket = _intent;
    _wanted = identity;
    _wantedGeneration = generation;
    return _run(() async {
      if (_closed ||
          _disposing ||
          ticket != _intent ||
          _wanted != identity ||
          _wantedGeneration != generation ||
          identity.isEmpty ||
          generation <= 0) {
        return false;
      }
      try {
        if (!_safe(current, complete: false) ||
            !_safe(next, complete: true) ||
            _fileOnlyToNetwork(current, next) ||
            Media.normalizeURI(current.url) == Media.normalizeURI(next.url)) {
          await _dropNext();
          await _restorePrefetch();
          return false;
        }
        if (_active != null && !_active!.ready && !_active!.failed) {
          return false;
        }
        final old = _next;
        if (old != null &&
            old.identity == identity &&
            old.generation == generation &&
            old.current.url == current.url &&
            old.next.url == next.url) {
          if (old.attached) return true;
          final result = !_suspended && await _attach(old, ticket);
          if (!result) await _restorePrefetch();
          return result;
        }
        await _dropNext();
        if (_active != null) {
          _active!.retired = true;
          _active!.timeout?.cancel();
          _active = null;
        }
        final entry = _QueuedMedia(current, next, identity, generation);
        _next = entry;
        if (_suspended) return false;
        final result = await _attach(entry, ticket);
        if (!result) await _restorePrefetch();
        return result;
      } catch (_) {
        if (ticket == _intent &&
            _wanted == identity &&
            _wantedGeneration == generation) {
          try {
            await _dropNext();
          } catch (_) {}
        }
        await _restorePrefetch();
        return false;
      }
    });
  }

  Future<void> _dropNext() async {
    final entry = _next;
    _next = null;
    entry?.retired = true;
    entry?.timeout?.cancel();
    if (entry?.attached == true) await _transport.keepCurrent();
  }

  bool _desired(_QueuedMedia entry, int ticket) =>
      !_closed &&
      !_disposing &&
      !_suspended &&
      ticket == _intent &&
      !entry.retired &&
      identical(_next, entry) &&
      _wanted == entry.identity &&
      _wantedGeneration == entry.generation;

  Future<bool> _attach(_QueuedMedia entry, int ticket) async {
    if (!_desired(entry, ticket) || !await _prefetch()) return false;
    if (!_desired(entry, ticket)) return false;
    final before = await _transport.items();
    if (!_desired(entry, ticket)) return false;
    if (before.length != 1 ||
        !before.single.current ||
        before.single.uri != Media.normalizeURI(entry.current.url)) {
      return false;
    }
    _attaching = true;
    try {
      entry.attached = true;
      await _transport.append(Media(entry.next.url, httpHeaders: const {}));
      final after = await _transport.items();
      final next = after
          .where((item) => item.uri == Media.normalizeURI(entry.next.url))
          .firstOrNull;
      if (after.length != 2 || next == null) throw StateError('下一集未加入原生队列');
      entry.nativeId = next.entryId;
      if (!_desired(entry, ticket)) {
        await _transport.keepCurrent();
        entry.attached = false;
        return false;
      }
      return true;
    } finally {
      _attaching = false;
      Timer.run(() {
        final events = List<MediaKitQueueNativeEvent>.of(_earlyEvents);
        _earlyEvents.clear();
        for (final event in events) {
          _nativeEvent(event);
        }
      });
    }
  }

  void _emit(
    _QueuedMedia entry,
    PlaybackQueueEventKind kind, {
    String message = '',
  }) {
    if (_closed || _disposing || entry.retired || _events.isClosed) return;
    _events.add(
      PlaybackQueueEvent(
        identity: entry.identity,
        generation: entry.generation,
        kind: kind,
        message: message,
      ),
    );
  }

  void _activate(_QueuedMedia entry) {
    if (entry.retired || entry.activated) return;
    entry.activated = true;
    if (identical(_next, entry)) _next = null;
    _active = entry;
    _watchReady(entry);
    _emit(entry, PlaybackQueueEventKind.activated);
  }

  void _watchReady(_QueuedMedia entry) {
    entry.timeout?.cancel();
    entry.timeout = Timer(activationTimeout, () {
      if (!entry.retired && !entry.ready && !entry.failed) {
        entry.failed = true;
        _emit(entry, PlaybackQueueEventKind.failed, message: '下一集队列等待超时');
      }
    });
  }

  void _nativeEvent(MediaKitQueueNativeEvent event) {
    if (_closed || _disposing) return;
    if (_attaching) {
      if (_earlyEvents.length < 128) _earlyEvents.add(event);
      return;
    }
    final entry = [_next, _active]
        .whereType<_QueuedMedia>()
        .where((item) => item.nativeId == event.entryId && !item.retired)
        .firstOrNull;
    if (event.kind == MediaKitQueueNativeEventKind.shutdown) {
      if (_next != null) {
        _emit(_next!, PlaybackQueueEventKind.failed, message: '播放器队列已关闭');
      }
      if (_active != null) {
        _emit(_active!, PlaybackQueueEventKind.failed, message: '播放器队列已关闭');
      }
      return;
    }
    if (entry == null || entry.failed) return;
    if (event.kind == MediaKitQueueNativeEventKind.started) {
      _activate(entry);
    } else if (event.kind == MediaKitQueueNativeEventKind.loaded) {
      _activate(entry);
      if (entry.ready) return;
      entry.ready = true;
      entry.timeout?.cancel();
      unawaited(
        _run(() async {
          if (_closed || entry.retired) return;
          await _transport.keepCurrent();
          if (entry.requestedPlay == false) {
            await _transport.select(entry.nativeId!, play: false);
          }
          await _restorePrefetch();
        }).catchError((Object _) {}),
      );
      _emit(entry, PlaybackQueueEventKind.ready);
    } else if (event.kind == MediaKitQueueNativeEventKind.failed) {
      entry.failed = true;
      entry.timeout?.cancel();
      _emit(entry, PlaybackQueueEventKind.failed, message: '下一集原生媒体加载失败');
    }
  }

  @override
  Future<bool> advance({required String identity, required bool play}) =>
      _run(() async {
        if (_closed || _disposing) return false;
        final active = _active;
        if (active != null &&
            active.identity == identity &&
            !active.retired &&
            !active.failed) {
          active.requestedPlay = play;
          await _transport.select(active.nativeId!, play: play);
          return true;
        }
        final entry = _next;
        if (entry == null ||
            entry.identity != identity ||
            entry.retired ||
            entry.failed) {
          return false;
        }
        _suspended = false;
        if (!entry.attached && !await _attach(entry, _intent)) return false;
        entry.requestedPlay = play;
        _watchReady(entry);
        try {
          await _transport.select(entry.nativeId!, play: play);
          return true;
        } catch (_) {
          entry.failed = true;
          _emit(entry, PlaybackQueueEventKind.failed, message: '下一集队列跳转失败');
          return false;
        }
      });

  @override
  Future<void> suspend(bool paused) {
    _suspended = paused;
    final ticket = ++_intent;
    return _run(() async {
      if (_closed || ticket != _intent) return;
      final entry = _next;
      if (entry == null || entry.retired) return;
      if (paused) {
        await _transport.keepCurrent();
        final remaining = await _transport.items();
        final selected =
            remaining.length == 1 && remaining.single.entryId == entry.nativeId;
        if (selected) {
          _activate(entry);
        } else if (!entry.activated) {
          entry.attached = false;
          entry.nativeId = null;
          entry.timeout?.cancel();
        }
        await _restorePrefetch();
      } else {
        var attached = false;
        try {
          attached = await _attach(entry, ticket);
        } catch (_) {
          if (identical(_next, entry) && !entry.retired) {
            _emit(entry, PlaybackQueueEventKind.failed, message: '下一集队列恢复失败');
            try {
              await _dropNext();
            } catch (_) {}
          }
        }
        if (!attached) await _restorePrefetch();
      }
    });
  }

  @override
  Future<void> clear({String? identity}) {
    if (identity != null &&
        _next?.identity != identity &&
        _wanted != identity) {
      return Future<void>.value();
    }
    ++_intent;
    _wanted = null;
    final entry = _next;
    final active = _active;
    _next = null;
    entry?.retired = true;
    entry?.timeout?.cancel();
    if (identity == null) {
      _active?.retired = true;
      _active?.timeout?.cancel();
      _active = null;
    }
    return _run(() async {
      if (_closed) return;
      if (entry?.attached == true ||
          identity == null && active?.nativeId != null) {
        await _transport.keepCurrent();
      }
      await _restorePrefetch();
    });
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_closed) return;
    _disposing = true;
    try {
      await clear().timeout(cleanupTimeout);
    } catch (_) {
    } finally {
      _closed = true;
      ++_intent;
      await _subscription.cancel();
      await _transport.dispose();
      await _events.close();
    }
  }
}
