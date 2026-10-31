package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.test.utils.FakeTimeline;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.MediaSource;
import io.flutter.plugin.common.EventChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PlaybackQueueTest {
  ExoPlayer player;
  PreparedNext prepared;
  PlaybackQueue queue;
  final List<MediaItem> items = new ArrayList<>();
  final List<Map<String, Object>> events = new ArrayList<>();
  int selected;
  int state;
  Runnable activated;

  @Before
  public void setup() {
    player = mock(ExoPlayer.class);
    prepared = mock(PreparedNext.class);
    activated = mock(Runnable.class);
    state = Player.STATE_READY;
    items.add(item("current"));
    when(player.getMediaItemCount()).thenAnswer(call -> items.size());
    when(player.getCurrentMediaItemIndex()).thenAnswer(call -> selected);
    when(player.getCurrentMediaItem()).thenAnswer(call -> items.get(selected));
    when(player.getMediaItemAt(anyInt())).thenAnswer(call -> items.get(call.getArgument(0)));
    when(player.getPlaybackState()).thenAnswer(call -> state);
    when(player.getDuration()).thenReturn(5000L);
    when(player.getVideoSize()).thenReturn(new VideoSize(640, 360));
    doAnswer(call -> {
      items.add(((MediaSource) call.getArgument(0)).getMediaItem());
      return null;
    }).when(player).addMediaSource(any(MediaSource.class));
    doAnswer(call -> {
      int at = call.getArgument(0);
      items.remove(at);
      if (selected > at) selected--;
      return null;
    }).when(player).removeMediaItem(anyInt());
    doAnswer(call -> {
      int start = call.getArgument(0), end = call.getArgument(1);
      for (int index = end - 1; index >= start; index--) {
        items.remove(index);
        if (selected > index) selected--;
      }
      return null;
    }).when(player).removeMediaItems(anyInt(), anyInt());
    queue = new PlaybackQueue(player, prepared, activated);
    queue.listen(new EventChannel.EventSink() {
      @Override public void success(Object value) {
        events.add(new HashMap<>((Map<String, Object>) value));
      }
      @Override public void error(String code, String message, Object details) { fail(message); }
      @Override public void endOfStream() {}
    });
  }

  private static MediaItem item(String id) {
    return new MediaItem.Builder().setUri("http://127.0.0.1/cache/" + id + ".mp4")
        .setMediaId(id).build();
  }

  private static MediaSource source(String id) {
    MediaSource result = mock(MediaSource.class);
    when(result.getMediaItem()).thenReturn(item(id));
    return result;
  }

  private static PreparedMediaRequest request(String id) {
    return new PreparedMediaRequest(id, "http://127.0.0.1/cache/" + id + ".mp4", null, "mp4");
  }

  @Test
  public void stageAppendsOnlyOneItemWithoutStoppingOrPreparingPlayer() {
    assertTrue(queue.stage(request("next"), source("next"), 4, 1, null));
    assertEquals(2, items.size());
    assertEquals("current", player.getCurrentMediaItem().mediaId);
    assertTrue(queue.stage(request("next"), source("ignored"), 4, 2, null));
    assertEquals(2, items.size());
    assertTrue(queue.stage(request("replacement"), source("replacement"), 5, 3, null));
    assertEquals(2, items.size());
    assertEquals("replacement", items.get(1).mediaId);
    verify(player, never()).stop();
    verify(player, never()).prepare();
    verify(player, never()).setMediaSource(any(MediaSource.class));
    assertTrue(events.isEmpty());
  }

  @Test
  public void actualNativeTransitionEmitsIdentityAndTrimsPrevious() {
    PreparedNext.Selection selection = mock(PreparedNext.Selection.class);
    assertTrue(queue.stage(request("next"), source("next"), 4, 1, selection));
    selected = 1;
    queue.onMediaItemTransition(items.get(1), Player.MEDIA_ITEM_TRANSITION_REASON_AUTO);
    assertEquals(1, items.size());
    assertEquals("next", player.getCurrentMediaItem().mediaId);
    assertEquals("activated", events.get(0).get("kind"));
    assertEquals("next", events.get(0).get("identity"));
    assertEquals(4L, events.get(0).get("generation"));
    assertEquals("ready", events.get(1).get("kind"));
    verify(activated).run();
    verify(selection).release();
    queue.onMediaItemTransition(player.getCurrentMediaItem(), Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED);
    assertEquals(2, events.size());
    assertFalse(queue.clear("next", 2));
    assertEquals(1, items.size());
    assertEquals("next", player.getCurrentMediaItem().mediaId);
  }

  @Test
  public void manualAdvanceIsIdempotentAndRetainsPausedIntent() {
    queue.stage(request("next"), source("next"), 3, 1, null);
    assertTrue(queue.advance("next", false));
    verify(player).seekToDefaultPosition(1);
    verify(player).setPlayWhenReady(false);
    selected = 1;
    queue.onMediaItemTransition(items.get(1), Player.MEDIA_ITEM_TRANSITION_REASON_SEEK);
    assertTrue(queue.advance("next", false));
    verify(player, times(1)).seekToDefaultPosition(anyInt());
    verify(player, times(2)).setPlayWhenReady(false);
    assertFalse(queue.advance("different", true));
  }

  @Test
  public void suspendCancelsOnlyFutureAndBlocksLateStageUntilResumed() {
    PreparedNext.Selection selectedSource = mock(PreparedNext.Selection.class);
    queue.stage(request("next"), source("next"), 3, 1, selectedSource);
    queue.suspend(true, 2);
    assertEquals(1, items.size());
    assertEquals("current", player.getCurrentMediaItem().mediaId);
    verify(prepared).clear(null);
    verify(selectedSource).release();
    assertFalse(queue.stage(request("late"), source("late"), 4, 1, null));
    assertFalse(queue.stage(request("paused"), source("paused"), 4, 3, null));
    queue.suspend(false, 4);
    assertEquals(1, items.size());
    assertTrue(queue.stage(request("resumed"), source("resumed"), 4, 5, null));
    assertFalse(queue.clear(null, 3));
    assertEquals(2, items.size());
    assertTrue(queue.clear("resumed", 6));
    assertEquals(1, items.size());
  }

  @Test
  public void clearRacingNativeSelectionPromotesInsteadOfRemovingCurrent() {
    queue.stage(request("next"), source("next"), 3, 1, null);
    selected = 1;
    assertFalse(queue.clear("next", 2));
    assertEquals("next", player.getCurrentMediaItem().mediaId);
    assertEquals(1, items.size());
    assertEquals("activated", events.get(0).get("kind"));
  }

  @Test
  public void invalidOrEndedCurrentRejectsAndReleasesPreparedSource() {
    state = Player.STATE_ENDED;
    PreparedNext.Selection selection = mock(PreparedNext.Selection.class);
    assertFalse(queue.stage(request("next"), source("next"), 1, 1, selection));
    verify(selection).release();
    verify(player, never()).addMediaSource(any(MediaSource.class));
  }

  private static AnalyticsListener.EventTime time(MediaItem item) {
    Timeline timeline = new FakeTimeline(new FakeTimeline.TimelineWindowDefinition.Builder()
        .setMediaItem(item).build());
    return new AnalyticsListener.EventTime(0, timeline, 0, null, 0, timeline, 0, null, 0, 0);
  }

  @Test
  public void sourceFailureUsesEventItemIdentityAndStaleFailureCannotPoisonReplacement() {
    queue.stage(request("next"), source("next"), 7, 1, null);
    PlaybackException error = new PlaybackException("synthetic", null,
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND);
    queue.onPlayerError(time(item("next")), error);
    assertEquals(1, events.size());
    assertEquals("failed", events.get(0).get("kind"));
    assertEquals("next", events.get(0).get("identity"));
    assertEquals(7L, events.get(0).get("generation"));
    assertEquals(1, items.size());
    assertEquals("current", player.getCurrentMediaItem().mediaId);
    queue.stage(request("replacement"), source("replacement"), 8, 2, null);
    queue.onPlayerError(time(item("next")), error);
    assertEquals(1, events.size());
    assertEquals(2, items.size());
    assertEquals("replacement", items.get(1).mediaId);
  }

  @Test
  public void activationTimeoutFailsOnlyItsGenerationAndDisposalIgnoresLateEvents() {
    queue.stage(request("next"), source("next"), 7, 1, null);
    selected = 1;
    state = Player.STATE_BUFFERING;
    queue.onMediaItemTransition(items.get(1), Player.MEDIA_ITEM_TRANSITION_REASON_AUTO);
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    assertEquals("failed", events.get(1).get("kind"));
    assertEquals("queue_ready_timeout", events.get(1).get("message"));
    assertEquals(7L, events.get(1).get("generation"));
    queue.dispose();
    state = Player.STATE_READY;
    queue.onPlaybackStateChanged(state);
    ShadowLooper.idleMainLooper(20, TimeUnit.SECONDS);
    assertEquals(2, events.size());
    verify(player).removeListener(queue);
    verify(player).removeAnalyticsListener(queue);
  }
}
