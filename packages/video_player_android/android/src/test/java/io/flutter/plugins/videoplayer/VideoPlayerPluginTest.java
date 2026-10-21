// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.content.Context;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.util.LongSparseArray;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import io.flutter.plugin.platform.PlatformViewRegistry;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.MockedStatic;
import org.mockito.MockitoAnnotations;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class VideoPlayerPluginTest {
  @Mock private TextureRegistry mockTextureRegistry;
  @Mock private TextureRegistry.SurfaceProducer mockSurfaceProducer;
  @Mock private PlatformViewRegistry mockPlatformViewRegistry;
  private VideoPlayerPlugin plugin;
  private BinaryMessenger messenger;
  private Configuration configuration;

  @Before
  public void setUp() {
    MockitoAnnotations.openMocks(this);
    when(mockTextureRegistry.createSurfaceProducer()).thenReturn(mockSurfaceProducer);

    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    Context context = mock(Context.class);
    Resources resources = mock(Resources.class);
    configuration = new Configuration();
    when(context.getResources()).thenReturn(resources);
    when(resources.getConfiguration()).thenReturn(configuration);
    when(binding.getApplicationContext()).thenReturn(context);
    when(binding.getTextureRegistry()).thenReturn(mockTextureRegistry);
    messenger = mock(BinaryMessenger.class);
    when(binding.getBinaryMessenger()).thenReturn(messenger);
    when(binding.getPlatformViewRegistry()).thenReturn(mockPlatformViewRegistry);

    plugin = new VideoPlayerPlugin();
    plugin.onAttachedToEngine(binding);
  }

  @SuppressWarnings("unchecked")
  private LongSparseArray<VideoPlayer> getVideoPlayers() throws Exception {
    final Field field = VideoPlayerPlugin.class.getDeclaredField("videoPlayers");
    field.setAccessible(true);
    return (LongSparseArray<VideoPlayer>) field.get(plugin);
  }

  // This is only a placeholder test and doesn't actually initialize the plugin.
  @Test
  public void initPluginDoesNotThrow() {
    final VideoPlayerPlugin plugin = new VideoPlayerPlugin();
  }

  @Test
  public void registersPlatformVideoViewFactory() {
    verify(mockPlatformViewRegistry)
        .registerViewFactory(
            eq("plugins.flutter.dev/video_player_android"), any(PlatformVideoViewFactory.class));
  }

  @Test
  public void createsPlatformViewVideoPlayer() throws Exception {
    try (MockedStatic<PlatformViewVideoPlayer> mockedPlatformViewVideoPlayerStatic =
        mockStatic(PlatformViewVideoPlayer.class)) {
      mockedPlatformViewVideoPlayerStatic
          .when(() -> PlatformViewVideoPlayer.create(any(), any(), any(), any()))
          .thenAnswer(call -> {
            assertEquals("software", ((VideoPlayerOptions) call.getArgument(3)).decoderMode);
            return mock(PlatformViewVideoPlayer.class);
          });

      final CreationOptions options =
          new CreationOptions(
              "https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4",
              null,
              new HashMap<>(),
              null,
              null,
              "software");

      final long playerId = plugin.createForPlatformView(options);

      final LongSparseArray<VideoPlayer> videoPlayers = getVideoPlayers();
      assertTrue(videoPlayers.get(playerId) instanceof PlatformViewVideoPlayer);
    }
  }

  @Test
  public void createsTextureVideoPlayer() throws Exception {
    try (MockedStatic<TextureVideoPlayer> mockedTextureVideoPlayerStatic =
        mockStatic(TextureVideoPlayer.class)) {
      mockedTextureVideoPlayerStatic
          .when(() -> TextureVideoPlayer.create(any(), any(), any(), any(), any()))
          .thenAnswer(call -> {
            assertEquals("hardware", ((VideoPlayerOptions) call.getArgument(4)).decoderMode);
            return mock(TextureVideoPlayer.class);
          });

      final CreationOptions options =
          new CreationOptions(
              "https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4",
              null,
              new HashMap<>(),
              null,
              null,
              "hardware");

      final TexturePlayerIds ids = plugin.createForTextureView(options);

      final LongSparseArray<VideoPlayer> videoPlayers = getVideoPlayers();
      assertTrue(videoPlayers.get(ids.getPlayerId()) instanceof TextureVideoPlayer);
    }
  }

  private Object diagnostics(String method, Map<String, Object> arguments) {
    ArgumentCaptor<BinaryMessenger.BinaryMessageHandler> captor =
        ArgumentCaptor.forClass(BinaryMessenger.BinaryMessageHandler.class);
    verify(messenger).setMessageHandler(eq("hongguo/video_diagnostics"), captor.capture());
    ByteBuffer call = StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall(method, arguments));
    call.rewind();
    AtomicReference<Object> value = new AtomicReference<>();
    captor.getValue().onMessage(call, reply -> {
      reply.rewind();
      value.set(StandardMethodCodec.INSTANCE.decodeEnvelope(reply));
    });
    return value.get();
  }

  @Test
  public void televisionCaptureRequiresExplicitOptInAndUsesReducedBound() throws Exception {
    configuration.uiMode = Configuration.UI_MODE_TYPE_TELEVISION;
    VideoPlayer player = mock(VideoPlayer.class);
    getVideoPlayers().put(42L, player);
    Map<String, Object> arguments = new HashMap<>();
    arguments.put("playerId", 42L);
    assertNull(diagnostics("captureFrame", arguments));
    verify(player, never()).captureFrame(anyInt(), any());
    arguments.put("allowTelevision", true);
    diagnostics("captureFrame", arguments);
    verify(player).captureFrame(eq(640), any(MethodChannel.Result.class));
  }

  @Test
  public void phoneCaptureKeepsOriginalBound() throws Exception {
    configuration.uiMode = Configuration.UI_MODE_TYPE_NORMAL;
    VideoPlayer player = mock(VideoPlayer.class);
    getVideoPlayers().put(42L, player);
    diagnostics("captureFrame", Map.of("playerId", 42L));
    verify(player).captureFrame(eq(960), any(MethodChannel.Result.class));
  }

  @Test
  public void firstFrameWaitPassesTransitionGenerationWithoutRequiringMediaUrl() throws Exception {
    VideoPlayer player = mock(VideoPlayer.class);
    getVideoPlayers().put(42L, player);
    Map<String, Object> expected = Map.of("firstFrame", true, "generation", 9L);
    doAnswer(invocation -> {
      MethodChannel.Result result = invocation.getArgument(1);
      result.success(expected);
      return null;
    }).when(player).waitForFirstFrame(eq(9L), any(MethodChannel.Result.class));
    assertEquals(expected, diagnostics("waitForFirstFrame", Map.of("playerId", 42L, "generation", 9L)));
    verify(player).waitForFirstFrame(eq(9L), any(MethodChannel.Result.class));
    diagnostics("waitForFirstFrame", Map.of("playerId", 42L));
    verify(player).waitForFirstFrame(eq(0L), any(MethodChannel.Result.class));
  }
}
