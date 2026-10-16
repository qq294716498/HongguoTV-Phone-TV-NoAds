import 'dart:async';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/television_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class DelayedNextRepository extends RouteRepository {
  final nextReady = Completer<void>();

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    if (episode.number == 2) await nextReady.future;
    return super.resolve(drama, episode, quality: quality);
  }
}

class ScreenOnPlayer extends ScriptedPlayer {
  void buffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }
}

void main() {
  for (final mode in [
    'portrait',
    'fullscreen',
    'television',
    'retry',
    'windows',
  ]) {
    testWidgets(
      '$mode playback keeps screen on through buffering and handoff',
      (tester) async {
        if (mode == 'windows') {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
        }
        tester.view.physicalSize = mode == 'portrait'
            ? const Size(390, 800)
            : const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <bool>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
          if (call.method == 'setPlaybackScreenOn') {
            requests.add((call.arguments as Map)['enabled'] as bool);
            if (mode == 'retry' && requests.length == 1) {
              throw PlatformException(code: 'transient-screen-on');
            }
          }
          if (call.method == 'setFullscreenBrightness') return true;
          if (call.method == 'batteryStatus') {
            return {'percent': 73, 'charging': false};
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
        );
        Future<void> frames() async {
          for (var i = 0; i < 24; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
        }

        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        final repository = DelayedNextRepository();
        final platform = ScreenOnPlayer();
        final screen = PlayerScreen(
          detail: await repository.detail(FixtureRepository.free),
          initialIndex: 0,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) =>
              ColoredBox(color: Colors.black, child: controls),
        );
        await tester.pumpWidget(
          mode == 'television'
              ? televisionHost(child: screen)
              : MaterialApp(home: screen),
        );
        await frames();
        platform.videoSize(1920, 1080);
        await frames();
        if (mode == 'retry') {
          await tester.pump(const Duration(seconds: 1));
          await frames();
          expect(requests, [true, true]);
          requests.removeAt(0);
        }
        expect(requests, [true]);
        if (mode != 'television') {
          expect(
            tester
                .widget<PlayerControls>(find.byType(PlayerControls))
                .fullscreen,
            mode == 'fullscreen' || mode == 'retry',
          );
        }
        platform.buffering(true);
        await frames();
        expect(requests, [true]);
        platform.buffering(false);
        platform.finishEpisode();
        await frames();
        await tester.pump(const Duration(seconds: 3));
        expect(requests, [true]);
        repository.nextReady.complete();
        await frames();
        expect(repository.requestedEpisodes, [1, 2]);
        expect(requests, [true]);

        void toggle() {
          if (mode == 'television') {
            tester
                .widget<TelevisionControls>(find.byType(TelevisionControls))
                .onTogglePlayback();
          } else {
            tester
                .widget<PlayerControls>(find.byType(PlayerControls))
                .onTogglePlayback();
          }
        }

        toggle();
        await frames();
        expect(requests, [true, false]);
        toggle();
        await frames();
        expect(requests, [true, false, true]);
        if (mode == 'windows') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await frames();
          expect(platform.state.playing, isTrue);
          expect(requests.last, true);
        }
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await frames();
        expect(requests.last, false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await frames();
        expect(requests.last, false);
        toggle();
        await frames();
        expect(requests.last, true);
        await tester.pumpWidget(const SizedBox.shrink());
        await frames();
        expect(requests.last, false);
        expect(tester.takeException(), isNull);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        store.dispose();
      },
    );
  }
}
