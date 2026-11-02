package io.flutter.plugins.videoplayer;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import android.os.SystemClock;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Timeline;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DecoderCounters;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import java.util.LinkedHashMap;
import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;

@UnstableApi
final class PlaybackDiagnostics implements AnalyticsListener {
  private final ExoPlayer player;
  private final String output;
  private final DecoderCounters finishedCounters = new DecoderCounters();
  private final Set<DecoderCounters> retiredCounters =
      Collections.newSetFromMap(new WeakHashMap<>());
  private DecoderCounters activeCounters;
  private String decoder = "pending";
  private String hardware = "unknown";
  private String codecError = "none";
  private long decoderInitMs;
  private MediaItem renderedMediaItem;
  private String audioDecoder = "pending";
  private String audioCodecError = "none";
  private String audioSinkError = "none";
  private long audioDecoderInitMs;
  private long audioDecoderInitTotal;
  private long audioUnderrunsTotal;
  private long lateAudioEventsTotal;
  private long lastAudioUnderrunRealtimeMs = -1;
  private long lastAudioUnderrunBufferMs = -1;
  private long lastAudioUnderrunElapsedSinceFeedMs = -1;
  private int lastAudioUnderrunWindowIndex = -1;
  private MediaItem lastAudioUnderrunMediaItem;
  private MediaItem audioCodecErrorMediaItem;
  private MediaItem audioSinkErrorMediaItem;

  PlaybackDiagnostics(ExoPlayer player, String output) {
    this.player = player;
    this.output = output;
    player.addAnalyticsListener(this);
  }

  @Override
  public void onRenderedFirstFrame(EventTime eventTime, Object output, long renderTimeMs) {
    if (!eventTime.timeline.isEmpty() && eventTime.windowIndex >= 0
        && eventTime.windowIndex < eventTime.timeline.getWindowCount()) {
      renderedMediaItem = eventTime.timeline.getWindow(
          eventTime.windowIndex, new Timeline.Window()).mediaItem;
    }
  }

  boolean hasFrameFor(MediaItem item) {
    return item != null && item.equals(renderedMediaItem);
  }

  @Override
  public void onVideoEnabled(EventTime eventTime, DecoderCounters counters) {
    activeCounters = counters;
  }

  @Override
  public void onVideoDisabled(EventTime eventTime, DecoderCounters counters) {
    counters.ensureUpdated();
    if (retiredCounters.add(counters)) finishedCounters.merge(counters);
    if (activeCounters == counters) activeCounters = null;
  }

