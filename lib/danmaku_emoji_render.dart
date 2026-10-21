import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'danmaku_emoji_assets.dart';
import 'danmaku_text.dart';

class DanmakuEmojiCache extends ChangeNotifier {
  DanmakuEmojiCache({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const decodeDimension = 64;
  static const maxConcurrentDecodes = 4;
  final AssetBundle _bundle;
  final _images = <String, ui.Image>{};
  final _requested = <String>{};
  final _queue = Queue<String>();
  var _workers = 0;
  var _disposed = false;

  int get imageCount => _images.length;
  int get decodedBytes => _images.values.fold(
    0,
    (sum, image) => sum + image.width * image.height * 4,
  );
  bool get loading => _workers > 0 || _queue.isNotEmpty;
  ui.Image? imageFor(String glyph) => _images[DanmakuEmojiAssets.paths[glyph]];

  void ensureLoaded(Iterable<String> texts) {
    if (_disposed) return;
    for (final text in texts) {
      for (final part in DanmakuEmojiContent.parse(text).parts) {
        for (final asset in part.assets) {
          if (_requested.add(asset)) _queue.add(asset);
        }
      }
    }
    while (_workers < maxConcurrentDecodes && _queue.isNotEmpty) {
      _workers++;
      unawaited(_decode());
    }
  }

  Future<void> _decode() async {
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final asset = _queue.removeFirst();
        ui.Codec? codec;
        try {
          final data = await _bundle.load(
            '${DanmakuEmojiAssets.directory}$asset',
          );
          if (_disposed) return;
          codec = await ui.instantiateImageCodec(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            targetWidth: decodeDimension,
            targetHeight: decodeDimension,
            allowUpscaling: false,
          );
          final frame = await codec.getNextFrame();
          if (_disposed) {
            frame.image.dispose();
            return;
          }
          _images[asset] = frame.image;
        } catch (_) {
          if (_disposed) return;
        } finally {
          codec?.dispose();
        }
        if (!_disposed) notifyListeners();
      }
    } finally {
      _workers--;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    super.dispose();
  }
}

class DanmakuEmojiPart {
  const DanmakuEmojiPart(this.text, {this.glyphs = const [], this.fallback});
  final String text;
  final List<String> glyphs;
  final String? fallback;
  String? get asset =>
      glyphs.isEmpty ? null : DanmakuEmojiAssets.paths[glyphs.first];
  Iterable<String> get assets =>
      glyphs.map((glyph) => DanmakuEmojiAssets.paths[glyph]!);
  String get fallbackText => fallback ?? text;

  bool ready(DanmakuEmojiCache? cache) =>
      cache != null &&
      glyphs.isNotEmpty &&
      glyphs.every((glyph) => cache.imageFor(glyph) != null);
}

class DanmakuEmojiContent {
  const DanmakuEmojiContent._(this.parts);
  static const maxCachedLines = 128;
  static final _recent = <String, DanmakuEmojiContent>{};
  final List<DanmakuEmojiPart> parts;

  static DanmakuEmojiContent parse(String text) {
    final cached = _recent.remove(text);
    if (cached != null) {
      _recent[text] = cached;
      return cached;
    }
    final parts = <DanmakuEmojiPart>[];
    final pendingText = StringBuffer();
    void flushText() {
      if (pendingText.isEmpty) return;
      parts.add(DanmakuEmojiPart(pendingText.toString()));
      pendingText.clear();
    }

    for (final expression in danmakuExpressionParts(text)) {
      final glyphs = expression.glyphs?.characters.toList();
      if (glyphs != null &&
          glyphs.every(DanmakuEmojiAssets.paths.containsKey)) {
        flushText();
        parts.add(
          DanmakuEmojiPart(
            expression.original,
            glyphs: List.unmodifiable(glyphs),
          ),
        );
        continue;
      }
      if (expression.expression) {
        pendingText.write(expression.original);
        continue;
      }
      for (final glyph in expression.original.characters) {
        if (DanmakuEmojiAssets.paths.containsKey(glyph)) {
          flushText();
          parts.add(
            DanmakuEmojiPart(
              glyph,
              glyphs: [glyph],
              fallback: '[${danmakuGlyphName(glyph) ?? '表情'}]',
            ),
          );
        } else if (glyph == '\uFFFC' || glyph == '🫡') {
          flushText();
          parts.add(
            DanmakuEmojiPart(
              glyph,
              fallback: glyph == '\uFFFC' ? '[OBJ]' : '[敬礼]',
            ),
          );
        } else {
          pendingText.write(glyph);
        }
      }
    }
    flushText();
    final content = DanmakuEmojiContent._(List.unmodifiable(parts));
    if (_recent.length >= maxCachedLines) _recent.remove(_recent.keys.first);
    _recent[text] = content;
    return content;
  }

  bool get hasImages => parts.any((part) => part.asset != null);
  String get fallbackText => parts.map((part) => part.fallbackText).join();
  double imageSize(TextStyle style, TextScaler scaler) =>
      scaler.scale(style.fontSize ?? 14) * 1.25;

  List<PlaceholderDimensions> placeholders(
    double size, {
    DanmakuEmojiCache? cache,
  }) => [
    for (final part in parts)
      if (part.ready(cache))
        for (final _ in part.glyphs)
          PlaceholderDimensions(
            size: Size.square(size),
            alignment: PlaceholderAlignment.middle,
          ),
  ];

  TextSpan span(TextStyle style, TextScaler scaler, DanmakuEmojiCache? cache) {
    final size = imageSize(style, scaler);
    return TextSpan(
      style: style,
      children: [
        for (final part in parts)
          if (!part.ready(cache))
            TextSpan(text: part.fallbackText)
          else
            for (final glyph in part.glyphs)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.square(
                  dimension: size,
                  child: _imageWidget(glyph, style, cache!),
                ),
              ),
      ],
    );
  }

  Widget _imageWidget(String glyph, TextStyle style, DanmakuEmojiCache cache) {
    return Opacity(
      opacity: style.color?.a ?? 1,
      child: RawImage(
        image: cache.imageFor(glyph)!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  double measure(
    TextStyle style,
    TextScaler scaler, {
    DanmakuEmojiCache? cache,
  }) {
    final painter =
        TextPainter(
          text: span(style, scaler, cache),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..setPlaceholderDimensions(
          placeholders(imageSize(style, scaler), cache: cache),
        );
    painter.layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class DanmakuEmojiText extends StatelessWidget {
  const DanmakuEmojiText({
    super.key,
    required this.text,
    required this.style,
    required this.scaler,
    required this.cache,
  });
  final String text;
  final TextStyle style;
  final TextScaler scaler;
  final DanmakuEmojiCache cache;

  @override
  Widget build(BuildContext context) {
    final content = DanmakuEmojiContent.parse(text);
    final resolvedStyle = style.copyWith(inherit: false);
    if (!content.hasImages) {
      return Text(
        content.fallbackText,
        style: resolvedStyle,
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        softWrap: false,
      );
    }
    return Text.rich(
      content.span(resolvedStyle, scaler, cache),
      style: resolvedStyle,
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      semanticsLabel: text,
      maxLines: 1,
      softWrap: false,
    );
  }
}
