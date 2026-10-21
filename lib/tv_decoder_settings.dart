import 'package:flutter/material.dart';

import 'remote_widgets.dart';

enum TvDecoderMode {
  automatic('自动（默认）'),
  hardware('仅硬件解码'),
  software('系统软件解码');

  const TvDecoderMode(this.label);
  final String label;

  static TvDecoderMode parse(Object? value) =>
      values.where((mode) => mode.name == value).firstOrNull ?? automatic;
}

bool isDecoderCompatibilityError(String message) {
  final value = message.toLowerCase();
  return [
    'no_exceeds_capabilities',
    'no_unsupported_type',
    'decoderinitializationexception',
    'mediacodecvideorenderer error',
    'error_code_decoder',
    'error_code_decoding',
    'decoder init failed',
    'decoding failed',
  ].any(value.contains);
}

class TvDecoderSettings extends StatelessWidget {
  const TvDecoderSettings({
    super.key,
    required this.value,
    required this.onChanged,
    this.applyingToPlayback = false,
  });

  final TvDecoderMode value;
  final ValueChanged<TvDecoderMode> onChanged;
  final bool applyingToPlayback;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('TV 解码模式', style: TextStyle(fontSize: 18)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final mode in TvDecoderMode.values)
            RemoteButton(
              key: ValueKey('tv-decoder-${mode.name}'),
              label: mode.label,
              selected: value == mode,
              autofocus: value == mode,
              onPressed: () => onChanged(mode),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        applyingToPlayback ? '保存后重新打开当前集并保留进度。' : '保存后在下次打开视频时生效，所有 TV 播放共用。',
      ),
      const Text(
        '自动沿用系统选择并允许初始化回退。系统软解仅使用设备已有的软件解码器，可能不支持 HEVC 或性能不足；失败请尝试其他线路或较低清晰度。视频输出模式不改变解码能力。',
      ),
    ],
  );
}
