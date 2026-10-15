import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../services/notification_service.dart';
import '../utils/responsive.dart';

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

/// 定时关闭弹层：状态区（剩余时间 + 取消）+ 档位 chips（含自定义时长）+
/// 播完当前歌曲。开启后弹 Snackbar 反馈，自带「取消」操作。
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
            _buildStatusCard(context, l10n, timer, state),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                l10n.sleepTimerCountdownSection,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            const SizedBox(height: 12),
            _buildPresetChips(context, l10n, timer, state),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: M3EListItem(
                key: const Key('sleepTimerAfterTrackItem'),
                leading: const Icon(Icons.music_note_rounded),
                headline: l10n.sleepTimerAfterTrack,
                selected: state.mode == SleepTimerMode.afterCurrentTrack,
                enabled: canArmAfterTrack,
                onTap: canArmAfterTrack
                    ? () {
                        HapticFeedback.lightImpact();
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
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 状态区：未开启给说明；已开启给剩余时间 / 模式 + 「关闭定时」出口。
  Widget _buildStatusCard(
    BuildContext context,
    AppLocalizations l10n,
    SleepTimerController timer,
    SleepTimerState state,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = state.isActive;
    final countdown = state.mode == SleepTimerMode.countdown;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.bedtime_rounded,
            color: active ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: active && countdown
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        formatSleepTimerRemaining(
                            state.remaining ?? Duration.zero),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          l10n.sleepTimerHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(
                    active ? l10n.sleepTimerAfterTrack : l10n.sleepTimerHint,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
          ),
          if (active) ...[
            const SizedBox(width: 8),
            M3EButton.text(
              key: const Key('sleepTimerCancelButton'),
              onPressed: () {
                HapticFeedback.lightImpact();
                timer.cancel();
              },
              child: Text(l10n.sleepTimerCancel),
            ),
          ],
        ],
      ),
    );
  }

  /// 档位 chips：常用档位 + 自定义时长（M3E time picker）；当前档位有选中态。
  Widget _buildPresetChips(
    BuildContext context,
    AppLocalizations l10n,
    SleepTimerController timer,
    SleepTimerState state,
  ) {
    final armedMinutes =
        state.mode == SleepTimerMode.countdown ? state.duration?.inMinutes : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final minutes in kSleepTimerPresetMinutes)
            M3EChip(
              key: Key('sleepTimerPreset_$minutes'),
              type: M3EChipType.filter,
              label: l10n.sleepTimerMinutesShort(minutes),
              selected: armedMinutes == minutes,
              onPressed: () => _armCountdown(
                context,
                l10n,
                timer,
                Duration(minutes: minutes),
              ),
            ),
          M3EChip(
            key: const Key('sleepTimerCustomChip'),
            label: l10n.sleepTimerCustom,
            leading: const Icon(Icons.schedule_rounded, size: 18),
            onPressed: () =>
                unawaited(_pickCustomDuration(context, timer, state)),
          ),
        ],
      ),
    );
  }

  /// 开启倒计时 + 反馈 + 关闭弹层（列表 / chips 共用）。
  void _armCountdown(
    BuildContext context,
    AppLocalizations l10n,
    SleepTimerController timer,
    Duration duration,
  ) {
    HapticFeedback.lightImpact();
    timer.startCountdown(duration);
    _showArmedFeedback(
      context,
      timer,
      l10n.sleepTimerArmedSnackbar(formatSleepTimerRemaining(duration)),
    );
    Navigator.of(context).pop();
  }

  /// 自定义时长：M3E time picker（24 小时制 —— 小时 + 分钟即为时长）。
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
