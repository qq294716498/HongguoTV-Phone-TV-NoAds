import 'dart:async';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'app_updates.dart';

void openAppUpdates(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const AppUpdateScreen()));
}

class AppUpdateTile extends StatelessWidget {
  const AppUpdateTile({super.key, this.updates});
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) {
    final controller = updates ?? AppUpdates.current;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListTile(
        key: const ValueKey('app-update-setting'),
        leading: const Icon(Icons.system_update_rounded),
        title: Text(
          controller.hasUpdate
              ? '软件更新 · 发现 ${controller.release!.version}'
              : '软件更新',
        ),
        subtitle: Text(
          controller.installationFailure ?? controller.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => openAppUpdates(context),
      ),
    );
  }
}

class AppUpdateIndicator extends StatelessWidget {
  const AppUpdateIndicator({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = AppUpdates.current;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => controller.installationFailure != null
          ? IconButton(
              tooltip: '上次 Windows 更新未完成，查看恢复记录',
              onPressed: () => openAppUpdates(context),
              icon: const Icon(Icons.warning_amber_rounded),
            )
          : controller.showAutomaticPrompt
          ? IconButton(
              tooltip: '发现新版本 ${controller.release!.version}',
              onPressed: () => openAppUpdates(context),
              icon: const Badge(child: Icon(Icons.system_update_rounded)),
            )
          : const SizedBox.shrink(),
    );
  }
}

class AppUpdateScreen extends StatelessWidget {
  const AppUpdateScreen({super.key, this.updates});
  final AppUpdates? updates;

