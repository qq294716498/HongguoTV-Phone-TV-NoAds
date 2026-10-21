package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertThrows;

import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class DecoderPolicyTest {
  private MediaCodecInfo codec(String name, boolean hardware) {
    return MediaCodecInfo.newInstance(name, "video/hevc", "video/hevc", null,
        hardware, !hardware, hardware, false, false);
  }

  @Test
  public void defaultPreservesSystemSelectionAndUnknownModeIsRejected() {
    assertSame(MediaCodecSelector.DEFAULT, DecoderPolicy.selector(null));
    assertSame(MediaCodecSelector.DEFAULT, DecoderPolicy.selector("automatic"));
    assertThrows(IllegalArgumentException.class, () -> DecoderPolicy.selector("ffmpeg"));
  }

  @Test
  public void softwareModeNeverPretendsMissingSoftwareHevcIsAvailable() {
    MediaCodecInfo hardware = codec("synthetic.vendor.hevc", true);
    assertEquals(List.of(), DecoderPolicy.filter(List.of(hardware), "software"));
  }

  @Test
  public void explicitModesKeepOnlyMatchingCodecsAndOrder() {
    MediaCodecInfo hardware = codec("synthetic.vendor.hevc", true);
    MediaCodecInfo software = codec("synthetic.android.hevc", false);
    MediaCodecInfo second = codec("synthetic.android.hevc.second", false);
    List<MediaCodecInfo> codecs = List.of(hardware, software, second);
    assertEquals(List.of(software, second), DecoderPolicy.filter(codecs, "software"));
    assertEquals(List.of(hardware), DecoderPolicy.filter(codecs, "hardware"));
  }

  @Test
  public void videoModeLeavesAudioCodecSelectionIntact() throws Exception {
    assertEquals(MediaCodecSelector.DEFAULT.getDecoderInfos("audio/mp4a-latm", false, false),
        DecoderPolicy.selector("hardware").getDecoderInfos("audio/mp4a-latm", false, false));
  }
}