  @Override
  public void onVideoDecoderInitialized(
      EventTime eventTime, String decoderName, long initializedTimestampMs,
      long initializationDurationMs) {
    if (!currentEvent(eventTime)) return;
    decoder = safeName(decoderName);
    decoderInitMs = initializationDurationMs;
    hardware = "unknown";
    if (Build.VERSION.SDK_INT >= 29) {
      try {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
          if (info.getName().equals(decoderName) || info.getCanonicalName().equals(decoderName)) {
            hardware = Boolean.toString(info.isHardwareAccelerated());
            break;
          }
        }
      } catch (RuntimeException ignored) {
      }
    }
  }

  @Override
  public void onVideoCodecError(EventTime eventTime, Exception error) {
    if (currentEvent(eventTime)) codecError = safeName(error.getClass().getSimpleName());
  }

  @Override
  public void onAudioDecoderInitialized(EventTime eventTime, String decoderName,
      long initializedTimestampMs, long initializationDurationMs) {
    audioDecoderInitTotal++;
    if (!currentEvent(eventTime)) {
      lateAudioEventsTotal++;
      return;
    }
    audioDecoder = safeName(decoderName);
    audioDecoderInitMs = initializationDurationMs;
  }

  @Override
  public void onAudioUnderrun(EventTime eventTime, int bufferSize, long bufferSizeMs,
      long elapsedSinceLastFeedMs) {
    audioUnderrunsTotal++;
    lastAudioUnderrunRealtimeMs = eventTime == null
        ? SystemClock.elapsedRealtime() : eventTime.realtimeMs;
    lastAudioUnderrunBufferMs = bufferSizeMs >= 0 ? bufferSizeMs : -1;
    lastAudioUnderrunElapsedSinceFeedMs = Math.max(-1, elapsedSinceLastFeedMs);
    lastAudioUnderrunWindowIndex = eventTime == null ? -1 : eventTime.windowIndex;
    lastAudioUnderrunMediaItem = eventItem(eventTime);
    if (!currentEvent(eventTime)) lateAudioEventsTotal++;
  }

  @Override
  public void onAudioCodecError(EventTime eventTime, Exception error) {
    if (currentEvent(eventTime)) {
      audioCodecError = safeName(error.getClass().getSimpleName());
      audioCodecErrorMediaItem = eventItem(eventTime);
    } else lateAudioEventsTotal++;
  }

  @Override
  public void onAudioSinkError(EventTime eventTime, Exception error) {
    if (currentEvent(eventTime)) {
      audioSinkError = safeName(error.getClass().getSimpleName());
      audioSinkErrorMediaItem = eventItem(eventTime);
    } else lateAudioEventsTotal++;
  }

  private boolean currentEvent(EventTime eventTime) {
    if (eventTime == null) return true;
    MediaItem item = eventItem(eventTime);
    return item != null && item.equals(player.getCurrentMediaItem());
  }

  private MediaItem eventItem(EventTime eventTime) {
    if (eventTime == null) return player.getCurrentMediaItem();
    if (eventTime.timeline.isEmpty() || eventTime.windowIndex < 0
        || eventTime.windowIndex >= eventTime.timeline.getWindowCount()) return null;
    return eventTime.timeline.getWindow(
        eventTime.windowIndex, new Timeline.Window()).mediaItem;
  }

  private boolean currentItem(MediaItem item) {
    return item != null && item.equals(player.getCurrentMediaItem());
  }

  private static String safeName(String value) {
    return value != null && value.matches("[A-Za-z0-9_.-]{1,160}") ? value : "unknown";
  }

  private static String safeMime(String value) {
    return value != null && value.matches("[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]{1,120}")
        && value.length() <= 160 ? value : "unknown";
  }

  Map<String, Object> snapshot() {
    DecoderCounters counters = new DecoderCounters();
    counters.merge(finishedCounters);
    if (activeCounters != null) {
      activeCounters.ensureUpdated();
      counters.merge(activeCounters);
    }
    Format format = player.getVideoFormat();
    Format audioFormat = player.getAudioFormat();
    PlaybackParameters playback = player.getPlaybackParameters();
    if (playback == null) playback = PlaybackParameters.DEFAULT;
    Timeline timeline = player.getCurrentTimeline();
    Map<String, Object> values = new LinkedHashMap<>();
    values.put("output", output);
    values.put("statisticsScope", "player-lifetime");
    values.put("sampleRealtimeMs", SystemClock.elapsedRealtime());
    values.put("nativeSpeed", (double) playback.speed);
    values.put("nativePitch", (double) playback.pitch);
    values.put("audioDecoder", audioDecoder);
    values.put("audioDecoderInitMs", audioDecoderInitMs);
    values.put("audioDecoderInitTotal", audioDecoderInitTotal);
    values.put("audioCodecError", audioCodecError);
    values.put("audioSinkError", audioSinkError);
    values.put("audioCodecErrorCurrentMedia", currentItem(audioCodecErrorMediaItem));
    values.put("audioSinkErrorCurrentMedia", currentItem(audioSinkErrorMediaItem));
    values.put("audioMime", audioFormat == null ? "unknown" : safeMime(audioFormat.sampleMimeType));
    values.put("audioSampleRate", audioFormat == null ? -1 : audioFormat.sampleRate);
    values.put("audioChannels", audioFormat == null ? -1 : audioFormat.channelCount);
    values.put("audioUnderrunsTotal", audioUnderrunsTotal);
    values.put("lastAudioUnderrunRealtimeMs", lastAudioUnderrunRealtimeMs);
    values.put("lastAudioUnderrunBufferMs", lastAudioUnderrunBufferMs);
    values.put("lastAudioUnderrunElapsedSinceFeedMs", lastAudioUnderrunElapsedSinceFeedMs);
    values.put("lastAudioUnderrunWindowIndex", lastAudioUnderrunWindowIndex);
    values.put("lastAudioUnderrunCurrentMedia", currentItem(lastAudioUnderrunMediaItem));
    values.put("lateAudioEventsTotal", lateAudioEventsTotal);
    values.put("mediaWindowIndex", player.getCurrentMediaItemIndex());
    values.put("timelineWindowCount", timeline == null ? 0 : timeline.getWindowCount());
    values.put("playWhenReady", player.getPlayWhenReady());
    values.put("suppressionReason", player.getPlaybackSuppressionReason());
    values.put("decoder", decoder);
    values.put("hardware", hardware);
    values.put("decoderInitMs", decoderInitMs);
    values.put("codecError", codecError);
    values.put("mime", format == null ? "unknown" : safeMime(format.sampleMimeType));
    values.put("codecs", format == null || format.codecs == null
        || !format.codecs.matches("[A-Za-z0-9_.,-]{1,160}") ? "unknown" : format.codecs);
    values.put("fps", format == null ? -1.0 : (double) format.frameRate);
    values.put("renderedTotal", counters.renderedOutputBufferCount);
    values.put("droppedTotal", counters.droppedBufferCount);
    values.put("skippedTotal", counters.skippedOutputBufferCount);
    values.put("maxConsecutiveDrops", counters.maxConsecutiveDroppedBufferCount);
    values.put("droppedToKeyframe", counters.droppedToKeyframeCount);
    values.put("decoderInitCount", counters.decoderInitCount);
    values.put("processingOffsetAvgUs", counters.videoFrameProcessingOffsetCount == 0 ? 0L
        : counters.totalVideoFrameProcessingOffsetUs / counters.videoFrameProcessingOffsetCount);
    values.put("durationMs", Math.max(0L, player.getDuration()));
    values.put("positionMs", player.getCurrentPosition());
    values.put("bufferedAheadMs", Math.max(0L, player.getBufferedPosition() - player.getCurrentPosition()));
    values.put("playing", player.isPlaying());
    values.put("state", player.getPlaybackState());
    return values;
  }
}
