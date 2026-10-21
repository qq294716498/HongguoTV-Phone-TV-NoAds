// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.util.LongSparseArray;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import io.flutter.FlutterInjector;
import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;

/** Android platform implementation of the VideoPlayerPlugin. */
public class VideoPlayerPlugin implements FlutterPlugin, AndroidVideoPlayerApi {
  private static final String TAG = "VideoPlayerPlugin";
  private final LongSparseArray<VideoPlayer> videoPlayers = new LongSparseArray<>();
  private FlutterState flutterState;
  private MethodChannel diagnosticChannel;
  private final VideoPlayerOptions sharedOptions = new VideoPlayerOptions();
  private long nextPlayerIdentifier = 1;

  /** Register this with the v2 embedding for the plugin to respond to lifecycle callbacks. */
  public VideoPlayerPlugin() {}

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    final FlutterInjector injector = FlutterInjector.instance();
    this.flutterState =
        new FlutterState(
            binding.getApplicationContext(),
            binding.getBinaryMessenger(),
            injector.flutterLoader()::getLookupKeyForAsset,
            injector.flutterLoader()::getLookupKeyForAsset,
            binding.getTextureRegistry());
    flutterState.startListening(this, binding.getBinaryMessenger());
    attachDiagnostics(binding.getBinaryMessenger());

