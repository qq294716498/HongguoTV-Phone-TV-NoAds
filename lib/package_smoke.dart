import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'danmaku_emoji_assets.dart';
import 'media_pipeline.dart';
import 'video_enhancement_assets.dart';
import 'windows_desktop.dart';
import 'dart:async';

Future<void> runPackageSmoke(List<String> arguments) async {
  if (arguments.length != 3) exit(2);
  final report = File(arguments[1]), input = arguments[2];
  Player? player;
  final evidence = <String, Object>{
    'ok': false,
    'version': appVersion,
    'build': windowsBuildNumber,
    'platform': Platform.operatingSystem,
    'syntheticMediaOnly': true,
  };
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  try {
    final repository = NativeRepository();
    await repository.initialize();
    evidence['nativeCore'] = true;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('windows_package_smoke', appVersion);
    if (preferences.getString('windows_package_smoke') != appVersion) {
      throw StateError('Preferences round trip failed');
    }
    await preferences.remove('windows_package_smoke');
    evidence['preferences'] = true;
    await rootBundle.load('${DanmakuEmojiAssets.directory}2764-fe0f.png');
    await VideoEnhancementAssets.prepare(VideoEnhancementAssets.ravuRgb);
    evidence['bundledAssets'] = true;
    final executor = FFmpegExecutor();
    await executor.run([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x90:rate=12',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '3',
      '-c:v',
      'libx264',
      '-threads',
      '1',
      '-c:a',
      'aac',
      input,
    ]);
    final probe = await executor.probe(input);
    verifyMediaDuration(probe, 3);
    if (!probe.hasAudio) throw StateError('Synthetic AAC stream missing');
    evidence['ffprobe'] = true;
    final remuxed = File(
      '${report.parent.path}${Platform.pathSeparator}remuxed.mkv',
    );
    await executor.run(['-i', input, '-map', '0', '-c', 'copy', remuxed.path]);
    verifyMediaDuration(await executor.probe(remuxed.path), 3);
    evidence['remux'] = true;
    player = Player(configuration: const PlayerConfiguration(muted: true));
    final video = VideoController(player);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Video(
            controller: video,
            controls: NoVideoControls,
            pauseUponEnteringBackgroundMode: false,
          ),
        ),
      ),
    );
    await windowManager.show();
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
      const Duration(seconds: 20),
    );
    evidence['flutterWindow'] = true;
    final advancing = player.stream.position.firstWhere(
      (time) => time.inMilliseconds >= 400,
    );
    await player.open(Media(remuxed.path));
    await player.setPlaylistMode(PlaylistMode.single);
    await advancing.timeout(const Duration(seconds: 20));
    await video.waitUntilFirstFrameRendered.timeout(
      const Duration(seconds: 20),
    );
    final frame = await player.screenshot(format: 'image/png');
    if (frame == null || frame.length < 100)
      throw StateError('Decoded frame missing');
    evidence['videoFrameRendered'] = true;
    evidence['decodedFrameBytes'] = frame.length;
    await player.pause();
    await player.seek(const Duration(milliseconds: 700));
    await player.setRate(1.5);
    await player.setVolume(20);
    await player.play();
    final afterSeek = player.stream.position.firstWhere(
      (time) => time.inMilliseconds > 1000,
    );
    await afterSeek.timeout(const Duration(seconds: 20));
    evidence['seekRateVolume'] = true;
    await AppDevice.channel.invokeMethod<void>('setPlaybackScreenOn', {
      'enabled': true,
    });
    await AppDevice.channel.invokeMethod<void>('setPlaybackScreenOn', {
      'enabled': false,
    });
    evidence['playbackPower'] = true;
    await windowManager.setFullScreen(true);
    if (!await windowManager.isFullScreen())
      throw StateError('Fullscreen failed');
    await windowManager.setFullScreen(false);
    evidence['fullscreen'] = true;
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    evidence['mediaKitPlayback'] = true;
    final desktop = WindowsDesktop(preferences);
    await desktop.initialize();
    if (!desktop.available)
      throw StateError('Native notification area unavailable');
    desktop.playbackOwner = player;
    await desktop.updatePlayback(attached: true, playing: true);
    final originalBounds = await windowManager.getBounds();
    final originalTopmost = await windowManager.isAlwaysOnTop();
    for (var repeat = 0; repeat < 3; repeat++) {
      await desktop.enterMini();
      if (!await windowManager.isAlwaysOnTop() || !desktop.mini)
        throw StateError('Mini not topmost');
      await windowManager.setSize(const Size(520, 340));
      final resized = await windowManager.getSize();
      if ((resized.width - 520).abs() > 2 || (resized.height - 340).abs() > 2)
        throw StateError('Mini resize failed');
      await desktop.setFullscreen(true);
      if (desktop.mini || !await windowManager.isFullScreen())
        throw StateError('Mini to fullscreen failed');
      await desktop.setFullscreen(false);
      final restored = await windowManager.getBounds();
      if ((restored.width - originalBounds.width).abs() > 2 ||
          (restored.height - originalBounds.height).abs() > 2 ||
          await windowManager.isAlwaysOnTop() != originalTopmost)
        throw StateError('Window state restoration failed');
    }
    evidence['miniReuseResizeRestore'] = true;
    await player.play();
    var toggles = 0;
    desktop.togglePlayback = () {
      unawaited(
        player!.playOrPause().then((_) async {
          toggles++;
          await desktop.updatePlayback(
            attached: true,
            playing: player!.state.playing,
          );
        }),
      );
    };
    Future<void> writes = Future.value();
    Future<void> write() => writes = writes.then((_) async {
      final pending = File('${report.path}.next');
      await pending.writeAsString(jsonEncode(evidence), flush: true);
      await pending.rename(report.path);
    });
    evidence['desktopReady'] = true;
    Timer? timer;
    timer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
      if (desktop.quitting) return;
      if (desktop.inTray && !await windowManager.isVisible()) {
        evidence['nativeTrayHidden'] = true;
        if (toggles == 0 && player!.state.playing)
          evidence['trayKeepsPlaying'] = true;
      }
      if (evidence['nativeTrayHidden'] == true &&
          !desktop.inTray &&
          await windowManager.isVisible())
        evidence['nativeTrayRestored'] = true;
      evidence['nativeTrayToggles'] = toggles;
      evidence['playing'] = player!.state.playing;
      await write();
    });
    desktop.savePlayback = () async {
      timer?.cancel();
      await player!.pause();
      for (final key in [
        'nativeTrayHidden',
        'trayKeepsPlaying',
        'nativeTrayRestored',
      ]) {
        if (evidence[key] != true)
          throw StateError('Missing native tray check: $key');
      }
      if (toggles != 2 || errors.isNotEmpty)
        throw StateError('Native toggle or Flutter errors: $errors');
      evidence['nativeTrayQuit'] = true;
      evidence['ok'] = true;
      await write();
      await player!.dispose();
    };
    await write();
    await Completer<void>().future;
  } catch (error) {
    evidence['error'] = error.toString();
    evidence['flutterErrors'] = errors;
    await report.writeAsString(jsonEncode(evidence), flush: true);
    await player?.dispose();
    exit(1);
  }
}
