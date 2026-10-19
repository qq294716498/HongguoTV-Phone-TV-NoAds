package io.flutter.plugins.videoplayer;

import androidx.annotation.Nullable;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import java.util.ArrayList;
import java.util.List;

@UnstableApi
final class DecoderPolicy {
  static MediaCodecSelector selector(@Nullable String mode) {
    if (mode == null || mode.equals("automatic")) return MediaCodecSelector.DEFAULT;
    if (!mode.equals("hardware") && !mode.equals("software")) {
      throw new IllegalArgumentException("Unknown decoder mode: " + mode);
    }
    return (mime, secure, tunneling) -> {
      List<MediaCodecInfo> codecs =
          MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling);
      return mime.startsWith("video/") ? filter(codecs, mode) : codecs;
    };
  }

  static List<MediaCodecInfo> filter(List<MediaCodecInfo> codecs, String mode) {
    List<MediaCodecInfo> selected = new ArrayList<>();
    for (MediaCodecInfo codec : codecs) {
      if (mode.equals("software") ? codec.softwareOnly : codec.hardwareAccelerated) {
        selected.add(codec);
      }
    }
    return selected;
  }

  private DecoderPolicy() {}
}
