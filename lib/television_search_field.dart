import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';

class TelevisionSearchField extends StatelessWidget {
  const TelevisionSearchField({
    super.key,
    required this.controller,
    required this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => AppLayout.isTelevisionDevice(context)
      ? _TelevisionSearchEditor(field: this)
      : TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          textInputAction: textInputAction,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: decoration,
        );
}

class _TelevisionSearchEditor extends StatefulWidget {
  const _TelevisionSearchEditor({required this.field});
  final TelevisionSearchField field;

  @override
  State<_TelevisionSearchEditor> createState() =>
      _TelevisionSearchEditorState();
}

class _TelevisionSearchEditorState extends State<_TelevisionSearchEditor>
    with WidgetsBindingObserver {
  final _navigation = FocusNode(debugLabel: 'tv-search-navigation');
  late FocusNode _editor;
  bool _editing = false;
  bool _hadImeInsets = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _editor =
        widget.field.focusNode ?? FocusNode(debugLabel: 'tv-search-editor');
    _editor.addListener(_editorChanged);
  }

  @override
  void didUpdateWidget(_TelevisionSearchEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.field.focusNode != widget.field.focusNode) {
      _editor.removeListener(_editorChanged);
      if (oldWidget.field.focusNode == null) _editor.dispose();
      _editor =
          widget.field.focusNode ?? FocusNode(debugLabel: 'tv-search-editor');
      _editor.addListener(_editorChanged);
      _editing = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _imeChanged();
  }

  @override
  void didChangeMetrics() => _imeChanged();

  void _imeChanged() {
    final visible = View.of(context).viewInsets.bottom > 0;
    if (_editing && _hadImeInsets && !visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editing && View.of(context).viewInsets.bottom == 0) {
          _finishEditing();
        }
      });
    }
    if (_editing && visible) _hadImeInsets = true;
  }

  void _editorChanged() {
    if (mounted && _editing && !_editor.hasFocus) {
      setState(() {
        _editing = false;
        _hadImeInsets = false;
      });
    }
  }

  void _beginEditing() {
    if (_editing) return;
    _navigation.requestFocus();
    setState(() {
      _editing = true;
      _hadImeInsets = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing && ModalRoute.of(context)?.isCurrent != false) {
        _editor.requestFocus();
      }
    });
  }

  void _finishEditing() {
    if (!mounted) return;
    _editor.unfocus();
    setState(() {
      _editing = false;
      _hadImeInsets = false;
    });
    if (ModalRoute.of(context)?.isCurrent != false) _navigation.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_editing) {
      if (key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) _finishEditing();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!_navigation.hasPrimaryFocus) return KeyEventResult.ignored;
    if ([
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.gameButtonA,
    ].contains(key)) {
      if (event is KeyDownEvent) _beginEditing();
      return KeyEventResult.handled;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _navigation.focusInDirection(direction);
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor.removeListener(_editorChanged);
    if (widget.field.focusNode == null) _editor.dispose();
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final theme = Theme.of(context);
    final border =
        field.decoration.focusedBorder ??
        theme.inputDecorationTheme.focusedBorder ??
        const OutlineInputBorder();
    return Focus(
      focusNode: _navigation,
      autofocus: field.autofocus,
      onKeyEvent: _key,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: Semantics(
        hint: _editing ? '按返回结束输入' : '按确定输入，方向键浏览',
        child: TextField(
          controller: field.controller,
          focusNode: _editor,
          canRequestFocus: _editing,
          readOnly: !_editing,
          showCursor: _editing,
          enableInteractiveSelection: _editing,
          textInputAction: field.textInputAction,
          onTap: _beginEditing,
          onChanged: field.onChanged,
          onSubmitted: (value) {
            field.onSubmitted?.call(value);
            if (mounted) _finishEditing();
          },
          decoration: _navigation.hasPrimaryFocus
              ? field.decoration.copyWith(
                  enabledBorder: border.copyWith(
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 3,
                    ),
                  ),
                )
              : field.decoration,
        ),
      ),
    );
  }
}
