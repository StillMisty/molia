import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'simple_modal_body.dart';

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
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: AppLocalizations.of(context)!.sleepTimerTitle,
    // 标题右侧的「同时退出应用」勾选项：宽屏 M3EDialog 没有标题插槽，
    // 统一走底部抽屉，窄屏 / 宽屏保持同一套标题行。
    titleTrailing: _SleepTimerExitAppCheckbox(playback: playback),
    forceSheet: true,
    child: _SleepTimerSheet(playback: playback),
  );
}

/// 标题右侧勾选项：计时结束后是否同时退出应用。
///
/// 默认勾选、仅本次运行（不落盘）：退出应用是强动作，状态随进程结束而消失，
/// 下次启动仍回到默认勾选。
class _SleepTimerExitAppCheckbox extends StatelessWidget {
  const _SleepTimerExitAppCheckbox({required this.playback});

  final PlaybackProvider playback;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final timer = playback.sleepTimer;
    final theme = M3ETheme.of(context);
    // 默认 48 的触控槽 + 8 的标签间距，在标题行里会显得勾选框和文字分家。
    // 收成 40 槽、标签紧贴状态层；整行（含标签）仍是可点区域。
    return M3ETheme(
      data: theme.copyWith(
        checkboxTheme: theme.checkboxTheme.copyWith(
          boxSize: 20,
          hitSize: 40,
          targetSize: 40,
          labelGap: 0,
        ),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: timer.exitApp,
        builder: (context, checked, _) => M3ECheckbox(
          key: const Key('sleepTimerExitAppCheckbox'),
          value: checked,
          onChanged: (next) {
            if (next == null) return;
            HapticsService.lightImpact();
            timer.setExitApp(next);
          },
          // 标题行只有 64：标签限宽单行省略，英文 / 大字号下先牺牲文案，
          // 不挤压左侧「定时关闭」标题；极窄屏再收一档，保住标题完整。
          label: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.isCompact ? 96 : 132),
            child: Text(
              l10n.sleepTimerExitApp,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

/// 状态卡片：定时未开启 / 剩余倒计时 / 播完当前歌曲，作为正文的视觉锚点。
///
/// 倒计时数字用等宽数字，避免每秒刷新时宽度抖动；非倒计时模式文案较长，
/// 用较小字阶并允许两行。
class _SleepTimerStatusCard extends StatelessWidget {
  const _SleepTimerStatusCard({required this.state});

  final SleepTimerState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = M3ETheme.of(context).colorScheme;
    final countdown = state.mode == SleepTimerMode.countdown;
    final active = state.isActive;
    return M3ECard(
      key: const Key('sleepTimerStatusCard'),
      variant: M3ECardVariant.filled,
      focusable: false,
      showFocusRing: false,
      trackHover: false,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Icon(
            Icons.bedtime_rounded,
            color: active ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              sleepTimerStatusLabel(l10n, state),
              key: const Key('sleepTimerStatusText'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  (countdown
                          ? context.typeScale.headlineSmall
                          : context.typeScale.titleMedium)
                      .copyWith(
                        color: active
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontFeatures: countdown
                            ? const [FontFeature.tabularFigures()]
                            : null,
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 定时关闭弹层：状态 + 自定义时长入口 + 播完当前歌曲 + 关闭定时。
///
/// 时长只经 [M3ETimePicker] 设置，弹层保持单一决策路径，避免「档位选中态 /
/// 自定义 / 播完当前歌曲」三块并列。
class _SleepTimerSheet extends StatelessWidget {
  const _SleepTimerSheet({required this.playback});

  final PlaybackProvider playback;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final timer = playback.sleepTimer;
    final scheme = M3ETheme.of(context).colorScheme;
    // 恢复态（冷启动未起播）没有真实播放曲目：不能承诺「播完当前歌曲」。
    final canArmAfterTrack =
        !playback.hasRestoredSession && playback.snapshot.current != null;

    return SimpleModalBody(
      // 底部多留一档：移动端弹层叠在应用底栏之上，视口会比内容高度短一点；
      // 只留默认 8 时最后一行（「播完当前歌曲后暂停」）会被裁掉下沿。
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // 倒计时每秒通知：只重建内层内容，不连带重建外层滚动视图。
        ValueListenableBuilder<SleepTimerState>(
          valueListenable: timer,
          builder: (context, state, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: _SleepTimerStatusCard(state: state),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  l10n.sleepTimerModeSection,
                  key: const Key('sleepTimerModeSection'),
                  style: context.typeScale.titleSmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              M3EListItem(
                key: const Key('sleepTimerCustomItem'),
                leading: const Icon(Icons.schedule_rounded),
                headline: l10n.sleepTimerCustom,
                trailingText:
                    state.mode == SleepTimerMode.countdown &&
                        state.duration != null
                    ? formatSleepTimerRemaining(state.duration!)
                    : null,
                selected: state.mode == SleepTimerMode.countdown,
                onTap: () =>
                    unawaited(_pickCustomDuration(context, timer, state)),
              ),
              const M3EDivider(inset: M3EDividerInset.middle),
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
                          timer.exitApp.value
                              ? l10n.sleepTimerArmedAfterTrackExit
                              : l10n.sleepTimerArmedAfterTrack,
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
            ],
          ),
        ),
      ],
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
      // 显式用 M3E time pickers 的表盘入口（Material 原生 showTimePicker 与
      // 纯数字输入都不是本项目 UI 口径）。
      initialEntryMode: M3ETimePickerEntryMode.dial,
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
      context.read<NotificationService?>()?.showSnackBar(
        l10n.sleepTimerCustomInvalid,
      );
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
    final remaining = formatSleepTimerRemaining(duration);
    _showArmedFeedback(
      context,
      timer,
      timer.exitApp.value
          ? l10n.sleepTimerArmedExitSnackbar(remaining)
          : l10n.sleepTimerArmedSnackbar(remaining),
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
