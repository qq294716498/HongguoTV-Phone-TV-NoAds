package io.flutter.plugins.videoplayer;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.MediaSource;
import io.flutter.plugin.common.EventChannel;
import java.util.HashMap;
import java.util.Map;

@UnstableApi
final class PlaybackQueue implements Player.Listener, AnalyticsListener {
  private static final long READY_TIMEOUT_MS = 8000;
  final ExoPlayer player;
  private final PreparedNext prepared;
  private final Runnable onActivated;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private EventChannel.EventSink events;
  private Entry next;
  private Entry current;
  private long revision;
  private boolean suspended;
  private boolean disposed;
  private boolean listening;
  private Map<String, Object> lastEvent = new HashMap<>();

  private final class Entry {
    final PreparedMediaRequest request;
    final MediaItem item;
    final long generation;
    final PreparedNext.Selection selection;
    final Runnable timeout = () -> fail(this, "queue_ready_timeout");
    final long stagedAt = SystemClock.elapsedRealtime();
    long activatedAt;
    boolean ready;
    boolean firstFrame;
    boolean failed;

    Entry(PreparedMediaRequest request, MediaSource source, long generation,
        PreparedNext.Selection selection) {
      this.request = request;
      item = source.getMediaItem();
      this.generation = generation;
      this.selection = selection;
    }

    void release() {
      handler.removeCallbacks(timeout);
      if (selection != null) selection.release();
    }
  }

  PlaybackQueue(ExoPlayer player, PreparedNext prepared, Runnable onActivated) {
    this.player = player;
    this.prepared = prepared;
    this.onActivated = onActivated;
  }

  void listen(EventChannel.EventSink sink) {
    events = sink;
    if (!lastEvent.isEmpty()) sink.success(new HashMap<>(lastEvent));
  }

  void stopListening() {
    events = null;
  }

  boolean stage(PreparedMediaRequest request, MediaSource source, long generation,
      long commandRevision, PreparedNext.Selection selection) {
    if (disposed || suspended || generation <= 0 || commandRevision < revision
        || player.getMediaItemCount() == 0 || player.getPlaybackState() == Player.STATE_IDLE
        || player.getPlaybackState() == Player.STATE_ENDED || player.getPlayerError() != null) {
      if (selection != null) selection.release();
      return false;
    }
    revision = commandRevision;
    if (current != null && current.request.equals(request)
        && current.generation == generation && matches(current)) {
      if (selection != null) selection.release();
      return true;
    }
    if (next != null && next.request.equals(request) && next.generation == generation) {
      if (selection != null) selection.release();
      return true;
    }
    if (!listening) {
      listening = true;
      player.addListener(this);
      player.addAnalyticsListener(this);
    }
    clearCandidate(null);
    trimAroundCurrent();
    Entry entry = new Entry(request, source, generation, selection);
    next = entry;
    try {
      player.addMediaSource(source);
      return true;
    } catch (RuntimeException error) {
      if (next == entry) next = null;
      entry.release();
      return false;
    }
  }

  void invalidate() {
    Entry pending = next;
    next = null;
    if (pending != null) pending.release();
    if (current != null) current.release();
    current = null;
    lastEvent.clear();
    stop();
  }

  private void trimAroundCurrent() {
    int index = player.getCurrentMediaItemIndex();
    if (index < 0 || index >= player.getMediaItemCount()) return;
    if (index + 1 < player.getMediaItemCount()) {
      player.removeMediaItems(index + 1, player.getMediaItemCount());
    }
    if (index > 0) player.removeMediaItems(0, index);
  }

  boolean advance(String identity, boolean play) {
    if (disposed || suspended) return false;
    if (current != null && current.request.identity.equals(identity) && matches(current)) {
      player.setPlayWhenReady(play);
      return true;
    }
    Entry entry = next;
    if (entry == null || !entry.request.identity.equals(identity)) return false;
    int index = indexOf(entry.item);
    if (index < 0) return false;
    player.setPlayWhenReady(play);
    player.seekToDefaultPosition(index);
    return true;
  }

  boolean clear(String identity, long commandRevision) {
    if (disposed || commandRevision < revision) return false;
    revision = commandRevision;
    return clearCandidate(identity);
  }

  private boolean clearCandidate(String identity) {
    Entry entry = next;
    if (entry == null || (identity != null && !entry.request.identity.equals(identity))) {
      return false;
    }
    if (matches(entry)) {
      activate(entry);
      return false;
    }
    next = null;
    int index = indexOf(entry.item);
    if (index >= 0) player.removeMediaItem(index);
    entry.release();
    return true;
  }

  void suspend(boolean paused, long commandRevision) {
    if (disposed || commandRevision < revision) return;
    revision = commandRevision;
    suspended = paused;
    if (paused) {
      clearCandidate(null);
      if (prepared != null) prepared.clear(null);
    }
  }

  private int indexOf(MediaItem item) {
    for (int i = 0; i < player.getMediaItemCount(); i++) {
      if (item.mediaId.equals(player.getMediaItemAt(i).mediaId)) return i;
    }
    return -1;
  }

