import 'package:flutter/material.dart';
import 'watch_reminder_models.dart';

class WatchReminderSettings extends StatelessWidget {
  const WatchReminderSettings({
    super.key,
    required this.preferences,
    required this.onChanged,
    this.busy = false,
  });
  final WatchReminderPreferences preferences;
  final Future<void> Function(WatchReminderPreferences) onChanged;
  final bool busy;

  Future<void> _number(
    BuildContext context, {
    required String title,
    required String initial,
    required bool hours,
    required Future<void> Function(int) save,
  }) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) =>
          _ReminderNumberDialog(title: title, initial: initial, hours: hours),
    );
    if (result != null && context.mounted) await save(result);
  }

  @override
  Widget build(BuildContext context) {
    final bedtime = TimeOfDay(
      hour: preferences.bedtimeMinute ~/ 60,
      minute: preferences.bedtimeMinute % 60,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('观看提醒（仅手机播放页）'),
        SwitchListTile.adaptive(
          key: const ValueKey('reminder-daily-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('每日观看时长提醒'),
          subtitle: const Text('仅累计实际播放时间；暂停、缓冲和后台不累计'),
          value: preferences.dailyEnabled,
          onChanged: busy
              ? null
              : (value) => onChanged(preferences.copyWith(dailyEnabled: value)),
        ),
        ListTile(
          key: const ValueKey('reminder-daily-limit'),
          contentPadding: EdgeInsets.zero,
          title: const Text('每天观看上限'),
          subtitle: Text(
            '${(preferences.dailyLimitMinutes / 60).toStringAsFixed(2)} 小时',
          ),
          onTap: busy
              ? null
              : () => _number(
                  context,
                  title: '每日观看时长',
                  initial: '${preferences.dailyLimitMinutes / 60}',
                  hours: true,
                  save: (value) =>
                      onChanged(preferences.copyWith(dailyLimitMinutes: value)),
                ),
        ),
        ListTile(
          key: const ValueKey('reminder-daily-repeat'),
          contentPadding: EdgeInsets.zero,
          title: Text('时长提醒间隔：${preferences.dailyRepeatMinutes} 分钟'),
          onTap: busy
              ? null
              : () => _number(
                  context,
                  title: '时长提醒间隔',
                  initial: '${preferences.dailyRepeatMinutes}',
                  hours: false,
                  save: (value) => onChanged(
                    preferences.copyWith(dailyRepeatMinutes: value),
                  ),
                ),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('reminder-bedtime-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('每日睡觉时间提醒'),
          subtitle: const Text('触发后持续提醒；关闭功能或重新打开应用间隔超过4小时后解除上一轮'),
          value: preferences.bedtimeEnabled,
          onChanged: busy
              ? null
              : (value) =>
                    onChanged(preferences.copyWith(bedtimeEnabled: value)),
        ),
        ListTile(
          key: const ValueKey('reminder-bedtime-time'),
          contentPadding: EdgeInsets.zero,
          title: const Text('睡觉时间（设备当地时间）'),
          subtitle: Text(
            '${bedtime.hour.toString().padLeft(2, '0')}:${bedtime.minute.toString().padLeft(2, '0')}',
          ),
          onTap: busy
              ? null
              : () async {
                  final value = await showTimePicker(
                    context: context,
                    initialTime: bedtime,
                    initialEntryMode: TimePickerEntryMode.input,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(alwaysUse24HourFormat: true),
                      child: child!,
                    ),
                  );
                  if (value != null && context.mounted) {
                    await onChanged(
                      preferences.copyWith(
                        bedtimeMinute: value.hour * 60 + value.minute,
                      ),
                    );
                  }
                },
        ),
        ListTile(
          key: const ValueKey('reminder-bedtime-repeat'),
          contentPadding: EdgeInsets.zero,
          title: Text('睡觉提醒间隔：${preferences.bedtimeRepeatMinutes} 分钟'),
          onTap: busy
              ? null
              : () => _number(
                  context,
                  title: '睡觉提醒间隔',
                  initial: '${preferences.bedtimeRepeatMinutes}',
                  hours: false,
                  save: (value) => onChanged(
                    preferences.copyWith(bedtimeRepeatMinutes: value),
                  ),
                ),
        ),
        const Text(
          '两项独立开关，默认关闭。弹窗不会叠加；点“知道了”后重新计算提醒间隔。每天本地00:00重置观看累计，重新打开应用不会清零。\nAndroid强制关闭的确切时间无法可靠获知，间隔按最近活跃记录估算；普通切到后台不会解除。',
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _ReminderNumberDialog extends StatefulWidget {
  const _ReminderNumberDialog({
    required this.title,
    required this.initial,
    required this.hours,
  });
  final String title;
  final String initial;
  final bool hours;
  @override
  State<_ReminderNumberDialog> createState() => _ReminderNumberDialogState();
}

class _ReminderNumberDialogState extends State<_ReminderNumberDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('reminder-number-input'),
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.hours ? '小时（约0.02–24，精确到分钟）' : '分钟（1–120）',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final number = double.tryParse(_controller.text.trim());
          if (number == null ||
              !number.isFinite ||
              number <= 0 ||
              number > (widget.hours ? 24 : 120) ||
              !widget.hours && number != number.roundToDouble() ||
              widget.hours && (number * 60).round() < 1) {
            setState(
              () => _error = widget.hours ? '请输入1分钟至24小时的时长' : '请输入1至120之间的整数',
            );
            return;
          }
          Navigator.pop(
            context,
            widget.hours ? (number * 60).round() : number.round(),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}
