import 'dart:math' as math;

import 'package:flutter/material.dart';

Rect? portraitLandscapeVideoRect(
  Size viewport,
  double aspectRatio, {
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
    padding.top + math.min(centeredTop, header),
    size.width,
    size.height,
  );
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
