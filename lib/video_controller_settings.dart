import 'package:media_kit_video/media_kit_video.dart';

import 'playback_preferences.dart';

VideoControllerConfiguration playbackVideoConfiguration({
  required String operatingSystem,
  required PlaybackPreferences preferences,
  bool macHardwareVideoOutput = true,
}) => VideoControllerConfiguration(
  enableHardwareAcceleration:
      operatingSystem != 'ios' &&
      (operatingSystem != 'macos' || macHardwareVideoOutput),
  hwdec: operatingSystem == 'windows'
      ? preferences.windowsVideoCompatibility
            ? 'd3d11va-copy'
            : 'auto'
      : operatingSystem == 'macos' && !macHardwareVideoOutput
      ? 'videotoolbox-copy'
      : null,
);
