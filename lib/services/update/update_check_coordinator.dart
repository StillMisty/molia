/// 应用与音源更新的自动检查调度：启动时 / 每日各一次，发现更新后发一条
/// 合并提示。
///
/// 为什么独立于 `UpdateProvider`：provider 只编排「检查 → 下载 → 安装」的
/// 应用更新状态机；音源脚本检查、每日节流与弹窗去重是另一条横切流程，
/// 混进去会让状态机多出与本机安装无关的分支。这里只经 [UpdateCheckHooks]
/// 读偏好并触发检查，不感知 UI 或安装细节。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/app_release.dart';
import '../../domain/models/source_script.dart';
import '../../domain/models/update_check_notice.dart';

/// 调度器读取的外部状态与检查入口（组合根接到 `UpdateProvider` 与
/// `SourceManager`；测试直接给假实现）。
class UpdateCheckHooks {
  const UpdateCheckHooks({
    required this.checkOnStartup,
    required this.checkDaily,
    required this.lastCheckedAt,
    required this.checkApp,
    required this.checkSources,
    this.settingsListenable,
  });

  final bool Function() checkOnStartup;
  final bool Function() checkDaily;
  final DateTime? Function() lastCheckedAt;

  /// 静默检查应用更新；返回刚发现的发布，无更新 / 失败为 null。
  final Future<AppRelease?> Function() checkApp;

  /// 批量检查音源脚本；失败由实现自行吞掉或由调度器兜底。
  final Future<List<SourceScriptUpdate>> Function() checkSources;

  /// 偏好变化（开关 / 上次检查时间）触发重新排期。
  final Listenable? settingsListenable;
}

/// 自动检查调度器（每进程一个）。
class UpdateCheckCoordinator {
  UpdateCheckCoordinator({
    required this.hooks,
    DateTime Function()? now,
    this.dailyInterval = const Duration(hours: 24),
  }) : _now = now ?? DateTime.now;

  final UpdateCheckHooks hooks;
  final Duration dailyInterval;
  final DateTime Function() _now;

  /// 启动 / 每日检查发现更新后的待展示数据；UI 展示完置空。
  final ValueNotifier<UpdateCheckNotice?> notice = ValueNotifier(null);

  Timer? _dailyTimer;
  bool _started = false;
  bool _running = false;
  DateTime? _lastAttemptAt;

  /// 启动一次：按偏好决定立即检查（启动时 / 每日到期）并排下一次每日检查。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    hooks.settingsListenable?.addListener(_onSettingsChanged);
    final now = _now();
    if (hooks.checkOnStartup() || (hooks.checkDaily() && _isDailyDue(now))) {
      await runAutoCheck();
      return;
    }
    _scheduleDaily();
  }

  /// 回前台补一次到期检查；后台期间 Timer 可能被系统冻结。
  ///
  /// 不等待网络：生命周期扇出不应被一次更新检查拖住。
  Future<void> handleAppResumed() async {
    if (hooks.checkDaily() && _isDailyDue(_now())) {
      unawaited(runAutoCheck());
      return;
    }
    _scheduleDaily();
  }

  /// 跑一轮自动检查：应用与音源并行，任一失败不影响另一条链路。
  Future<void> runAutoCheck() async {
    if (_running) return;
    _running = true;
    _lastAttemptAt = _now();
    try {
      final appFuture = _checkAppSafely();
      final sourceFuture = _checkSourcesSafely();
      final appRelease = await appFuture;
      final sourceUpdates = await sourceFuture;
      if (appRelease != null || sourceUpdates.isNotEmpty) {
        notice.value = UpdateCheckNotice(
          appRelease: appRelease,
          sourceUpdates: sourceUpdates,
        );
      }
    } finally {
      _running = false;
      _scheduleDaily();
    }
  }

  /// 开关变化后重新排期（打开每日检查立即按到期时间排，关闭则取消）。
  void refreshSchedule() => _scheduleDaily();

  Future<AppRelease?> _checkAppSafely() async {
    try {
      return await hooks.checkApp();
    } catch (e) {
      debugPrint('[UpdateCheck] 应用更新检查失败: $e');
      return null;
    }
  }

  Future<List<SourceScriptUpdate>> _checkSourcesSafely() async {
    try {
      return await hooks.checkSources();
    } catch (e) {
      debugPrint('[UpdateCheck] 音源更新检查失败: $e');
      return const [];
    }
  }

  void _onSettingsChanged() => _scheduleDaily();

  bool _isDailyDue(DateTime now) {
    final base = _latestCheckAt();
    return base == null || now.difference(base) >= dailyInterval;
  }

  DateTime? _latestCheckAt() {
    final lastChecked = hooks.lastCheckedAt();
    final attempt = _lastAttemptAt;
    if (lastChecked == null) return attempt;
    if (attempt == null) return lastChecked;
    return lastChecked.isAfter(attempt) ? lastChecked : attempt;
  }

  void _scheduleDaily() {
    _dailyTimer?.cancel();
    if (!hooks.checkDaily()) return;
    final now = _now();
    final base = _latestCheckAt();
    final due = base == null ? now : base.add(dailyInterval);
    final delay = due.difference(now);
    _dailyTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(runAutoCheck());
    });
  }

  void dispose() {
    _dailyTimer?.cancel();
    hooks.settingsListenable?.removeListener(_onSettingsChanged);
    notice.dispose();
  }
}
