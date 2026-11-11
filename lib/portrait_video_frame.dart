import 'dart:math' as math;

import 'package:flutter/material.dart';

Rect? portraitLandscapeVideoRect(
  Size viewport,
  double aspectRatio, {
  double verticalOffset = -.08,
  EdgeInsets padding = EdgeInsets.zero,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (!viewport.width.isFinite ||
      !viewport.height.isFinite ||
      viewport.width <= 0 ||
      viewport.height <= viewport.width ||
      !aspectRatio.isFinite ||
      aspectRatio <= 1) {
    return null;
  }
  final width = viewport.width - padding.horizontal;
  final height = viewport.height - padding.vertical;
  if (width <= 0 || height <= 0) return null;
  final size = applyBoxFit(
    BoxFit.contain,
    Size(aspectRatio, 1),
    Size(width, height),
  ).destination;
  final centeredTop = (height - size.height) / 2;
  final header = 96 + math.max(0, textScaler.scale(32) - 32);
  return Rect.fromLTWH(
    padding.left + (width - size.width) / 2,
    padding.top +
        (centeredTop +
                height *
                    (verticalOffset.isFinite
                        ? verticalOffset.clamp(-.5, .5)
                        : -.08))
            .clamp(math.min(centeredTop, header), height - size.height),
    size.width,
    size.height,
  );
}

class PortraitVideoPosition extends InheritedWidget {
  const PortraitVideoPosition({
    super.key,
    required this.offset,
    required super.child,
  });

  final double offset;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PortraitVideoPosition>()
          ?.offset ??
      -.08;

  @override
  bool updateShouldNotify(PortraitVideoPosition oldWidget) =>
      offset != oldWidget.offset;
}

class PortraitVideoFrame extends StatelessWidget {
  const PortraitVideoFrame({
    super.key,
    required this.enabled,
    required this.aspectRatio,
    required this.child,
  });

  final bool enabled;
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final rect = enabled
          ? portraitLandscapeVideoRect(
              size,
              aspectRatio,
              verticalOffset: PortraitVideoPosition.of(context),
              padding: MediaQuery.paddingOf(context),
              textScaler: MediaQuery.textScalerOf(context),
            )
          : null;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(rect: rect ?? Offset.zero & size, child: child),
        ],
      );
    },
  );
}

List<double> portraitDanmakuLaneTops(
  Rect picture,
  double height,
  double rowHeight,
  EdgeInsets padding,
) {
  final safeTop = padding.top + 8;
  final safeBottom = height - padding.bottom - 8;
  final above = ((picture.top - safeTop) / rowHeight).floor().clamp(0, 4);
  final remaining = 4 - above;
  final belowStart = math.max(
    safeTop,
    math.min(picture.bottom, safeBottom - remaining * rowHeight),
  );
  return [
    for (var lane = 0; lane < above; lane++)
      picture.top - (lane + 1) * rowHeight,
    for (var lane = 0; lane < remaining; lane++)
      if (belowStart + (lane + 1) * rowHeight <= safeBottom)
        belowStart + lane * rowHeight,
  ];
}
