import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'home_screen.dart';
import 'local_store.dart';
import 'profiles_screen.dart';
import 'media_library.dart';
import 'package_smoke.dart';
import 'lan_controller.dart';
import 'player_screen.dart';
import 'video_enhancement_assets.dart';
import 'danmaku_emoji_assets.dart';
import 'diary_service.dart';
import 'app_updates.dart';
import 'windows_update_runtime.dart';
import 'windows_desktop.dart';
import 'app_origin.dart';
import 'models.dart';
import 'watch_reminder_runtime.dart';
import 'television_navigation.dart';
import 'widgets.dart' show DramaCover;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows &&
      Platform.environment['HONGGUOTV_DISABLE_IMAGES'] == '1') {
    DramaCover.imagesDisabled = true;
  }
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(800, 600));
    try {
      await WindowsUpdateRuntime.initialize(arguments);
    } catch (error) {
      stderr.writeln('Windows update startup rejected: $error');
      rethrow;
    }
    if (arguments.firstOrNull == '--update-environment-smoke') {
      if (arguments.length != 2) exit(2);
      await File(arguments[1]).writeAsString(
        jsonEncode({
          'support': (await getApplicationSupportDirectory()).path,
          'executable': Platform.resolvedExecutable,
          'build': windowsBuildNumber,
        }),
        flush: true,
      );
      exit(0);
    }
  }
  MediaKit.ensureInitialized();
  VideoEnhancementAssets.registerLicenses();
  DanmakuEmojiAssets.registerLicenses();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  final device = await AppDevice.detect();
  DiaryService.add(
    '[App] 应用启动，版本: ${device.version}, 平台: ${Platform.operatingSystem}',
  );
  if (Platform.isWindows && arguments.firstOrNull == '--startup-smoke') {
    if (arguments.length != 2) exit(2);
    DramaCover.imagesDisabled = true;
    final ready = Completer<void>();
    final errors = <String>[];
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    runApp(
      AppBootstrap(
        device: device,
        onReady: () {
          if (!ready.isCompleted) ready.complete();
        },
      ),
    );
    final report = File(arguments[1]);
    try {
      await ready.future.timeout(const Duration(seconds: 30));
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      await Future<void>.delayed(const Duration(seconds: 2));
      if (errors.isNotEmpty) throw StateError(errors.join('\n'));
      var originText = false, originButton = false;
      void inspect(Element element) {
        if (element.widget is Text &&
            (element.widget as Text).data == projectFreeNotice)
          originText = true;
        if (element.widget.key == const ValueKey('acknowledge-project-origin'))
          originButton = true;
        element.visitChildren(inspect);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(inspect);
      if (!originText || !originButton)
        throw StateError('First launch notice did not render');
      await report.writeAsString(
        '{"ok":true,"normalAppStartup":true,"remoteImagesDisabled":true,"firstLaunchNoticeVisible":true}',
        flush: true,
      );
      exit(0);
    } catch (error) {
      await report.writeAsString(error.toString(), flush: true);
      exit(1);
    }
  }
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({
    super.key,
    this.device = const AppDevice(),
    this.onReady,
  });
  final AppDevice device;
  final VoidCallback? onReady;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  final navigator = GlobalKey<NavigatorState>();
  LocalStore? store;
  Object? error;
  bool _exiting = false;
  late AppDevice device = widget.device;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    AppUpdates.current?.dispose();
    AppUpdates.current = null;
    WatchReminderRuntime.current?.dispose();
    WatchReminderRuntime.current = null;
    WindowsDesktop.current?.dispose();
    WindowsDesktop.current = null;
    store?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    WatchReminderRuntime.current?.lifecycle(state);
    if (state == AppLifecycleState.resumed &&
        (Platform.isAndroid || Platform.isWindows)) {
      unawaited(_refreshDevice());
      unawaited(AppUpdates.current?.returnedFromSettings());
      unawaited(AppUpdates.current?.check());
    }
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() {
      error = null;
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      if (Platform.isWindows && WindowsDesktop.current == null) {
        final desktop = WindowsDesktop(preferences, exitProcess: exit);
        await desktop.initialize();
        WindowsDesktop.current = desktop;
        desktop.flushStore = () async {
          await store?.flushPendingWrites();
        };
        desktop.detachUI = () async {
          if (mounted) setState(() => _exiting = true);
          WidgetsBinding.instance.scheduleForcedFrame();
          await WidgetsBinding.instance.endOfFrame;
        };
        desktop.restoreUI = () async {
          if (mounted) setState(() => _exiting = false);
        };
      }
      await _refreshDevice();
      if (!mounted) return;
      if ((Platform.isAndroid || Platform.isWindows) &&
          AppUpdates.current == null) {
        AppUpdates.current = AppUpdates(preferences: preferences);
        unawaited(AppUpdates.current!.check());
      }
      await repository.initialize();
      if (mounted) {
        setState(() {
          store = LocalStore(preferences);
          repository.access = store;
          if ((Platform.isAndroid || Platform.isIOS) && !device.television) {
            WatchReminderRuntime.current?.dispose();
            WatchReminderRuntime.current = WatchReminderRuntime(store!);
          }
          MediaLibrary.attach(repository, store!);
          LanController.current?.dispose();
          final link = LanController(
            repository,
            store!,
            kind: device.television
                ? 'tv'
                : Platform.isWindows
                ? 'computer'
                : 'phone',
          );
          LanController.current = link;
          link.openPlayback = (request) async {
            final epoch = request.profileEpoch;
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                !link.receiving ||
                store!.profileEpoch != epoch ||
                !store!.allowsSource(request.detail.drama.source)) {
              throw StateError('当前用户不能接收播放');
            }
            await link.playbackHost?.stop();
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                store!.profileEpoch != epoch ||
                !link.receiving) {
              throw StateError('播放接收已取消');
            }
            final navigation = navigator.currentState;
            if (navigation == null) throw StateError('接收设备界面尚未就绪');
            unawaited(
              navigation.pushAndRemoveUntil<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    detail: request.detail,
                    initialIndex: request.index,
                    initialPosition: request.position,
                    repository: repository,
                    store: store!,
                    handoff: request,
                  ),
                ),
                (route) => route.isFirst,
              ),
            );
          };
        });
        widget.onReady?.call();
        if (Platform.isWindows) {
          unawaited(
            _finishWindowsUpdate().catchError(
              (Object failure) => WindowsUpdateRuntime.startupPhase(
                'ready-failed',
                error: failure,
              ),
            ),
          );
        }
      }
    } catch (failure) {
      if (Platform.isWindows)
        await WindowsUpdateRuntime.startupPhase(
          'bootstrap-failed',
          error: failure,
        );
      if (mounted) {
        setState(() {
          error = failure;
        });
      }
    }
  }

  Future<void> _finishWindowsUpdate() async {
    WindowsUpdateRuntime.flushStore = () async => store?.flushPendingWrites();
    await WindowsUpdateRuntime.startupPhase('bootstrap-ready');
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    await WindowsUpdateRuntime.startupPhase('first-frame');
    await WidgetsBinding.instance.endOfFrame;
    await WindowsUpdateRuntime.startupPhase('rendered');
    if (store?.configurationError != null)
      throw StateError(store!.configurationError!);
    final resume = await WindowsUpdateRuntime.ready();
    if (!mounted ||
        store == null ||
        resume == null ||
        store!.locked ||
        resume['profile'] != store!.profile.id)
      return;
    final detail = DramaDetail.fromJson(
      Map<String, dynamic>.from(resume['detail'] as Map),
    );
    final index = resume['index'] as int;
    if (!store!.allowsSource(detail.drama.source) ||
        index < 0 ||
        index >= detail.episodes.length)
      return;
    navigator.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          detail: detail,
          initialIndex: index,
          repository: repository,
          store: store!,
          initialPosition: (resume['position'] as num).toDouble(),
          initiallyPlaying: false,
          localOnly: resume['localOnly'] == true,
          allowOnlineFallback: resume['allowOnlineFallback'] != false,
          mediaId: resume['mediaId'] as String?,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _exiting
      ? const SizedBox.shrink()
      : DuanjuApp(
          repository: repository,
          store: store,
          bootstrapError: error?.toString(),
          onRetry: _initialize,
          television: device.television,
          version: device.version,
          navigatorKey: navigator,
          requireOriginNotice: true,
        );
}

