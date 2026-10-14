import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../utils/responsive.dart';
import 'settings/settings_tiles.dart';

/// 常用档位（分钟）：与 LX Music 的定时关闭档位一致。
const List<int> kSleepTimerPresetMinutes = [15, 30, 45, 60, 90, 120];

/// 自定义时长范围（分钟）。
const int kSleepTimerMinMinutes = 1;
const int kSleepTimerMaxMinutes = 600;

/// 剩余时长展示：`mm:ss`，超过 1 小时带小时位（`h:mm:ss`）。
String formatSleepTimerRemaining(Duration remaining) {
  final total = remaining.isNegative ? Duration.zero : remaining;
  String two(int value) => value.toString().padLeft(2, '0');
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  return total.inHours > 0
      ? '${total.inHours}:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// 定时关闭状态文案（歌曲信息页行副标题 / 弹层状态行共用）。
String sleepTimerStatusLabel(AppLocalizations l10n, SleepTimerState state) {
  return switch (state.mode) {
    SleepTimerMode.off => l10n.sleepTimerOff,
    SleepTimerMode.afterCurrentTrack => l10n.sleepTimerAfterTrack,
    SleepTimerMode.countdown => l10n.sleepTimerRemaining(
        formatSleepTimerRemaining(state.remaining ?? Duration.zero),
      ),
  };
}

/// 打开定时关闭弹层（歌曲信息页唯一入口）。
Future<void> showSleepTimerSheet(BuildContext context) {
  final playback = context.read<PlaybackProvider>();
  return ResponsiveNavigation.showAdaptiveModalPage<void>(
    context: context,
    title: AppLocalizations.of(context)!.sleepTimerTitle,
    child: _SleepTimerSheet(playback: playback),
  );
}

/// 定时关闭弹层：状态行 + 关闭定时 / 播完当前歌曲 / 档位 / 自定义。
class _SleepTimerSheet extends StatelessWidget {
  const _SleepTimerSheet({required this.playback});

  final PlaybackProvider playback;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final timer = playback.sleepTimer;
    // 恢复态（冷启动未起播）没有真实播放曲目：不能承诺「播完当前歌曲」。
    final canArmAfterTrack =
        !playback.hasRestoredSession && playback.snapshot.current != null;

    return SingleChildScrollView(
      child: ValueListenableBuilder<SleepTimerState>(
        valueListenable: timer,
        builder: (context, state, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Text(
                // 未开启时说明到点行为；已开启时给出当前状态（剩余时间每秒刷新）。
                state.mode == SleepTimerMode.off
                    ? l10n.sleepTimerHint
                    : sleepTimerStatusLabel(l10n, state),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            if (state.isActive)
              M3EListItem(
                leading: const Icon(Icons.timer_off_rounded),
                headline: l10n.sleepTimerCancel,
                onTap: () {
                  timer.cancel();
                  Navigator.of(context).pop();
                },
              ),
            M3EListItem(
              leading: const Icon(Icons.music_note_rounded),
              headline: l10n.sleepTimerAfterTrack,
              selected: state.mode == SleepTimerMode.afterCurrentTrack,
              enabled: canArmAfterTrack,
              onTap: canArmAfterTrack
                  ? () {
                      timer.startAfterCurrentTrack();
                      Navigator.of(context).pop();
                    }
                  : null,
            ),
            for (final minutes in kSleepTimerPresetMinutes)
              M3EListItem(
                leading: const Icon(Icons.schedule_rounded),
                headline: l10n.sleepTimerMinutes(minutes),
                onTap: () {
                  timer.startCountdown(Duration(minutes: minutes));
                  Navigator.of(context).pop();
                },
              ),
            M3EListItem(
              leading: const Icon(Icons.edit_rounded),
              headline: l10n.sleepTimerCustom,
              onTap: () => _promptCustomDuration(context, timer),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 自定义时长：数字输入弹窗，1–600 分钟；非法时确认键禁用并给出错误文案。
  Future<void> _promptCustomDuration(
    BuildContext context,
    SleepTimerController timer,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义），关闭要显式定向。
    final dialogNavigator = Navigator.of(context, rootNavigator: true);

    int? parsedMinutes() {
      final value = int.tryParse(controller.text.trim());
      if (value == null ||
          value < kSleepTimerMinMinutes ||
          value > kSleepTimerMaxMinutes) {
        return null;
      }
      return value;
    }

    final minutes = await M3EDialog.show<int>(
      context,
      dialog: StatefulBuilder(
        builder: (context, setDialogState) {
          final minutes = parsedMinutes();
          return M3EDialog(
            title: l10n.sleepTimerCustomTitle,
            content: SizedBox(
              width: settingsDialogWidth(context),
              child: M3ETextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 3,
                placeholder: l10n.sleepTimerCustomHint,
                errorText: controller.text.isEmpty || minutes != null
                    ? null
                    : l10n.sleepTimerCustomInvalid,
                onChanged: (_) => setDialogState(() {}),
                onSubmitted: (_) {
                  if (minutes != null) dialogNavigator.pop(minutes);
                },
              ),
            ),
            actions: [
              M3EButton.text(
                onPressed: () => dialogNavigator.pop(),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                enabled: minutes != null,
                onPressed: () => dialogNavigator.pop(minutes),
                child: Text(l10n.sleepTimerCustomConfirm),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (minutes == null) return;
    timer.startCountdown(Duration(minutes: minutes));
    if (context.mounted) Navigator.of(context).pop();
  }
}
