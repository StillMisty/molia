import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../utils/responsive.dart';

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

/// 定时关闭状态文案（歌曲信息页行副标题 / 弹层状态区共用）。
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

/// 定时关闭弹层：状态 + 自定义时长入口 + 播完当前歌曲 + 关闭定时。
///
/// 不再提供预设档位 chips：时长只经 [M3ETimePicker] 设置，弹层保持单一
/// 决策路径，避免「档位选中态 / 自定义 / 播完当前歌曲」三块并列。
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text(
                sleepTimerStatusLabel(l10n, state),
                style: M3ETheme.of(context).typeScale.headlineSmall,
              ),
            ),
            M3EListItem(
              key: const Key('sleepTimerCustomItem'),
              leading: const Icon(Icons.schedule_rounded),
              headline: l10n.sleepTimerCustom,
              trailingText: state.mode == SleepTimerMode.countdown &&
                      state.duration != null
                  ? formatSleepTimerRemaining(state.duration!)
                  : null,
              selected: state.mode == SleepTimerMode.countdown,
              onTap: () =>
                  unawaited(_pickCustomDuration(context, timer, state)),
            ),
            M3EListItem(
              key: const Key('sleepTimerAfterTrackItem'),
              leading: const Icon(Icons.music_note_rounded),
              headline: l10n.sleepTimerAfterTrack,
              selected: state.mode == SleepTimerMode.afterCurrentTrack,
              enabled: canArmAfterTrack,
              onTap: canArmAfterTrack
                  ? () {
                      HapticsService.lightImpact();
                      timer.startAfterCurrentTrack();
                      _showArmedFeedback(
                        context,
                        timer,
                        l10n.sleepTimerArmedAfterTrack,
                      );
                      Navigator.of(context).pop();
                    }
                  : null,
            ),
            if (state.isActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: M3EButton.outlined(
                    key: const Key('sleepTimerCancelButton'),
                    size: M3EButtonSize.md,
                    onPressed: () {
                      HapticsService.lightImpact();
                      timer.cancel();
                      Navigator.of(context).pop();
                    },
                    child: Text(l10n.sleepTimerCancel),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 自定义时长：M3ETimePicker（24 小时制 —— 小时 + 分钟即为时长）。
  ///
  /// 1–600 分钟之外不开启并提示一次（picker 本身不做范围限制）。
  Future<void> _pickCustomDuration(
    BuildContext context,
    SleepTimerController timer,
    SleepTimerState state,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final initialMinutes = state.duration?.inMinutes ?? 30;
    final picked = await M3ETimePicker.show(
      context,
      initialTime: M3ETime(
        hour: initialMinutes ~/ 60,
        minute: initialMinutes % 60,
      ),
      alwaysUse24HourFormat: true,
      helpText: l10n.sleepTimerCustomTitle,
      hourLabelText: l10n.sleepTimerHourLabel,
      minuteLabelText: l10n.sleepTimerMinuteLabel,
      cancelText: l10n.cancel,
      confirmText: l10n.sleepTimerCustomConfirm,
    );
    if (picked == null || !context.mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    if (minutes < kSleepTimerMinMinutes || minutes > kSleepTimerMaxMinutes) {
      context
          .read<NotificationService?>()
          ?.showSnackBar(l10n.sleepTimerCustomInvalid);
      return;
    }
    _armCountdown(context, l10n, timer, Duration(minutes: minutes));
  }

  /// 开启倒计时 + 反馈 + 关闭弹层。
  void _armCountdown(
    BuildContext context,
    AppLocalizations l10n,
    SleepTimerController timer,
    Duration duration,
  ) {
    HapticsService.lightImpact();
    timer.startCountdown(duration);
    _showArmedFeedback(
      context,
      timer,
      l10n.sleepTimerArmedSnackbar(formatSleepTimerRemaining(duration)),
    );
    Navigator.of(context).pop();
  }

  /// 开启反馈：Snackbar（含「取消」操作，直接撤销定时）。
  void _showArmedFeedback(
    BuildContext context,
    SleepTimerController timer,
    String message,
  ) {
    context.read<NotificationService?>()?.showSnackBar(
          message,
          actionLabel: AppLocalizations.of(context)!.cancel,
          onActionPressed: timer.cancel,
        );
  }
}
