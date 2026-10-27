import 'package:flutter/material.dart';

class PlayerChoiceMenu<T> extends StatelessWidget {
  const PlayerChoiceMenu({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.tooltip,
    required this.values,
    required this.selected,
    required this.format,
    required this.onSelected,
    required this.onOpenChanged,
    this.enabled = true,
    this.width,
  });
  final Key buttonKey;
  final String label;
  final String tooltip;
  final List<T> values;
  final T selected;
  final String Function(T) format;
  final ValueChanged<T> onSelected;
  final ValueChanged<bool> onOpenChanged;
  final bool enabled;
  final double? width;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    onOpen: () => onOpenChanged(true),
    onClose: () => onOpenChanged(false),
    style: MenuStyle(
      alignment: Alignment.topCenter,
      backgroundColor: const WidgetStatePropertyAll(Color(0xF0202020)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    menuChildren: [
      for (final value in values)
        MenuItemButton(
          key: ValueKey('$tooltip-option-$value'),
          autofocus: value == selected,
          onPressed: enabled ? () => onSelected(value) : null,
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(
              value == selected ? const Color(0xFF8CD8F5) : Colors.white,
            ),
            minimumSize: const WidgetStatePropertyAll(Size(88, 36)),
          ),
          child: Semantics(
            selected: value == selected,
            child: Text(
              format(value),
              style: TextStyle(
                fontWeight: value == selected
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
        ),
    ],
    builder: (context, controller, child) => SizedBox(
      width: width,
      child: TextButton(
        key: buttonKey,
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 36),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Tooltip(
          message: '$tooltip · $label',
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1),
          ),
        ),
      ),
    ),
  );
}
