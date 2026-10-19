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
          : controller.hasUpdate
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
                            'Windows 0.1.19：关闭到托盘前暂停并保存进度，恢复窗口后保持暂停；更新超时先取消助手并确认退出，启动失败先确认新程序退出再回滚，无法确认时保留恢复文件；更新失败显示具体阶段和系统错误。完整包清除两个无用的上游调试 DLL，保留所需运行库和资源。保留追剧下季复用、跨季进度同步、全局弹幕设置、全季选集、迷你窗、托盘操作和静态正式更新清单。0.1.17 自带的旧更新助手不会自动获得这些修复，首次升级建议彻底退出旧程序，下载完整 ZIP 并解压到独立可写的新目录，不要混放旧 DLL 或只复制 EXE；同一 Windows 账户继续使用原应用数据。未签名；真实站源、长时间连播及旧版本原地替换仍未实测。',
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