    binding
        .getPlatformViewRegistry()
        .registerViewFactory(
            "plugins.flutter.dev/video_player_android",
            new PlatformVideoViewFactory(videoPlayers::get));
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (flutterState == null) {
      Log.wtf(TAG, "Detached from the engine before registering to it.");
    }
    diagnosticChannel.setMethodCallHandler(null);
    diagnosticChannel = null;
    flutterState.stopListening(binding.getBinaryMessenger());
    flutterState = null;
    onDestroy();
  }

  @OptIn(markerClass = UnstableApi.class)
  private void attachDiagnostics(BinaryMessenger messenger) {
    diagnosticChannel = new MethodChannel(messenger, "hongguo/video_diagnostics");
    diagnosticChannel.setMethodCallHandler((call, result) -> {
      if (!call.method.equals("snapshot") && !call.method.equals("transition")
          && !call.method.equals("prepareNext") && !call.method.equals("clearNext")
          && !call.method.equals("captureFrame") && !call.method.equals("waitForFirstFrame")) {
        result.notImplemented();
        return;
      }
      Number id = call.argument("playerId");
      VideoPlayer player = id == null ? null : videoPlayers.get(id.longValue());
      if (player == null) {
        if (call.method.equals("captureFrame")) {
          result.success(null);
          return;
        }
        result.error("player_unavailable", "播放器已释放", null);
        return;
      }
      if (call.method.equals("waitForFirstFrame")) {
        Number generation = call.argument("generation");
        player.waitForFirstFrame(generation == null ? 0L : generation.longValue(), result);
        return;
      }
      if (call.method.equals("captureFrame")) {
        int mode = flutterState.applicationContext.getResources().getConfiguration().uiMode;
        boolean television = (mode & android.content.res.Configuration.UI_MODE_TYPE_MASK)
            == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION;
        if (television && !Boolean.TRUE.equals(call.argument("allowTelevision"))) {
          result.success(null);
          return;
        }
        player.captureFrame(television ? FrameCapture.TELEVISION_MAX_EDGE
            : FrameCapture.MAX_EDGE, result);
        return;
      }
      if (call.method.equals("snapshot")) {
        result.success(player.playbackSnapshot());
        return;
      }
      if (call.method.equals("clearNext")) {
        result.success(player.clearNext(call.argument("identity")));
        return;
      }
      String url = call.argument("url");
      if (url == null || url.isEmpty()) {
        result.error("invalid_media", "播放地址为空", null);
        return;
      }
      String mediaType = call.argument("mediaType");
      if (mediaType == null) mediaType = call.argument("mimeType");
      try {
        PreparedMediaRequest request = new PreparedMediaRequest(
            call.argument("identity"), url, call.argument("headers"), mediaType);
        if (call.method.equals("prepareNext")) {
          player.prepareNext(flutterState.applicationContext, request, result);
        } else {
          Number elapsed = call.argument("requestElapsedMs");
          player.transitionTo(flutterState.applicationContext, request,
              elapsed == null ? 0L : elapsed.longValue(), result);
        }
      } catch (RuntimeException error) {
        result.error(call.method.equals("prepareNext") ? "prepare_failed" : "transition_failed",
            error.toString(), null);
      }
    });
  }

  private void disposeAllPlayers() {
    for (int i = 0; i < videoPlayers.size(); i++) {
      videoPlayers.valueAt(i).dispose();
    }
    videoPlayers.clear();
  }

  public void onDestroy() {
    // The whole FlutterView is being destroyed. Here we release resources acquired for all
    // instances
    // of VideoPlayer. Once https://github.com/flutter/flutter/issues/19358 is resolved this may
    // be replaced with just asserting that videoPlayers.isEmpty().
    // https://github.com/flutter/flutter/issues/20989 tracks this.
    disposeAllPlayers();
  }

  @Override
  public void initialize() {
    disposeAllPlayers();
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  public long createForPlatformView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    final String streamInstance = Long.toString(id);
    VideoPlayerOptions playerOptions = new VideoPlayerOptions(sharedOptions);
    playerOptions.backBufferDurationMs = options.getBackBufferDurationMs();
    playerOptions.decoderMode = options.getDecoderMode();

    VideoPlayer videoPlayer =
        PlatformViewVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(flutterState.binaryMessenger, streamInstance),
            videoAsset,
            playerOptions);

    registerPlayerInstance(videoPlayer, id);
    return id;
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  public @NonNull TexturePlayerIds createForTextureView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    final String streamInstance = Long.toString(id);
    TextureRegistry.SurfaceProducer handle = flutterState.textureRegistry.createSurfaceProducer();
    VideoPlayerOptions playerOptions = new VideoPlayerOptions(sharedOptions);
    playerOptions.backBufferDurationMs = options.getBackBufferDurationMs();
    playerOptions.decoderMode = options.getDecoderMode();

    VideoPlayer videoPlayer =
        TextureVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(flutterState.binaryMessenger, streamInstance),
            handle,
            videoAsset,
            playerOptions);

    registerPlayerInstance(videoPlayer, id);
    return new TexturePlayerIds(id, handle.id());
  }

  private @NonNull VideoAsset videoAssetWithOptions(@NonNull CreationOptions options) {
    final @NonNull String uri = options.getUri();
    if (uri.startsWith("asset:")) {
      return VideoAsset.fromAssetUrl(uri);
    } else if (uri.startsWith("rtsp:")) {
      return VideoAsset.fromRtspUrl(uri);
    } else {
      VideoAsset.StreamingFormat streamingFormat = VideoAsset.StreamingFormat.UNKNOWN;
      PlatformVideoFormat formatHint = options.getFormatHint();
      if (formatHint != null) {
        switch (formatHint) {
          case SS:
            streamingFormat = VideoAsset.StreamingFormat.SMOOTH;
            break;
          case DASH:
            streamingFormat = VideoAsset.StreamingFormat.DYNAMIC_ADAPTIVE;
            break;
          case HLS:
            streamingFormat = VideoAsset.StreamingFormat.HTTP_LIVE;
            break;
        }
      }
      return VideoAsset.fromRemoteUrl(
          uri, streamingFormat, options.getHttpHeaders(), options.getUserAgent());
    }
  }

  private void registerPlayerInstance(VideoPlayer player, long id) {
    // Set up the instance-specific API handler, and make sure it is removed when the player is
    // disposed.
    BinaryMessenger messenger = flutterState.binaryMessenger;
    final String channelSuffix = Long.toString(id);
    VideoPlayerInstanceApi.Companion.setUp(messenger, player, channelSuffix);
    player.setDisposeHandler(
        () -> VideoPlayerInstanceApi.Companion.setUp(messenger, null, channelSuffix));

    videoPlayers.put(id, player);
  }

  @NonNull
  private VideoPlayer getPlayer(long playerId) {
    VideoPlayer player = videoPlayers.get(playerId);

    // Avoid a very ugly un-debuggable NPE that results in returning a null player.
    if (player == null) {
      String message = "No player found with playerId <" + playerId + ">";
      if (videoPlayers.size() == 0) {
        message += " and no active players created by the plugin.";
      }
      throw new IllegalStateException(message);
    }

    return player;
  }

  @Override
  public void dispose(long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.dispose();
    videoPlayers.remove(playerId);
  }

  @Override
  public void setMixWithOthers(boolean mixWithOthers) {
    sharedOptions.mixWithOthers = mixWithOthers;
  }

  @Override
  public @NonNull String getLookupKeyForAsset(@NonNull String asset, @Nullable String packageName) {
    return packageName == null
        ? flutterState.keyForAsset.get(asset)
        : flutterState.keyForAssetAndPackageName.get(asset, packageName);
  }

  private interface KeyForAssetFn {
    String get(String asset);
  }

  private interface KeyForAssetAndPackageName {
    String get(String asset, String packageName);
  }

  private static final class FlutterState {
    final Context applicationContext;
    final BinaryMessenger binaryMessenger;
    final KeyForAssetFn keyForAsset;
    final KeyForAssetAndPackageName keyForAssetAndPackageName;
    final TextureRegistry textureRegistry;

    FlutterState(
        Context applicationContext,
        BinaryMessenger messenger,
        KeyForAssetFn keyForAsset,
        KeyForAssetAndPackageName keyForAssetAndPackageName,
        TextureRegistry textureRegistry) {
      this.applicationContext = applicationContext;
      this.binaryMessenger = messenger;
      this.keyForAsset = keyForAsset;
      this.keyForAssetAndPackageName = keyForAssetAndPackageName;
      this.textureRegistry = textureRegistry;
    }

    void startListening(VideoPlayerPlugin methodCallHandler, BinaryMessenger messenger) {
      AndroidVideoPlayerApi.Companion.setUp(messenger, methodCallHandler);
    }

    void stopListening(BinaryMessenger messenger) {
      AndroidVideoPlayerApi.Companion.setUp(messenger, null);
    }
  }
}
