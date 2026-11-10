import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'follow_updates.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'television_search_field.dart';
import 'widgets.dart';

class TelevisionSavedHeader extends StatelessWidget {
  const TelevisionSavedHeader({
    super.key,
    required this.count,
    required this.search,
    required this.onChanged,
    required this.onClear,
    required this.updates,
    required this.onRefresh,
    this.resume,
    this.onContinue,
  });

  final int count;
  final TextEditingController search;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final FollowUpdates updates;
  final VoidCallback onRefresh;
  final WatchEntry? resume;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final status = updates.checking
          ? '正在检查下季 · ${updates.checked}/${updates.total}'
          : updates.failed > 0
          ? '部分追剧暂未完成检查，可重试'
          : '进入追剧时检查下季，点卡片继续最近观看';
      final statusLabel = Tooltip(
        message: status,
        child: Text(
          status,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 14),
        ),
      );
      final watched = resume;
      return Column(
        key: const ValueKey('tv-follow-header'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
            child: Row(
              children: [
                Flexible(
                  flex: 2,
                  child: Text(
                    '我的追剧 · $count',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: TelevisionSearchField(
                    key: const ValueKey('favorites-search'),
                    controller: search,
                    onChanged: onChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索追剧',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空搜索',
                              onPressed: onClear,
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('follow-check-updates'),
                    tooltip: '检查下季 · $status',
                    onPressed: updates.checking ? null : onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ],
            ),
          ),
          if (watched != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: RemoteTarget(
                        key: const ValueKey('continue-watching'),
                        label:
                            '继续观看 · ${watched.drama.title}，第 ${watched.episode} 集，${formatPosition(watched.position)}',
                        onPressed: onContinue,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 34),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.play_circle_outline, size: 22),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '继续观看 · ${watched.drama.title}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '第 ${watched.episode} 集 · ${formatPosition(watched.position)}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: statusLabel),
                ],
              ),
            )
          else if (count > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(alignment: Alignment.centerLeft, child: statusLabel),
            ),
        ],
      );
    },
  );
}

class TelevisionSavedTile extends StatelessWidget {
  const TelevisionSavedTile({
    super.key,
    required this.drama,
    required this.repository,
    required this.onTap,
    required this.onMore,
    required this.subtitle,
    required this.actions,
    this.focusNode,
    this.onFocus,
    this.badge,
    this.hasNextSeason = false,
    this.showEpisodeCount = true,
  });

  final Drama drama;
  final AppRepository repository;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final String subtitle;
  final Widget actions;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final String? badge;
  final bool hasNextSeason;
  final bool showEpisodeCount;

  static double extentFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = (scaler.scale(17) * 1.3).ceilToDouble() * 2;
    final subtitle = (scaler.scale(14) * 1.3).ceilToDouble() * 2;
    return math.max(108, title + 6 + subtitle) + 26;
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.contextMenu): onMore},
    child: RemoteTarget(
      focusNode: focusNode,
      onFocus: onFocus,
      onPressed: onTap,
      label: '${drama.title}，${drama.episodes}集，${badge ?? ''}，$subtitle',
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 108,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DramaCover(
                    drama: drama,
                    repository: repository,
                    showMetadata: false,
                  ),
                  if (badge == '没找到下季')
                    const Positioned(
                      top: 4,
                      left: 4,
                      right: 4,
                      child: SeasonNotFoundBadge(),
                    ),
                  Positioned(
                    top: badge == '没找到下季' ? null : 0,
                    bottom: badge == '没找到下季' ? 0 : null,
                    right: 0,
                    child: actions,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text.rich(
                    TextSpan(
                      children: [
                        if (badge != null && badge != '没找到下季')
                          TextSpan(
                            text: '$badge · ',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: hasNextSeason
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ),
                        if (drama.vip)
                          const TextSpan(
                            text: 'VIP · ',
                            style: TextStyle(
                              color: Color(0xFFF6C86B),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (showEpisodeCount && drama.episodes > 0)
                          TextSpan(text: '共 ${drama.episodes} 集 · '),
                        TextSpan(text: subtitle),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