  @override
  Widget build(BuildContext context) {
    final controller = updates ?? AppUpdates.current;
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('软件更新')),
        body: const Center(child: Text('应用内安装更新目前支持 Android 手机与电视。')),
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final release = controller.release;
        final stage = controller.stage;
        final downloadBusy =
            stage == UpdateStage.downloading || stage == UpdateStage.validating;
        return Scaffold(
          appBar: AppBar(title: const Text('软件更新')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    '红果TV',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '当前版本：${controller.installedApp?.version ?? AppLayout.versionOf(context)}'
                    '${controller.installedApp == null ? '' : ' · ${controller.installedApp!.abi} · ${controller.installedApp!.code}'}',
                  ),
                  if (controller.windows)
                    const ExpansionTile(
                      title: Text('当前版本更新日志'),
                      children: [
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '0.1.23+48 更新：红果播放模型接口遇到零字节空响应时，最多增加一次短退避重试，仍服从原时限、取消和 Retry-After，不改变设备身份。Windows 同一账户下跨目录共用一个新版实例，再次启动唤醒托盘或最小化窗口并保持暂停；旧 EXE 无法追溯补上启动检查。更新交接发生实例冲突时保护用户配置。保留 0.1.22 的取源时限与取消、迟到结果隔离、预加载失败恢复、冷却提示、全屏及迷你窗、剧情简介、当前集与本季数量、跳过版本和弹幕表情改进。Windows 完整包仍未签名；上游偶发空响应的全部原因、真实站源长时间连播、消费级 GPU、多显示器混合 DPI 及用户旧版原地替换未实测。请先从托盘彻底退出旧程序，再将完整 ZIP 解压到独立可写的新目录，勿混放旧 DLL 或只复制 EXE；同一 Windows 账户保留原应用数据。',
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Text(
                    controller.message,
                    key: const ValueKey('app-update-status'),
                  ),
                  if (controller.installationFailure case final failure?) ...[
                    const SizedBox(height: 12),
                    Text(
                      '上次 Windows 更新未完成',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    SelectableText(
                      failure,
                      key: const ValueKey('app-update-installation-failure'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        autofocus: true,
                        key: const ValueKey('check-app-update'),
                        onPressed:
                            !controller.supportedEdition ||
                                controller.busy ||
                                stage == UpdateStage.permission
                            ? null
                            : () => unawaited(controller.check(manual: true)),
                        icon: const Icon(Icons.refresh),
                        label: const Text('检查更新'),
                      ),
                      if (controller.supportedEdition &&
                          release != null &&
                          !controller.busy &&
                          stage != UpdateStage.permission &&
                          stage != UpdateStage.ready)
                        FilledButton.icon(
                          key: const ValueKey('download-app-update'),
                          onPressed: () => unawaited(controller.download()),
                          icon: const Icon(Icons.download),
                          label: Text(
                            stage == UpdateStage.failed ? '重新下载' : '下载更新',
                          ),
                        ),
                      if (downloadBusy)
                        OutlinedButton(
                          key: const ValueKey('cancel-app-update'),
                          onPressed: controller.cancelDownload,
                          child: const Text('取消下载'),
                        ),
                      if (controller.supportedEdition &&
                          release != null &&
                          !controller.busy &&
                          stage != UpdateStage.permission)
                        OutlinedButton.icon(
                          key: const ValueKey('skip-app-update'),
                          onPressed: controller.currentVersionSkipped
                              ? null
                              : () =>
                                    unawaited(controller.skipCurrentVersion()),
                          icon: const Icon(Icons.notifications_off_outlined),
                          label: Text(
                            controller.currentVersionSkipped
                                ? '已跳过此版本自动提示'
                                : '跳过此版本',
                          ),
                        ),
                      if (controller.supportedEdition &&
                          stage == UpdateStage.ready)
                        FilledButton.icon(
                          key: const ValueKey('install-app-update'),
                          onPressed: () => unawaited(controller.install()),
                          icon: Icon(
                            controller.windows
                                ? Icons.restart_alt
                                : Icons.install_mobile,
                          ),
                          label: Text(controller.windows ? '安装并重启' : '安装更新'),
                        ),
                      if (stage == UpdateStage.permission) ...[
                        FilledButton(
                          key: const ValueKey('allow-app-update'),
                          onPressed: () =>
                              unawaited(controller.openPermission()),
                          child: const Text('前往系统设置'),
                        ),
                        OutlinedButton(
                          onPressed: controller.cancelPermission,
                          child: const Text('暂不设置'),
                        ),
                      ],
                    ],
                  ),
                  if (controller.busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: stage == UpdateStage.downloading && release != null
                          ? (controller.downloaded / release.bytes).clamp(
                              0.0,
                              1.0,
                            )
                          : null,
                    ),
                    if (stage == UpdateStage.downloading && release != null)
                      Text(
                        '${(controller.downloaded / 1048576).toStringAsFixed(1)} / ${(release.bytes / 1048576).toStringAsFixed(1)} MB',
                      ),
                  ],
                  if (release != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      '新版本 ${release.version}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${release.abi} · ${(release.bytes / 1048576).toStringAsFixed(1)} MB · 版本编号 ${release.code}',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      release.notes,
                      key: const ValueKey('app-update-notes'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      controller.windows ? '自动检查 Windows 正式版本' : '自动检查稳定版本',
                    ),
                    subtitle: const Text('常规每 12 小时检查一次，失败稍后重试；不会自动下载或打断播放'),
                    value: controller.automatic,
                    onChanged: controller.supportedEdition
                        ? (value) => unawaited(controller.setAutomatic(value))
                        : null,
                  ),
                  Text(
                    controller.windows
                        ? 'Windows 正式版未签名。点击安装并重启后自动校验、解压和替换完整程序目录，启动失败回滚旧版。播放中请先暂停；观看进度与配置会保存。旧版与配置备份保留在更新事务中。目录只读、占用或包含额外文件时将停止更新，不申请管理员权限。'
                        : '下载来自本项目的 GitHub Release。验证完成后，需要你确认安装；安装时请先保存或结束当前播放。返回此页可重试，观看记录不会因取消而删除。',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    controller.windows ? windowsUpdatePage : updatePage,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
