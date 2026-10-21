import 'package:flutter/material.dart';

import 'models.dart';

class WindowsDramaDescription extends StatefulWidget {
  const WindowsDramaDescription({super.key, required this.drama});
  final Drama drama;

  @override
  State<WindowsDramaDescription> createState() =>
      _WindowsDramaDescriptionState();
}

class _WindowsDramaDescriptionState extends State<WindowsDramaDescription> {
  final _scroll = ScrollController();
  bool _expanded = false;

  @override
  void didUpdateWidget(WindowsDramaDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.description != widget.drama.description) {
      _expanded = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final description = widget.drama.description.trim();
    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
            child: Row(
              children: [
                const Expanded(child: Text('剧情介绍')),
                if (description.isNotEmpty)
                  TextButton(
                    key: const ValueKey('windows-description-expand'),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? '收起' : '展开全部'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                key: const ValueKey('windows-description-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.drama.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        description.isEmpty ? '暂无剧情介绍' : description,
                        key: const ValueKey('windows-description-text'),
                        maxLines: _expanded ? null : 8,
                        overflow: _expanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(color: colors.onSurface, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
