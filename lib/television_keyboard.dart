import 'package:flutter/material.dart';

enum TelevisionKeyboardResult { submitted, systemIme, dismissed }

Future<TelevisionKeyboardResult> showTelevisionKeyboard(
  BuildContext context, {
  required TextEditingController controller,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
}) async {
  final result = await showDialog<TelevisionKeyboardResult>(
    context: context,
    builder: (_) => _TelevisionKeyboardDialog(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    ),
  );
  return result ?? TelevisionKeyboardResult.dismissed;
}

class _TelevisionKeyboardDialog extends StatefulWidget {
  const _TelevisionKeyboardDialog({
    required this.controller,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_TelevisionKeyboardDialog> createState() =>
      _TelevisionKeyboardDialogState();
}

class _TelevisionKeyboardDialogState extends State<_TelevisionKeyboardDialog> {
  static const _rows = [
    'ABCDEF',
    'GHIJKLM',
    'NOPQRS',
    'TUVWXY',
    'Z01234',
    '56789',
  ];

  final _firstKey = FocusNode(debugLabel: 'tv-keyboard-first');

  @override
  void dispose() {
    _firstKey.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged?.call(widget.controller.text);

  void _insert(String value) {
    final text = widget.controller.text;
    widget.controller.value = TextEditingValue(
      text: '$text$value',
      selection: TextSelection.collapsed(offset: text.length + value.length),
    );
    _emit();
  }

  void _delete() {
    final text = widget.controller.text;
    if (text.isEmpty) return;
    final next = text.substring(0, text.length - 1);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _emit();
  }

  void _clear() {
    widget.controller.value = const TextEditingValue();
    _emit();
  }

  void _submit() {
    final value = widget.controller.text.trim();
    Navigator.of(context).pop(TelevisionKeyboardResult.submitted);
    widget.onSubmitted?.call(value);
  }

  void _useSystemIme() =>
      Navigator.of(context).pop(TelevisionKeyboardResult.systemIme);

  void _cancel() => Navigator.of(context).pop();

  Widget _key(
    String label,
    VoidCallback onTap, {
    FocusNode? focusNode,
    bool autofocus = false,
  }) => TextButton(
    focusNode: focusNode,
    autofocus: autofocus,
    onPressed: onTap,
    style: TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(label, style: const TextStyle(fontSize: 18)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 键盘整体放进 Dialog 的可伸缩区域：每个按键行用 Expanded 平分剩余高度，
    // 这样 540 高的 TV 屏幕上底部「系统输入法 / 搜索」也不会被挤出可视区。
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('输入剧名或拼音首字母', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (_, value, _) => Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    value.text.isEmpty ? '尚未输入' : value.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      color: value.text.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 330),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final row in _rows)
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final char in row.split(''))
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: _key(
                                      char,
                                      () => _insert(char.toLowerCase()),
                                      focusNode: char == 'A' ? _firstKey : null,
                                      autofocus: char == 'A',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final action in [
                      ('删除', _delete),
                      ('清空', _clear),
                      ('系统输入法', _useSystemIme),
                      ('搜索', _submit),
                      ('取消', _cancel),
                    ])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: _key(action.$1, action.$2),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
