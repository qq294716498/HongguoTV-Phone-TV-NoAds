import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_interactions.dart';
import 'portrait_video_frame.dart';

class EpisodeSwipeSurface extends StatefulWidget {
  const EpisodeSwipeSurface({
    super.key,
    required this.interactions,
    required this.enabled,
    required this.previousLabel,
    required this.nextLabel,
    this.currentLabel = '',
    this.contentReady,
    this.topAlignedLandscapeVideo = false,
    required this.child,
  });
  final PlayerInteractions interactions;
  final bool enabled;
  final String previousLabel;
  final String nextLabel;
  final String currentLabel;
  final bool? contentReady;
  final bool topAlignedLandscapeVideo;
  final Widget child;

  @override
  State<EpisodeSwipeSurface> createState() => _EpisodeSwipeSurfaceState();
}

class _EpisodeSwipeSurfaceState extends State<EpisodeSwipeSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  );
  double _height = 1;
  bool _committed = false;
  String _preview = '';
  String _outgoingLabel = '';
  int _direction = 1;
  int _dismissedSequence = -1;
  Uint8List? _frameBytes;
  ui.Image? _outgoingImage;
  int _frameDecodeSequence = 0;

  @override
  void initState() {
    super.initState();
    widget.interactions.addListener(_sync);
  }

  @override
  void didUpdateWidget(EpisodeSwipeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interactions != oldWidget.interactions) {
      oldWidget.interactions.removeListener(_sync);
      widget.interactions.addListener(_sync);
      _motion.stop();
      _motion.value = 0;
      _committed = false;
      _dismissedSequence = -1;
      _clearOutgoingFrame();
    }
    if (!widget.enabled) {
      _dismissedSequence = widget.interactions.episodeSwipeSequence;
      _motion.stop();
      _motion.value = 0;
      _committed = false;
      _clearOutgoingFrame();
    }
  }

  void _sync() {
    if (!mounted || !widget.enabled) return;
    final gestures = widget.interactions;
    _syncOutgoingFrame();
    if (gestures.episodeCommit != 0) {
      if (_committed || gestures.episodeSwipeSequence == _dismissedSequence) {
        return;
      }
      setState(() {
        _committed = true;
        _direction = gestures.episodeCommit;
        _outgoingLabel = widget.currentLabel.trim();
        _preview = _direction > 0 ? widget.nextLabel : widget.previousLabel;
      });
      _motion.animateTo(
        -_direction.toDouble(),
        duration: PlayerInteractions.episodeTransitionDuration,
        curve: Curves.easeOutCubic,
      );
    } else if (gestures.episodeDragging) {
      _direction = gestures.episodeDrag < 0 ? 1 : -1;
      _preview = _direction > 0 ? widget.nextLabel : widget.previousLabel;
      _motion.stop();
      _motion.value = (gestures.episodeDrag / _height).clamp(-1.0, 1.0);
    } else if (_committed) {
      setState(() => _committed = false);
      _motion.stop();
      _motion.value = 0;
    } else if (_motion.value != 0 && !_motion.isAnimating) {
      _motion.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _syncOutgoingFrame() {
    final bytes = widget.interactions.episodeFrameBytes;
    if (identical(bytes, _frameBytes)) return;
    _clearOutgoingFrame();
    if (bytes == null) return;
    _frameBytes = bytes;
    _decodeOutgoingFrame(bytes, _frameDecodeSequence);
  }

  Future<void> _decodeOutgoingFrame(Uint8List bytes, int sequence) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted ||
          !widget.enabled ||
          sequence != _frameDecodeSequence ||
          !identical(bytes, widget.interactions.episodeFrameBytes)) {
        frame.image.dispose();
        return;
      }
      setState(() => _outgoingImage = frame.image);
    } catch (_) {
    } finally {
      codec?.dispose();
    }
  }

  void _clearOutgoingFrame() {
    _frameDecodeSequence++;
    _frameBytes = null;
    _outgoingImage?.dispose();
    _outgoingImage = null;
  }

  Widget _outgoingPage() {
    final image = _outgoingImage;
    if (image == null) return _outgoingFallback();
    return ColoredBox(
      color: Colors.black,
      child: PortraitVideoFrame(
        enabled: widget.topAlignedLandscapeVideo,
        aspectRatio: image.width / image.height,
        child: RawImage(
          key: const ValueKey('episode-swipe-outgoing-frame'),
          image: image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }

  Widget _outgoingFallback() => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF252734), Color(0xFF171820)],
      ),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_outline,
              color: Colors.white38,
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              _outgoingLabel.isEmpty ? '当前剧集' : _outgoingLabel,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '正在切换剧集',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _previewPage({required bool waiting}) => ColoredBox(
    color: const Color(0xFF111116),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _direction > 0
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              color: Colors.white54,
              size: 28,
            ),
            const SizedBox(height: 12),
            Text(
              _preview,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              waiting
                  ? '正在准备播放'
                  : widget.interactions.canSwipeEpisode(_direction)
                  ? '松开切换'
                  : '没有更多剧集',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    widget.interactions.removeListener(_sync);
    _clearOutgoingFrame();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _height = constraints.maxHeight > 0 ? constraints.maxHeight : 1;
      return AnimatedBuilder(
        animation: Listenable.merge([_motion, widget.interactions]),
        child: widget.child,
        builder: (context, child) {
          final transitioning = widget.enabled && _committed;
          final ready =
              widget.contentReady ??
              !widget.interactions.episodeNavigationPending;
          final incomingOffset = (_motion.value + _direction) * _height;
          return ClipRect(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (transitioning || _outgoingImage != null)
                    Transform.translate(
                      key: const ValueKey('episode-swipe-outgoing'),
                      offset: Offset(0, _motion.value * _height),
                      child: Offstage(
                        offstage: !transitioning,
                        child: _outgoingPage(),
                      ),
                    ),
                  if (widget.enabled && _motion.value != 0 && !transitioning)
                    Transform.translate(
                      offset: Offset(0, incomingOffset),
                      child: _previewPage(waiting: false),
                    ),
                  Transform.translate(
                    key: const ValueKey('episode-swipe-page'),
                    offset: Offset(
                      0,
                      !widget.enabled
                          ? 0
                          : transitioning
                          ? incomingOffset
                          : _motion.value * _height,
                    ),
                    child: IgnorePointer(ignoring: transitioning, child: child),
                  ),
                  if (transitioning && !ready)
                    Transform.translate(
                      key: const ValueKey('episode-swipe-loading'),
                      offset: Offset(0, incomingOffset),
                      child: _previewPage(waiting: true),
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
