import 'tv_decoder_settings.dart';
import 'video_enhancement_preferences.dart';
import 'watch_reminder_models.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];

const danmakuOpacities = [.2, .35, .5, .55, .65, .8, .95, 1.0];

const danmakuSpeeds = [.5, .75, 1.0, 1.15, 1.25, 1.5, 2.0];

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.danmakuSpeed,
    this.danmakuOpacity,
    this.reminders = const WatchReminderPreferences(),
    this.preload = true,
    this.tvTextureOutput = false,
    this.tvDecoderMode = TvDecoderMode.automatic,
    this.enhancement = const VideoEnhancementPreferences(),
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final double? danmakuSpeed;
  final double? danmakuOpacity;
  final WatchReminderPreferences reminders;

  final bool preload;
  final bool tvTextureOutput;
  final TvDecoderMode tvDecoderMode;
  final VideoEnhancementPreferences enhancement;

  double effectiveDanmakuSpeed({required bool mobile}) =>
      danmakuSpeed ?? (mobile ? 1.15 : 1.0);

  double effectiveDanmakuOpacity({
    required bool mobile,
    bool television = false,
  }) =>
      danmakuOpacity ??
      (mobile
          ? .95
          : television
          ? .55
          : .62);

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    bool? autoAdvance,
    bool? danmaku,
    double? danmakuSpeed,
    double? danmakuOpacity,
    WatchReminderPreferences? reminders,
    bool? preload,
    bool? tvTextureOutput,
    TvDecoderMode? tvDecoderMode,
    VideoEnhancementPreferences? enhancement,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    danmakuSpeed: danmakuSpeed ?? this.danmakuSpeed,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    reminders: reminders ?? this.reminders,
    preload: preload ?? this.preload,
    tvTextureOutput: tvTextureOutput ?? this.tvTextureOutput,
    tvDecoderMode: tvDecoderMode ?? this.tvDecoderMode,
    enhancement: enhancement ?? this.enhancement,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    if (danmakuSpeed != null) 'danmakuSpeed': danmakuSpeed,
    if (danmakuOpacity != null) 'danmakuOpacity': danmakuOpacity,
    'reminders': reminders.toJson(),
    'preload': preload,
    'tvTextureOutput': tvTextureOutput,
    'tvDecoderMode': tvDecoderMode.name,
    'enhancement': enhancement.toJson(),
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    if (!playbackSpeeds.contains(speed) || quality < 0 || quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      danmakuSpeed: danmakuSpeeds.contains(value['danmakuSpeed'])
          ? (value['danmakuSpeed'] as num).toDouble()
          : null,
      danmakuOpacity: danmakuOpacities.contains(value['danmakuOpacity'])
          ? (value['danmakuOpacity'] as num).toDouble()
          : null,
      reminders: WatchReminderPreferences.fromJson(value['reminders']),
      preload: preload,
      tvTextureOutput: value['tvTextureOutput'] as bool? ?? false,
      tvDecoderMode: TvDecoderMode.parse(value['tvDecoderMode']),
      enhancement: VideoEnhancementPreferences.fromJson(value['enhancement']),
    );
  }
}
