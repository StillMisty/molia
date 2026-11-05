import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'simple_modal_body.dart';

/// 自定义时长范围（分钟）与滑杆步进。
const int kSleepTimerMinMinutes = 1;
const int kSleepTimerMaxMinutes = 120;
const int kSleepTimerStepMinutes = 5;
const int kSleepTimerDefaultMinutes = 30;

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

/// 选中时长展示：`30 分钟` / `1 小时` / `1 小时 30 分`。
String formatSleepTimerDuration(AppLocalizations l10n, int minutes) {
  final clamped = minutes.clamp(kSleepTimerMinMinutes, kSleepTimerMaxMinutes);
  if (clamped < 60) return l10n.sleepTimerDurationMinutes(clamped);
  final hours = clamped ~/ 60;
  final rest = clamped % 60;
  return rest == 0
      ? l10n.sleepTimerDurationHours(hours)
      : l10n.sleepTimerDurationHoursMinutes(hours, rest);
}

/// 滑杆吸附：最左端保留 1 分钟，其余按 [kSleepTimerStepMinutes] 取整。
int snapSleepTimerMinutes(double value) {
  final minutes = value.round();
  if (minutes <= 3) return kSleepTimerMinMinutes;
  final stepped =
      (minutes / kSleepTimerStepMinutes).round() * kSleepTimerStepMinutes;
  return stepped.clamp(kSleepTimerStepMinutes, kSleepTimerMaxMinutes);
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
    // 顶栏不再放关闭按钮：下滑 / 点遮罩 / 系统返回关闭。
    showCloseButton: false,
    child: _SleepTimerSheet(playback: playback),
  );
}

/// 定时关闭弹层：状态 + 时长滑杆 + 两个勾选 + 取消。
///
/// 时长为本地草稿：拖动只改显示，松手才写入控制器并开始倒计时。
class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet({required this.playback});

  final PlaybackProvider playback;

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  late int _minutes;

  @override
  void initState() {
    super.initState();
    final duration = widget.playback.sleepTimer.value.duration;
    _minutes = duration == null
        ? kSleepTimerDefaultMinutes
        : snapSleepTimerMinutes(duration.inMinutes.toDouble());
  }

  void _onSliderChanged(double value) {
    final next = snapSleepTimerMinutes(value);
    if (next == _minutes) return;
    HapticsService.selectionClick();
    setState(() => _minutes = next);
  }

  void _armCountdown(SleepTimerController timer) {
    HapticsService.lightImpact();
    timer.startCountdown(Duration(minutes: _minutes));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final timer = widget.playback.sleepTimer;

    return SimpleModalBody(
      // 移动端弹层叠在应用底栏之上，视口会比内容高度短一点；底部留一档避免
      // 最后一行按钮被裁掉下沿。
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
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _SleepTimerHeaderRow(state: state, minutes: _minutes),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: M3ESlider(
                  key: const Key('sleepTimerDurationSlider'),
                  value: _minutes.toDouble(),
                  min: kSleepTimerMinMinutes.toDouble(),
                  max: kSleepTimerMaxMinutes.toDouble(),
                  size: M3ESliderSize.xs,
                  trackThickness: 6,
                  label: formatSleepTimerDuration(l10n, _minutes),
                  semanticLabel: l10n.sleepTimerTitle,
                  semanticFormatterCallback: (_) =>
                      formatSleepTimerDuration(l10n, _minutes),
                  onChanged: _onSliderChanged,
                  onChangeEnd: (_) => _armCountdown(timer),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    timer.exitApp,
                    timer.waitForTrackEnd,
                  ]),
                  builder: (context, _) => _SleepTimerOptionsRow(
                    exitApp: timer.exitApp.value,
                    waitForTrackEnd: timer.waitForTrackEnd.value,
                    onExitAppChanged: (value) {
                      HapticsService.lightImpact();
                      timer.setExitApp(value);
                    },
                    onWaitForTrackEndChanged: (value) {
                      HapticsService.lightImpact();
                      timer.setWaitForTrackEnd(value);
                    },
                    l10n: l10n,
                  ),
                ),
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
}

/// 状态行：状态在左、已选时长在右；未开启时突出时长，倒计时时突出剩余。
class _SleepTimerHeaderRow extends StatelessWidget {
  const _SleepTimerHeaderRow({required this.state, required this.minutes});

  final SleepTimerState state;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = M3ETheme.of(context).colorScheme;
    final active = state.isActive;
    final primary = context.typeScale.headlineSmall;
    final secondary = context.typeScale.titleMedium;
    return Row(
      children: [
        Expanded(
          child: Text(
            sleepTimerStatusLabel(l10n, state),
            key: const Key('sleepTimerStatusText'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (active ? primary : secondary).copyWith(
              color: active ? scheme.onSurface : scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          formatSleepTimerDuration(l10n, minutes),
          key: const Key('sleepTimerDurationValue'),
          maxLines: 1,
          style: (active ? secondary : primary).copyWith(
            color: active ? scheme.onSurfaceVariant : scheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 两个勾选一左一右：退出应用 / 本曲播完再停。
class _SleepTimerOptionsRow extends StatelessWidget {
  const _SleepTimerOptionsRow({
    required this.exitApp,
    required this.waitForTrackEnd,
    required this.onExitAppChanged,
    required this.onWaitForTrackEndChanged,
    required this.l10n,
  });

  final bool exitApp;
  final bool waitForTrackEnd;
  final ValueChanged<bool> onExitAppChanged;
  final ValueChanged<bool> onWaitForTrackEndChanged;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final halfWidth = (MediaQuery.sizeOf(context).width - 40) / 2;
    final labelWidth = (halfWidth - 40).clamp(0.0, 220.0);
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _SleepTimerCheckbox(
              checkboxKey: const Key('sleepTimerExitAppCheckbox'),
              value: exitApp,
              onChanged: onExitAppChanged,
              label: l10n.sleepTimerExitApp,
              maxLabelWidth: labelWidth,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _SleepTimerCheckbox(
              checkboxKey: const Key('sleepTimerWaitForTrackCheckbox'),
              value: waitForTrackEnd,
              onChanged: onWaitForTrackEndChanged,
              label: l10n.sleepTimerWaitForTrack,
              maxLabelWidth: labelWidth,
            ),
          ),
        ),
      ],
    );
  }
}

/// 紧凑勾选：标题行已不再放勾选，正文并排时也需要更小的槽与标签间距。
class _SleepTimerCheckbox extends StatelessWidget {
  const _SleepTimerCheckbox({
    this.checkboxKey,
    required this.value,
    required this.onChanged,
    required this.label,
    required this.maxLabelWidth,
  });

  final Key? checkboxKey;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    return M3ETheme(
      data: theme.copyWith(
        checkboxTheme: theme.checkboxTheme.copyWith(
          boxSize: 20,
          hitSize: 40,
          targetSize: 40,
          labelGap: 0,
        ),
      ),
      child: M3ECheckbox(
        key: checkboxKey,
        value: value,
        onChanged: (next) {
          if (next == null) return;
          onChanged(next);
        },
        label: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxLabelWidth),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typeScale.bodyMedium,
          ),
        ),
      ),
    );
  }
}
