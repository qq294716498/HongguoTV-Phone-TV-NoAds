import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_layout.dart';

const projectRepositoryUrl =
    'https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds';
const projectOwner = 'qq294716498';
const projectFreeNotice = '本软件免费提供，仅供学习交流，请勿付费购买，谨防盗卖';
const originNoticeAcknowledgedKey = 'app_origin_notice_acknowledged_v1';

Future<void> openProjectRepository(BuildContext context) async {
  try {
    await AppDevice.channel.invokeMethod<void>('openProjectPage');
  } catch (_) {
    await Clipboard.setData(const ClipboardData(text: projectRepositoryUrl));
    if (context.mounted)
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('无法打开浏览器，仓库链接已复制')));
  }
}

class ProjectOrigin extends StatelessWidget {
  const ProjectOrigin({super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          ClipOval(
            child: Image.asset(
              'assets/app_identity/github-avatar.png',
              width: 48,
              height: 48,
              semanticLabel: '$projectOwner 的 GitHub 公开头像',
              errorBuilder: (_, _, _) => const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.person),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('维护仓库 · $projectOwner')),
        ],
      ),
      const SizedBox(height: 12),
      const Text(projectFreeNotice),
      const SizedBox(height: 8),
      const Text('软件来源为以下 GitHub 仓库。基于 guoapp 继续维护，保留上游作者、依赖作者的贡献及许可证。'),
      const SizedBox(height: 8),
      const SelectableText(projectRepositoryUrl),
      TextButton.icon(
        key: const ValueKey('open-project-repository'),
        onPressed: () => openProjectRepository(context),
        icon: const Icon(Icons.open_in_new_rounded),
        label: const Text('打开 GitHub 仓库'),
      ),
      const Text('上游：https://github.com/zhoufuweigg/guoapp'),
      const SizedBox(height: 8),
      const Text('请遵守内容版权与相关许可；学习用途不免除版权义务。'),
    ],
  );
}

class FirstLaunchNotice extends StatefulWidget {
  const FirstLaunchNotice({
    super.key,
    required this.preferences,
    required this.child,
  });
  final SharedPreferences preferences;
  final Widget child;
  @override
  State<FirstLaunchNotice> createState() => _FirstLaunchNoticeState();
}

class _FirstLaunchNoticeState extends State<FirstLaunchNotice> {
  late bool _accepted =
      widget.preferences.getBool(originNoticeAcknowledgedKey) == true;
  bool _busy = false;
  String? _error;
  Future<void> _acknowledge() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await widget.preferences.setBool(originNoticeAcknowledgedKey, true))
        throw StateError('save failed');
      if (mounted) setState(() => _accepted = true);
    } catch (_) {
      await widget.preferences.reload().catchError((Object _) {});
      if (mounted) setState(() => _error = '确认状态保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _accepted
      ? widget.child
      : PopScope(
          canPop: false,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '欢迎使用$appName',
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 20),
                              const ProjectOrigin(),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_error != null)
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            FilledButton(
                              key: const ValueKey('acknowledge-project-origin'),
                              autofocus: true,
                              onPressed: _busy ? null : _acknowledge,
                              child: Text(_busy ? '正在保存…' : '我知道了'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
}
