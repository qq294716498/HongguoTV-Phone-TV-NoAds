package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;

import android.content.Context;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.LoadingInfo;
import androidx.media3.datasource.TransferListener;
import androidx.media3.exoplayer.drm.DrmSessionManager;
import androidx.media3.exoplayer.drm.DrmSessionEventListener;
import androidx.media3.exoplayer.source.MediaPeriod;
import androidx.media3.exoplayer.source.MediaSourceEventListener;
import androidx.media3.exoplayer.source.TrackGroupArray;
import androidx.media3.exoplayer.upstream.Allocator;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.test.utils.FakeMediaPeriod;
import androidx.media3.test.utils.FakeMediaSource;
import androidx.media3.test.utils.FakeRenderer;
import androidx.media3.test.utils.FakeTimeline;
import androidx.test.core.app.ApplicationProvider;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PreparedPlaybackIntegrationTest {
  private static final class EnabledRenderers {
    final AtomicInteger active = new AtomicInteger();
    final AtomicInteger peak = new AtomicInteger();
  }

  private static final class CountingRenderer extends FakeRenderer {
    final EnabledRenderers counts;

    CountingRenderer(EnabledRenderers counts) {
      super(C.TRACK_TYPE_VIDEO);
      this.counts = counts;
    }

    @Override
    protected void onEnabled(boolean joining, boolean mayRenderStartOfStream) throws ExoPlaybackException {
      super.onEnabled(joining, mayRenderStartOfStream);
      int active = counts.active.incrementAndGet();
      counts.peak.accumulateAndGet(active, Math::max);
    }

    @Override
    protected void onDisabled() {
      counts.active.decrementAndGet();
      super.onDisabled();
    }
  }

  private static final class Reply implements MethodChannel.Result {
    Object value;
    String error;

    @Override
    public void success(Object value) {
      this.value = value;
    }

    @Override
    public void error(String code, String message, Object details) {
      error = code;
    }

    @Override
    public void notImplemented() {
      error = "not_implemented";
    }
  }

  private static FakeMediaSource source(String id) {
    MediaItem item = new MediaItem.Builder().setUri("http://127.0.0.1/unused/" + id).setMediaId(id).build();
    FakeTimeline timeline = new FakeTimeline(new FakeTimeline.TimelineWindowDefinition.Builder()
        .setMediaItem(item).setUid(id).setDurationUs(5_000_000)
        .setDefaultPositionUs(0).setWindowPositionInFirstPeriodUs(0).build());
    return new FakeMediaSource(timeline,
        new Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).build()) {
      @Override
      protected MediaPeriod createMediaPeriod(MediaPeriodId id, TrackGroupArray tracks,
          Allocator allocator, MediaSourceEventListener.EventDispatcher events,
          DrmSessionManager drm, DrmSessionEventListener.EventDispatcher drmEvents,
          TransferListener transfer) {
        return new FakeMediaPeriod(tracks, allocator,
            FakeMediaPeriod.TrackDataFactory.samplesWithRateDurationAndKeyframeInterval(
                0, 30f, 5_000_000, 1), events, drm, drmEvents, false) {
          private Callback callback;

          @Override
          public synchronized void prepare(Callback callback, long positionUs) {
            this.callback = callback;
            super.prepare(callback, positionUs);
          }

          @Override
          public boolean continueLoading(LoadingInfo loadingInfo) {
            boolean loaded = super.continueLoading(loadingInfo);
            if (loaded) callback.onContinueLoadingRequested(this);
            return loaded;
          }
        };
      }
    };
  }

  private static void await(BooleanSupplier condition) throws Exception {
    long deadline = System.nanoTime() + 10_000_000_000L;
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() >= deadline) fail("Synthetic Media3 condition timed out");
      ShadowLooper.idleMainLooper();
      Thread.sleep(1);
    }
  }

  @Test
  public void realManagerTransfersLoadedPeriodAndRemovingPreloadKeepsPlaybackAlive() throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    EnabledRenderers counts = new EnabledRenderers();
    RenderersFactory renderers = (handler, video, audio, text, metadata) ->
        new Renderer[] {new CountingRenderer(counts)};
    PreparedPlayerProvider provider = new PreparedPlayerProvider(context,
        new FakeVideoAsset("http://127.0.0.1/unused"), new VideoPlayerOptions(), renderers);
    ExoPlayer player = provider.get();
    assertSame(player, provider.get());
    FakeMediaSource first = source("first");
    FakeMediaSource next = source("second");
    try {
      player.setMediaSource(first);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      assertEquals(1, counts.active.get());
      PreparedMediaRequest request = new PreparedMediaRequest("session-2",
          "http://127.0.0.1/unused/second", null, "mp4");
      Reply reply = new Reply();
      provider.preparedNext.prepare(request, next, 1, reply);
      await(() -> reply.value != null || reply.error != null);
      assertNull(reply.error);
      assertEquals("first", player.getCurrentMediaItem().mediaId);
      assertEquals(1, player.getMediaItemCount());
      assertEquals(1, next.getCreatedMediaPeriods().size());
      assertEquals(1, counts.active.get());
      assertEquals(1, counts.peak.get());
      assertFalse(player.getPlayWhenReady());
      assertNull(player.getSecondaryRenderer(0));
      PreparedNext.Selection selection = provider.preparedNext.take(request);
      assertNotNull(selection);
      assertTrue(selection.ready);
      player.setMediaSource(selection.source);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      assertEquals("second", player.getCurrentMediaItem().mediaId);
      assertEquals(1, next.getCreatedMediaPeriods().size());
      selection.release();
      player.createMessage((type, payload) -> {}).send().blockUntilDelivered(5000);
      ShadowLooper.idleMainLooper();
      assertTrue(next.isPrepared());
      assertNotNull(next.getLastCreatedActiveMediaPeriod());
      assertEquals(Player.STATE_READY, player.getPlaybackState());
      assertNull(player.getPlayerError());
      assertEquals(1, counts.peak.get());
      assertEquals(0, provider.preparedNext.snapshot().get("preloadSourceCount"));
      player.play();
      ShadowLooper.idleMainLooper(100, java.util.concurrent.TimeUnit.MILLISECONDS);
      await(() -> player.getCurrentPosition() > 0);
      assertEquals(Player.STATE_READY, player.getPlaybackState());
      player.pause();
      assertFalse(player.getPlayWhenReady());
    } finally {
      player.release();
      provider.preparedNext.dispose();
    }
    assertEquals(0, counts.active.get());
    next.assertReleased();
    first.assertReleased();
  }
  @Test
  public void preparedQueueNaturallyAdvancesOnePlayerWithoutAnIntermediateEndOrSecondRenderer()
      throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    EnabledRenderers counts = new EnabledRenderers();
    RenderersFactory renderers = (handler, video, audio, text, metadata) ->
        new Renderer[] {new CountingRenderer(counts)};
    PreparedPlayerProvider provider = new PreparedPlayerProvider(context,
        new FakeVideoAsset("http://127.0.0.1/unused"), new VideoPlayerOptions(), renderers);
    ExoPlayer player = provider.get();
    java.util.List<java.util.Map<String, Object>> events = new java.util.ArrayList<>();
    AtomicInteger intermediateEnds = new AtomicInteger();
    PlaybackQueue queue = new PlaybackQueue(player, provider.preparedNext, () -> {});
    queue.listen(new io.flutter.plugin.common.EventChannel.EventSink() {
      @Override public void success(Object value) {
        events.add(new java.util.HashMap<>((java.util.Map<String, Object>) value));
      }
      @Override public void error(String code, String message, Object details) { fail(message); }
      @Override public void endOfStream() {}
    });
    player.addListener(new Player.Listener() {
      @Override public void onPlaybackStateChanged(int state) {
        if (state == Player.STATE_ENDED && player.getCurrentMediaItem() != null
            && "first-queue".equals(player.getCurrentMediaItem().mediaId)) {
          intermediateEnds.incrementAndGet();
        }
      }
    });
    FakeMediaSource first = source("first-queue");
    FakeMediaSource next = source("second-queue");
    try {
      player.setMediaSource(first);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      player.seekTo(4500);
      player.createMessage((type, payload) -> {}).send().blockUntilDelivered(5000);
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      PreparedMediaRequest request = new PreparedMediaRequest("queue-session-2",
          "http://127.0.0.1/unused/second-queue", null, "mp4");
      Reply reply = new Reply();
      provider.preparedNext.prepare(request, next, 1, reply);
      await(() -> reply.value != null || reply.error != null);
      assertNull(reply.error);
      PreparedNext.Selection selected = provider.preparedNext.take(request);
      assertNotNull(selected);
      assertTrue(selected.ready);
      assertTrue(queue.stage(request, selected.source, 17, 1, selected));
      assertEquals(2, player.getMediaItemCount());
      assertEquals(1, next.getCreatedMediaPeriods().size());
      player.play();
      long deadline = System.nanoTime() + 10_000_000_000L;
      while (player.getCurrentMediaItem() == null
          || !"second-queue".equals(player.getCurrentMediaItem().mediaId)) {
        if (System.nanoTime() >= deadline) {
          fail("Queue did not advance: state=" + player.getPlaybackState()
              + ", position=" + player.getCurrentPosition() + ", buffer=" + player.getBufferedPosition()
              + ", count=" + player.getMediaItemCount() + ", error=" + player.getPlayerError());
        }
        ShadowLooper.idleMainLooper(20, java.util.concurrent.TimeUnit.MILLISECONDS);
        Thread.sleep(1);
      }
      await(() -> events.stream().anyMatch(event -> "ready".equals(event.get("kind"))));
      assertSame(player, provider.get());
      assertEquals(1, player.getMediaItemCount());
      assertEquals("second-queue", player.getCurrentMediaItem().mediaId);
      assertEquals(1, next.getCreatedMediaPeriods().size());
      assertEquals(0, intermediateEnds.get());
      assertEquals(1, counts.peak.get());
      assertNull(player.getSecondaryRenderer(0));
      assertEquals("activated", events.get(0).get("kind"));
      assertEquals("queue-session-2", events.get(0).get("identity"));
      assertEquals(17L, events.get(0).get("generation"));
      assertFalse(queue.clear("queue-session-2", 2));
      assertEquals("second-queue", player.getCurrentMediaItem().mediaId);
      assertNull(player.getPlayerError());
      System.out.println("QUEUE_NATIVE_METRICS " + new org.json.JSONObject(java.util.Map.of(
          "synthetic", true, "playerInstances", 1, "peakActiveRenderers", counts.peak.get(),
          "intermediateEnds", intermediateEnds.get(), "nextCreatedPeriods", next.getCreatedMediaPeriods().size(),
          "nativeItemCountAfterHandoff", player.getMediaItemCount())));
    } finally {
      queue.dispose();
      player.release();
      provider.preparedNext.dispose();
    }
    assertEquals(0, counts.active.get());
    first.assertReleased();
    next.assertReleased();
  }

  @Test
  public void queuePauseDropsOnlyCandidateAndManualAdvanceRetainsPause() throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    EnabledRenderers counts = new EnabledRenderers();
    RenderersFactory renderers = (handler, video, audio, text, metadata) ->
        new Renderer[] {new CountingRenderer(counts)};
    PreparedPlayerProvider provider = new PreparedPlayerProvider(context,
        new FakeVideoAsset("http://127.0.0.1/unused"), new VideoPlayerOptions(), renderers);
    ExoPlayer player = provider.get();
    PlaybackQueue queue = new PlaybackQueue(player, provider.preparedNext, () -> {});
    FakeMediaSource first = source("paused-current");
    FakeMediaSource next = source("paused-next");
    try {
      player.setMediaSource(first);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      PreparedMediaRequest request = new PreparedMediaRequest("paused-session-2",
          "http://127.0.0.1/unused/paused-next", null, "mp4");
      assertTrue(queue.stage(request, next, 3, 1, null));
      queue.suspend(true, 2);
      player.createMessage((type, payload) -> {}).send().blockUntilDelivered(5000);
      ShadowLooper.idleMainLooper();
      assertEquals(1, player.getMediaItemCount());
      assertEquals("paused-current", player.getCurrentMediaItem().mediaId);
      assertFalse(queue.advance(request.identity, true));
      queue.suspend(false, 3);
      assertEquals(1, player.getMediaItemCount());
      FakeMediaSource resumed = source("resumed-next");
      assertTrue(queue.stage(request, resumed, 3, 4, null));
      assertTrue(queue.advance(request.identity, false));
      await(() -> player.getCurrentMediaItem() != null
          && "resumed-next".equals(player.getCurrentMediaItem().mediaId)
          && player.getPlaybackState() == Player.STATE_READY);
      assertFalse(player.getPlayWhenReady());
      assertTrue(queue.advance(request.identity, false));
      assertEquals(1, player.getMediaItemCount());
      assertEquals("resumed-next", player.getCurrentMediaItem().mediaId);
      assertEquals(1, counts.peak.get());
      assertNull(player.getSecondaryRenderer(0));
    } finally {
      queue.dispose();
      player.release();
      provider.preparedNext.dispose();
    }
    assertEquals(0, counts.active.get());
  }

  @Test
  public void preparedQueueKeepsFiveEpisodesBeyondTwoSecondsBeforeEachNaturalHandoff()
      throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    EnabledRenderers counts = new EnabledRenderers();
    RenderersFactory renderers = (handler, video, audio, text, metadata) ->
        new Renderer[] {new CountingRenderer(counts)};
    PreparedPlayerProvider provider = new PreparedPlayerProvider(context,
        new FakeVideoAsset("http://127.0.0.1/unused"), new VideoPlayerOptions(), renderers);
    ExoPlayer player = provider.get();
    PlaybackQueue queue = new PlaybackQueue(player, provider.preparedNext, () -> {});
    java.util.List<java.util.Map<String, Object>> events = new java.util.ArrayList<>();
    AtomicInteger intermediateEnds = new AtomicInteger();
    queue.listen(new io.flutter.plugin.common.EventChannel.EventSink() {
      @Override public void success(Object value) {
        events.add(new java.util.HashMap<>((java.util.Map<String, Object>) value));
      }
      @Override public void error(String code, String message, Object details) { fail(message); }
      @Override public void endOfStream() {}
    });
    player.addListener(new Player.Listener() {
      @Override public void onPlaybackStateChanged(int state) {
        if (state == Player.STATE_ENDED) intermediateEnds.incrementAndGet();
      }
    });
    String[] ids = {"chain-A", "chain-B", "chain-C", "chain-D", "chain-E"};
    FakeMediaSource[] sources = new FakeMediaSource[ids.length];
    for (int i = 0; i < ids.length; i++) sources[i] = source(ids[i]);
    try {
      player.setMediaSource(sources[0]);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      player.play();
      for (int i = 0; i < ids.length - 1; i++) {
        final int currentIndex = i;
        final int nextIndex = i + 1;
        final String identity = "chain-session-" + nextIndex;
        PreparedMediaRequest request = new PreparedMediaRequest(identity,
            "http://127.0.0.1/unused/" + ids[nextIndex], null, "mp4");
        Reply reply = new Reply();
        provider.preparedNext.prepare(request, sources[nextIndex], nextIndex, reply);
        await(() -> reply.value != null || reply.error != null);
        assertNull(reply.error);
        PreparedNext.Selection selected = provider.preparedNext.take(request);
        assertNotNull(selected);
        assertTrue(selected.ready);
        assertTrue(queue.stage(request, selected.source, 100 + nextIndex, nextIndex, selected));
        assertEquals(2, player.getMediaItemCount());
        assertEquals(1, sources[nextIndex].getCreatedMediaPeriods().size());
        long deadline = System.nanoTime() + 10_000_000_000L;
        while (player.getCurrentPosition() < 2000
            && ids[currentIndex].equals(player.getCurrentMediaItem().mediaId)
            && player.getPlayerError() == null) {
          if (System.nanoTime() >= deadline) fail("Current episode did not progress beyond two seconds");
          ShadowLooper.idleMainLooper(20, java.util.concurrent.TimeUnit.MILLISECONDS);
          Thread.sleep(1);
        }
        assertEquals(ids[currentIndex], player.getCurrentMediaItem().mediaId);
        assertEquals(5000L, player.getDuration());
        assertTrue(player.getCurrentPosition() >= 2000);
        assertTrue(player.getCurrentPosition() < 3000);
        assertEquals(currentIndex, events.stream()
            .filter(event -> "activated".equals(event.get("kind"))).count());
        assertEquals(0, intermediateEnds.get());
        assertEquals(1, counts.active.get());
        assertEquals(1, counts.peak.get());
        assertNull(player.getSecondaryRenderer(0));
        player.seekTo(4500);
        player.createMessage((type, payload) -> {}).send().blockUntilDelivered(5000);
        deadline = System.nanoTime() + 10_000_000_000L;
        while (!ids[nextIndex].equals(player.getCurrentMediaItem().mediaId)
            || player.getPlaybackState() != Player.STATE_READY
            || !identity.equals(queue.snapshot().get("identity"))
            || !"ready".equals(queue.snapshot().get("kind"))) {
          if (System.nanoTime() >= deadline) fail("Natural handoff did not select " + ids[nextIndex]);
          ShadowLooper.idleMainLooper(20, java.util.concurrent.TimeUnit.MILLISECONDS);
          Thread.sleep(1);
        }
        assertSame(player, provider.get());
        assertEquals(1, player.getMediaItemCount());
        assertEquals(100L + nextIndex, queue.snapshot().get("generation"));
        assertEquals(nextIndex, events.stream()
            .filter(event -> "activated".equals(event.get("kind"))).count());
        assertNull(player.getPlayerError());
      }
      long deadline = System.nanoTime() + 10_000_000_000L;
      while (player.getCurrentPosition() < 2000) {
        if (System.nanoTime() >= deadline) fail("Fifth episode did not remain active beyond two seconds");
        ShadowLooper.idleMainLooper(20, java.util.concurrent.TimeUnit.MILLISECONDS);
        Thread.sleep(1);
      }
      assertEquals(ids[4], player.getCurrentMediaItem().mediaId);
      assertEquals(4, events.stream().filter(event -> "activated".equals(event.get("kind"))).count());
      assertEquals(0, events.stream().filter(event -> "failed".equals(event.get("kind"))).count());
      assertEquals(0, intermediateEnds.get());
      assertEquals(1, counts.peak.get());
      assertNull(player.getSecondaryRenderer(0));
      System.out.println("QUEUE_FIVE_EPISODE_METRICS " + new org.json.JSONObject(java.util.Map.of(
          "synthetic", true, "episodes", ids.length, "naturalHandoffs", 4,
          "earlyPlaybackChecks", ids.length, "minimumEarlyPositionMs", 2000,
          "playerInstances", 1, "peakActiveRenderers", counts.peak.get(),
          "intermediateEnds", intermediateEnds.get(), "finalMediaId", player.getCurrentMediaItem().mediaId)));
    } finally {
      queue.dispose();
      player.release();
      provider.preparedNext.dispose();
    }
    assertEquals(0, counts.active.get());
    for (FakeMediaSource source : sources) source.assertReleased();
  }

}
