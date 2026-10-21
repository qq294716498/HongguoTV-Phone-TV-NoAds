package io.flutter.plugins.videoplayer;

import android.content.Context;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;

@UnstableApi
final class PreparedPlayerProvider implements VideoPlayer.ExoPlayerProvider {
  final PreparedNext preparedNext;
  private final DefaultPreloadManager.Builder builder;
  private ExoPlayer player;

  PreparedPlayerProvider(Context context, VideoAsset asset, VideoPlayerOptions options) {
    this(context, asset, options, new DefaultRenderersFactory(context)
        .setEnableDecoderFallback(true)
        .setMediaCodecSelector(DecoderPolicy.selector(options.decoderMode))
        .experimentalSetEnableMediaCodecVideoRendererPrewarming(false));
  }

  PreparedPlayerProvider(Context context, VideoAsset asset, VideoPlayerOptions options,
      RenderersFactory renderersFactory) {
    DefaultLoadControl.Builder loadControl = new DefaultLoadControl.Builder()
        .setPlayerTargetBufferBytes("preload", PreparedNext.MAX_PRELOAD_BYTES);
    if (options.backBufferDurationMs != null) {
      if (options.backBufferDurationMs < 0) {
        throw new IllegalArgumentException("backBufferDurationMs must be at least 0");
      }
      loadControl.setBackBuffer(
          (int) Math.min(options.backBufferDurationMs, Integer.MAX_VALUE), true);
    }
    builder = new DefaultPreloadManager.Builder(context,
        index -> DefaultPreloadManager.PreloadStatus.specifiedRangeLoaded(PreparedNext.BUFFER_DURATION_MS))
        .setMediaSourceFactory(asset.getMediaSourceFactory(context))
        .setTrackSelectorFactory(DefaultTrackSelector::new)
        .setRenderersFactory(renderersFactory)
        .setLoadControl(loadControl.build());
    preparedNext = new PreparedNext(builder.build());
  }

  @Override
  public ExoPlayer get() {
    if (player == null) {
      try {
        player = builder.buildExoPlayer();
      } catch (RuntimeException error) {
        preparedNext.dispose();
        throw error;
      }
    }
    return player;
  }
}
