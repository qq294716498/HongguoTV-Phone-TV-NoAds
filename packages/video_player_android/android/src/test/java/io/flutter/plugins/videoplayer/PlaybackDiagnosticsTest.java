package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import androidx.media3.common.Format;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.DecoderCounters;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.test.utils.FakeTimeline;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class PlaybackDiagnosticsTest {
  private static AnalyticsListener.EventTime time(MediaItem item, long realtime) {
    Timeline timeline = new FakeTimeline(new FakeTimeline.TimelineWindowDefinition.Builder()
        .setMediaItem(item).build());
    return new AnalyticsListener.EventTime(
        realtime, timeline, 0, null, 0, timeline, 0, null, 0, 0);
  }

  @Test
  public void snapshotReadsNativeSpeedAndAudioStateWithoutChangingPlayback() {
    ExoPlayer player = mock(ExoPlayer.class);
    when(player.getPlaybackParameters()).thenReturn(new PlaybackParameters(1.5f, 1f));
    when(player.getAudioFormat()).thenReturn(new Format.Builder()
        .setSampleMimeType("audio/mp4a-latm").setSampleRate(48000).setChannelCount(2).build());
    when(player.getPlaybackState()).thenReturn(Player.STATE_READY);
    when(player.getPlayWhenReady()).thenReturn(true);
    when(player.getPlaybackSuppressionReason()).thenReturn(Player.PLAYBACK_SUPPRESSION_REASON_NONE);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "flutter-texture");
    Map<String, Object> result = stats.snapshot();
    assertEquals(1.5, result.get("nativeSpeed"));
    assertEquals(1.0, result.get("nativePitch"));
    assertEquals("audio/mp4a-latm", result.get("audioMime"));
    assertEquals(48000, result.get("audioSampleRate"));
    assertEquals(2, result.get("audioChannels"));
    assertEquals(true, result.get("playWhenReady"));
    assertEquals(Player.STATE_READY, result.get("state"));
    assertEquals("player-lifetime", result.get("statisticsScope"));
    when(player.getPlaybackParameters()).thenReturn(PlaybackParameters.DEFAULT);
    assertEquals(1.0, stats.snapshot().get("nativeSpeed"));
  }

  @Test
  public void audioUnderrunsKeepLifetimeCountsAndIdentifyOldMediaEvents() {
    ExoPlayer player = mock(ExoPlayer.class);
    MediaItem first = MediaItem.fromUri("file:///first.mp4");
    MediaItem second = MediaItem.fromUri("file:///second.mp4");
    when(player.getCurrentMediaItem()).thenReturn(first);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "flutter-texture");
    stats.onAudioUnderrun(time(first, 100), 4096, 50, 60);
    assertEquals(1L, stats.snapshot().get("audioUnderrunsTotal"));
    assertEquals(true, stats.snapshot().get("lastAudioUnderrunCurrentMedia"));
    when(player.getCurrentMediaItem()).thenReturn(second);
    assertEquals(false, stats.snapshot().get("lastAudioUnderrunCurrentMedia"));
    stats.onAudioUnderrun(time(first, 200), 4096, C.TIME_UNSET, 80);
    Map<String, Object> result = stats.snapshot();
    assertEquals(2L, result.get("audioUnderrunsTotal"));
    assertEquals(1L, result.get("lateAudioEventsTotal"));
    assertEquals(200L, result.get("lastAudioUnderrunRealtimeMs"));
    assertEquals(-1L, result.get("lastAudioUnderrunBufferMs"));
    assertEquals(80L, result.get("lastAudioUnderrunElapsedSinceFeedMs"));
    assertEquals(false, result.get("lastAudioUnderrunCurrentMedia"));
    assertEquals(2L, stats.snapshot().get("audioUnderrunsTotal"));
    assertEquals(0L, new PlaybackDiagnostics(player, "flutter-texture")
        .snapshot().get("audioUnderrunsTotal"));
  }

  @Test
  public void lateDecoderAndErrorsCannotPoisonCurrentMediaOrExposeMessages() {
    ExoPlayer player = mock(ExoPlayer.class);
    MediaItem old = MediaItem.fromUri("https://synthetic.invalid/old?token=secret");
    MediaItem current = MediaItem.fromUri("https://synthetic.invalid/new?token=secret");
    when(player.getCurrentMediaItem()).thenReturn(current);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "flutter-texture");
    stats.onAudioDecoderInitialized(time(current, 100), "synthetic.audio.current", 90, 10);
    stats.onAudioDecoderInitialized(time(old, 120), "synthetic.audio.old", 85, 35);
    stats.onAudioCodecError(time(current, 130), new IllegalStateException("token=secret"));
    stats.onAudioSinkError(time(current, 140), new IllegalArgumentException("https://private.invalid/secret"));
    stats.onAudioCodecError(time(old, 150), new RuntimeException("token=secret"));
    stats.onAudioSinkError(time(old, 160), new RuntimeException("token=secret"));
    stats.onVideoCodecError(time(current, 170), new RuntimeException("token=secret"));
    Map<String, Object> result = stats.snapshot();
    assertEquals("synthetic.audio.current", result.get("audioDecoder"));
    assertEquals(10L, result.get("audioDecoderInitMs"));
    assertEquals(2L, result.get("audioDecoderInitTotal"));
    assertEquals(3L, result.get("lateAudioEventsTotal"));
    assertEquals("IllegalStateException", result.get("audioCodecError"));
    assertEquals("IllegalArgumentException", result.get("audioSinkError"));
    assertEquals("RuntimeException", result.get("codecError"));
    assertEquals(true, result.get("audioCodecErrorCurrentMedia"));
    assertFalse(result.toString().contains("secret"));
    assertFalse(result.toString().contains("https://"));
    when(player.getCurrentMediaItem()).thenReturn(old);
    assertEquals(false, stats.snapshot().get("audioCodecErrorCurrentMedia"));
  }

  @Test
  public void lateVideoDisableKeepsTheActiveDecoderAndIsCountedOnce() {
    ExoPlayer player = mock(ExoPlayer.class);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "flutter-texture");
    DecoderCounters old = new DecoderCounters();
    old.renderedOutputBufferCount = 900;
    old.droppedBufferCount = 7;
    DecoderCounters active = new DecoderCounters();
    active.renderedOutputBufferCount = 20;
    active.droppedBufferCount = 2;
    stats.onVideoEnabled(null, old);
    stats.onVideoEnabled(null, active);
    stats.onVideoDisabled(null, old);
    stats.onVideoDisabled(null, old);
    assertEquals(920, stats.snapshot().get("renderedTotal"));
    assertEquals(9, stats.snapshot().get("droppedTotal"));
    active.renderedOutputBufferCount = 25;
    assertEquals(925, stats.snapshot().get("renderedTotal"));
    stats.onVideoDisabled(null, active);
    assertEquals(925, stats.snapshot().get("renderedTotal"));
  }

  @Test
  public void absentMimeAndUnboundedMetadataRemainSafeToReport() {
    ExoPlayer player = mock(ExoPlayer.class);
    when(player.getAudioFormat()).thenReturn(new Format.Builder().build());
    when(player.getVideoFormat()).thenReturn(new Format.Builder()
        .setCodecs("https://private.invalid/?token=secret").build());
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "flutter-texture");
    stats.onAudioDecoderInitialized(null, "https://private.invalid/secret", 0, 0);
    Map<String, Object> result = stats.snapshot();
    assertEquals("unknown", result.get("audioMime"));
    assertEquals("unknown", result.get("mime"));
    assertEquals("unknown", result.get("codecs"));
    assertEquals("unknown", result.get("audioDecoder"));
    assertFalse(result.toString().contains("secret"));
  }

  @Test
  public void durationRefreshesAfterInitiallyUnknownTimeline() {
    ExoPlayer player = mock(ExoPlayer.class);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "surface-hybrid");
    when(player.getDuration()).thenReturn(C.TIME_UNSET);
    assertEquals(0L, stats.snapshot().get("durationMs"));
    when(player.getDuration()).thenReturn(90000L);
    assertEquals(90000L, stats.snapshot().get("durationMs"));
  }

  @Test
  public void countersSurviveDecoderRestartWithoutDoubleCountingSnapshots() {
    ExoPlayer player = mock(ExoPlayer.class);
    when(player.getVideoFormat()).thenReturn(new Format.Builder()
        .setSampleMimeType("video/avc").setFrameRate(30).build());
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "surface-hybrid");
    DecoderCounters first = new DecoderCounters();
    first.renderedOutputBufferCount = 900;
    first.droppedBufferCount = 7;
    stats.onVideoEnabled(null, first);
    assertEquals(900, stats.snapshot().get("renderedTotal"));
    assertEquals(900, stats.snapshot().get("renderedTotal"));
    stats.onVideoDisabled(null, first);
    DecoderCounters second = new DecoderCounters();
    second.renderedOutputBufferCount = 20;
    second.droppedBufferCount = 2;
    stats.onVideoEnabled(null, second);
    stats.onVideoDecoderInitialized(null, "synthetic.vendor.avc", 1L, 12L);
    Map<String, Object> result = stats.snapshot();
    assertEquals(920, result.get("renderedTotal"));
    assertEquals(9, result.get("droppedTotal"));
    assertEquals("synthetic.vendor.avc", result.get("decoder"));
    assertEquals("unknown", result.get("hardware"));
    assertEquals(30.0, result.get("fps"));
    assertEquals("surface-hybrid", result.get("output"));
  }
}