  private boolean matches(Entry entry) {
    MediaItem selected = player.getCurrentMediaItem();
    return selected != null && entry.item.mediaId.equals(selected.mediaId);
  }

  @Override
  public void onMediaItemTransition(MediaItem item, int reason) {
    Entry entry = next;
    if (disposed || entry == null || item == null || !entry.item.mediaId.equals(item.mediaId)) {
      return;
    }
    activate(entry);
  }

  private void activate(Entry entry) {
    if (disposed || current == entry) return;
    next = null;
    Entry previous = current;
    current = entry;
    entry.activatedAt = SystemClock.elapsedRealtime();
    if (previous != null) previous.release();
    onActivated.run();
    emit(entry, "activated", "");
    handler.postDelayed(entry.timeout, READY_TIMEOUT_MS);
    trimAroundCurrent();
    updateReady();
  }

  @Override
  public void onPlaybackStateChanged(int state) {
    if (state == Player.STATE_READY) updateReady();
  }

  @Override
  public void onVideoSizeChanged(androidx.media3.common.VideoSize size) {
    Entry entry = current;
    if (!disposed && entry != null && entry.ready && !entry.failed && matches(entry)) {
      emit(entry, "ready", "");
    }
  }

  private void updateReady() {
    Entry entry = current;
    if (disposed || entry == null || entry.failed || !matches(entry)
        || player.getPlaybackState() != Player.STATE_READY) return;
    if (!entry.ready) {
      entry.ready = true;
      handler.removeCallbacks(entry.timeout);
      emit(entry, "ready", "");
      entry.release();
    }
  }

  @Override
  public void onRenderedFirstFrame(EventTime eventTime, Object output, long renderTimeMs) {
    Entry entry = current;
    if (disposed || entry == null || entry.failed || entry.firstFrame || !matches(entry)) return;
    if (eventTime.timeline.isEmpty() || eventTime.windowIndex < 0
        || eventTime.windowIndex >= eventTime.timeline.getWindowCount()) return;
    MediaItem item = eventTime.timeline.getWindow(eventTime.windowIndex,
        new androidx.media3.common.Timeline.Window()).mediaItem;
    if (!entry.item.mediaId.equals(item.mediaId)) return;
    entry.firstFrame = true;
    emit(entry, "ready", "");
  }

  @Override
  public void onPlayerError(EventTime eventTime, PlaybackException error) {
    Entry entry = eventMatches(next, eventTime) ? next
        : eventMatches(current, eventTime) ? current : null;
    if (entry != null) fail(entry, error.getErrorCodeName());
  }

  private boolean eventMatches(Entry entry, EventTime eventTime) {
    if (entry == null || eventTime.timeline.isEmpty() || eventTime.windowIndex < 0
        || eventTime.windowIndex >= eventTime.timeline.getWindowCount()) return false;
    MediaItem item = eventTime.timeline.getWindow(eventTime.windowIndex,
        new androidx.media3.common.Timeline.Window()).mediaItem;
    return entry.item.mediaId.equals(item.mediaId);
  }

  private void fail(Entry entry, String message) {
    if (disposed || entry.failed || (entry != current && entry != next)) return;
    entry.failed = true;
    emit(entry, "failed", message);
    if (entry == next) clearCandidate(entry.request.identity);
    entry.release();
  }

  private void emit(Entry entry, String kind, String message) {
    Map<String, Object> values = new HashMap<>();
    values.put("identity", entry.request.identity);
    values.put("generation", entry.generation);
    values.put("kind", kind);
    values.put("firstFrame", entry.firstFrame);
    values.put("message", message);
    values.put("prepared", entry.selection != null && entry.selection.ready);
    values.put("queueToActivationMs", Math.max(0, entry.activatedAt - entry.stagedAt));
    values.put("activationToReadyMs", entry.activatedAt == 0 ? 0L
        : Math.max(0, SystemClock.elapsedRealtime() - entry.activatedAt));
    values.put("url", entry.request.url);
    long duration = player.getDuration();
    values.put("durationMs", duration == C.TIME_UNSET ? 0L : Math.max(0, duration));
    values.put("positionMs", Math.max(0, player.getCurrentPosition()));
    values.put("bufferedMs", Math.max(0, player.getBufferedPosition()));
    values.put("playing", player.getPlayWhenReady() && player.getPlaybackState() == Player.STATE_READY);
    values.put("buffering", player.getPlaybackState() == Player.STATE_BUFFERING);
    androidx.media3.common.VideoSize size = player.getVideoSize();
    values.put("width", size.width * size.pixelWidthHeightRatio);
    values.put("height", size.height);
    lastEvent = values;
    if (events != null) events.success(new HashMap<>(values));
  }

  Map<String, Object> snapshot() {
    return new HashMap<>(lastEvent);
  }

  private void stop() {
    if (!listening) return;
    listening = false;
    player.removeListener(this);
    player.removeAnalyticsListener(this);
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    events = null;
    Entry pending = next;
    next = null;
    if (pending != null) pending.release();
    if (current != null) current.release();
    handler.removeCallbacksAndMessages(null);
    stop();
  }
}