class DuanjuApp extends StatefulWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
    this.requireOriginNotice = false,
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;
  final bool requireOriginNotice;

  @override
  State<DuanjuApp> createState() => _DuanjuAppState();
}

class _DuanjuAppState extends State<DuanjuApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  AppRepository get repository => widget.repository;
  LocalStore? get store => widget.store;
  String? get bootstrapError => widget.bootstrapError;
  VoidCallback? get onRetry => widget.onRetry;
  bool get television => widget.television;
  String get version => widget.version;
  GlobalKey<NavigatorState> get navigatorKey =>
      widget.navigatorKey ?? _navigatorKey;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store]),
    builder: (_, _) => _application(),
  );

  Widget _application() => MaterialApp(
    navigatorKey: navigatorKey,
    title: appName,
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
    builder: (context, child) {
      final mode = store?.displayMode ?? 'auto';
      final tv = mode == 'television' || mode == 'auto' && television;
      final theme = Theme.of(context);
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(theme.brightness),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: AppOrientationScope(
            television: tv,
            child: AppLayout(
              television: tv,
              version: version,
              mobileReminders:
                  !television && (Platform.isAndroid || Platform.isIOS),
              child: Theme(
                data: tv ? televisionTheme(theme) : theme,
                child: Shortcuts(
                  shortcuts: {
                    SingleActivator(
                      LogicalKeyboardKey.select,
                      includeRepeats: false,
                    ): ActivateIntent(),
                    SingleActivator(
                      LogicalKeyboardKey.gameButtonA,
                      includeRepeats: false,
                    ): ActivateIntent(),
                    if (!tv)
                      const SingleActivator(LogicalKeyboardKey.goBack):
                          const DismissIntent(),
                  },
                  child: TelevisionNavigation(
                    enabled: tv,
                    navigatorKey: navigatorKey,
                    child: FocusTraversalGroup(child: child!),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    home: store != null
        ? widget.requireOriginNotice
              ? FirstLaunchNotice(
                  preferences: store!.preferences,
                  child: _home(),
                )
              : _home()
        : _loading(),
  );

  Widget _home() => store!.locked
      ? ProfilesScreen(store: store!, locked: true)
      : HomeScreen(
          key: ValueKey('profile-${store!.profile.id}-${store!.profileEpoch}'),
          repository: repository,
          store: store!,
        );

  Widget _loading() => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_fill_rounded,
              color: Color(0xFFFF765F),
              size: 72,
            ),
            const SizedBox(height: 24),
            Text(
              bootstrapError ?? '正在打开$appName',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 24),
            if (bootstrapError == null)
              const CircularProgressIndicator()
            else
              FilledButton(onPressed: onRetry, child: const Text('重新打开')),
          ],
        ),
      ),
    ),
  );
}
