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
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    child: Text(label, style: const TextStyle(fontSize: 18)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('输入剧名或拼音首字母'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            const SizedBox(height: 12),
            for (final row in _rows)
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final char in row.split(''))
                    _key(
                      char,
                      () => _insert(char.toLowerCase()),
                      focusNode: char == 'A' ? _firstKey : null,
                      autofocus: char == 'A',
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _key('删除', _delete),
                _key('清空', _clear),
                _key('系统输入法', () {
                  Navigator.of(context).pop(TelevisionKeyboardResult.systemIme);
                }),
                _key('搜索', _submit),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
