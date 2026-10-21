import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TelevisionBackIntent extends Intent {
  const TelevisionBackIntent();
}

class TelevisionNavigation extends StatefulWidget {
  const TelevisionNavigation({
    super.key,
    required this.enabled,
    required this.navigatorKey,
    required this.child,
  });
  final bool enabled;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  static const channel = MethodChannel('hongguo/navigation');

  static bool dismissInput(BuildContext context) =>
      context
          .findAncestorStateOfType<TelevisionNavigationState>()
          ?.dismissInput() ??
      false;

  static Future<void> confirmExit(BuildContext context) async {
    await context
        .findAncestorStateOfType<TelevisionNavigationState>()
        ?.confirmExit();
  }

  @override
  State<TelevisionNavigation> createState() => TelevisionNavigationState();
}

class TelevisionNavigationState extends State<TelevisionNavigation> {
  FocusNode? _previousFocus;
  ModalRoute<dynamic>? _previousRoute;
  Timer? _backGuard;
  bool _handling = false;
  bool _exitPrompt = false;

  bool _editing(FocusNode node) =>
      node.context?.findAncestorStateOfType<EditableTextState>() != null ||
      node.context?.widget is EditableText;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    TelevisionNavigation.channel.setMethodCallHandler((call) async {
      if (call.method == 'back' && widget.enabled) await handleBack();
    });
    unawaited(_configure());
  }

  @override
  void didUpdateWidget(TelevisionNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _backGuard?.cancel();
      _backGuard = null;
      unawaited(_configure());
    }
  }

  Future<void> _configure() async {
    try {
      await TelevisionNavigation.channel.invokeMethod<void>('setEnabled', {
        'enabled': widget.enabled,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  void _focusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus is FocusScopeNode || _editing(focus)) return;
    final context = focus.context;
    if (context == null) return;
    _previousFocus = focus;
    _previousRoute = ModalRoute.of(context);
  }

  bool dismissInput() {
    if (!widget.enabled) return false;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || !_editing(focus)) return false;
    final context = focus.context;
    if (context == null) return false;
    final route = ModalRoute.of(context);
    final previous = _previousFocus;
    FocusNode? target;
    if (previous?.context != null &&
        previous!.canRequestFocus &&
        _previousRoute == route) {
      target = previous;
    } else {
      target = focus.nearestScope?.traversalDescendants.where((node) {
        final candidate = node.context;
        return node != focus &&
            node is! FocusScopeNode &&
            node.canRequestFocus &&
            candidate != null &&
            ModalRoute.of(candidate) == route &&
            !_editing(node);
      }).firstOrNull;
    }
    focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    target?.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    return true;
  }

  Future<void> handleBack() async {
    if (!widget.enabled || _handling) return;
    if (_backGuard?.isActive == true) return;
    _backGuard = Timer(
      const Duration(milliseconds: 300),
      () => _backGuard = null,
    );
    if (dismissInput()) return;
    _handling = true;
    try {
      final handled = await widget.navigatorKey.currentState?.maybePop();
      if (handled == false && mounted) unawaited(confirmExit());
    } finally {
      _handling = false;
    }
  }

  Future<void> confirmExit() async {
    final context = widget.navigatorKey.currentContext;
    if (_exitPrompt || context == null || !widget.enabled) return;
    _exitPrompt = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('退出红果TV？'),
          content: const Text('观看记录会保留。'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续使用'),
            ),
            FilledButton(
              key: const ValueKey('confirm-app-exit'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出软件'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) await SystemNavigator.pop();
    } finally {
      _exitPrompt = false;
    }
  }

  @override
  void dispose() {
    _backGuard?.cancel();
    FocusManager.instance.removeListener(_focusChanged);
    TelevisionNavigation.channel.setMethodCallHandler(null);
    unawaited(
      TelevisionNavigation.channel
          .invokeMethod<void>('setEnabled', {'enabled': false})
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false):
            TelevisionBackIntent(),
        SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
            TelevisionBackIntent(),
      },
      child: Actions(
        actions: {
          TelevisionBackIntent: CallbackAction<TelevisionBackIntent>(
            onInvoke: (_) {
              unawaited(handleBack());
              return null;
            },
          ),
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            final back =
                event.logicalKey == LogicalKeyboardKey.goBack ||
                event.logicalKey == LogicalKeyboardKey.escape;
            return back && event is! KeyDownEvent
                ? KeyEventResult.handled
                : KeyEventResult.ignored;
          },
          child: widget.child,
        ),
      ),
    );
  }
}
