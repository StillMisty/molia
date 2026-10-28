/// 下载通知 presenter 模块：把下载生命周期（起任务 / 进批量 / 进度 / 收尾）
/// 翻译成系统下载通知的 start / update / stop。
///
/// 为什么独立成模块：通知生命周期有自己的状态（id 分配、批量上下文、节流表、
/// 已起通知集合），编排只报事件（起 / 进 / 进度 / 收），
/// 「一条下载一条通知、批量共享一条 `N/N`、系统频率节流 500ms、收尾只收自己
/// 起过的」全部由本模块拥有；端口（[DownloadNotifications]）/ 设置 / 时钟都可
/// 注入，编排与其测试不依赖 Android。
///
/// 边界：只表达通知——不感知下载文件、记录与失败语义；通知是纯附加面
/// （通道缺失 / 权限未授予 / 原生失败一律 no-op 只记日志），下载本身不变。
library;

import 'dart:async';

import '../../data/downloads/download_notifications.dart';
import '../../domain/models/track.dart';
import 'download_settings.dart';

/// 下载通知 presenter（`DownloadService` 持有；每进程一个）。
class DownloadNotificationPresenter {
  /// [_settings] 的通知开关与端口能力共同决定是否发通知（每次事件即时读取，
  /// 改设置无需重建）；[clock] 供系统频率节流（与下载时间无关）。
  DownloadNotificationPresenter({
    required this._notifications,
    this._settings,
    int Function()? clock,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final DownloadNotifications _notifications;
  final DownloadSettings? _settings;
  final int Function() _clock;

  /// 批量通知 id：整批共享一条「N/N」通知。
  static const String _batchId = 'batch';

  /// 通知进度节流间隔：系统对通知更新有频率限制（前台服务通知尤其），进度按
  /// 「首个分片 / 距上次 ≥500ms / 已到最后一个分片」推送；UI 进度不受影响。
  static const int _intervalMs = 500;

  /// 通知最近推送时间（键 = 通知 id），只服务节流。
  final Map<String, int> _sentAt = {};

  /// 已起过通知的 id：收尾只收自己起过的，中途关掉开关也不会残留。
  final Set<String> _started = {};

  /// 批量通知状态（`_batchRunning` = 有批量在跑；服务端只有一个批量 id）。
  bool _batchRunning = false;
  bool _batchStarted = false;
  int _batchTotal = 0;
  String? _batchActiveKey;

  /// 当前平台是否支持系统下载通知（仅 Android；UI 据此显隐设置开关）。
  bool get supported => _notifications.supported;

  /// 通知是否生效：平台支持且设置开启（默认开）。
  bool get _enabled =>
      _notifications.supported && (_settings?.notifications ?? true);

  /// 单任务通知 id：一条下载一条通知，收尾时按同一 id 移除。
  static String _taskId(String key) => 'track:$key';

  // ── 单任务 ─────────────────────────────────────────────

  /// 起单任务通知（批量中的当前曲目由批量通知统一表达，避免 N 条通知连闪）。
  void startTask(String key, Track track) {
    if (!_enabled) return;
    if (_batchActiveKey == key) return;
    final id = _taskId(key);
    _sentAt.remove(id);
    _started.add(id);
    unawaited(_notifications.start(
      id: id,
      title: track.title,
      subtitle: track.artistLabel,
    ));
  }

  /// 收单任务通知（完成 / 失败 / 取消同一条路径：收尾并移除）。
  ///
  /// 不受「通知开关」影响：只收自己起过的，中途关掉开关也不残留。
  void stopTask(String key) {
    if (_batchActiveKey == key) return;
    final id = _taskId(key);
    _sentAt.remove(id);
    if (!_started.remove(id)) return;
    unawaited(_notifications.stop(id));
  }

  // ── 批量 ───────────────────────────────────────────────

  /// 开始批量：返回 true 表示本批起了「N/N」通知。
  ///
  /// false = 开关关闭 / 平台不支持 / 空批量 / 已有批量在跑（并发调用不抢占：
  /// 服务端只有一个批量 id）。返回 true 后必须配对 [endBatch]。
  bool beginBatch(int total) {
    if (!_enabled || total <= 0 || _batchRunning) return false;
    _batchRunning = true;
    _batchStarted = false;
    _batchTotal = total;
    _batchActiveKey = null;
    return true;
  }

  /// 批量进入下一首：[start] 建立通知，其余用 update 顺延序号与进度条。
  ///
  /// [index] 从 1 起（跳过项也占位：序号 = 曲目在入参里的位置）；[key] 供
  /// 批内单任务通知按它抑制。
  void enterBatch({
    required int index,
    required String key,
    required Track track,
  }) {
    if (!_batchRunning) return;
    _batchActiveKey = key;
    final id = _batchId;
    _sentAt.remove(id);
    _started.add(id);
    if (_batchStarted) {
      unawaited(_notifications.update(
        id: id,
        title: track.title,
        subtitle: track.artistLabel,
        index: index,
        total: _batchTotal,
        // max 传 0：新任务总大小未知，进度条回到不确定态。
        progress: 0,
        max: 0,
      ));
    } else {
      unawaited(_notifications.start(
        id: id,
        title: track.title,
        subtitle: track.artistLabel,
        index: index,
        total: _batchTotal,
      ));
      _batchStarted = true;
    }
  }

  /// 批量结束：移除批量通知（批内单任务通知本来就没起过）。
  ///
  /// 同 [stopTask]：收尾不受「通知开关」影响。
  void endBatch() {
    _sentAt.remove(_batchId);
    if (_started.remove(_batchId)) unawaited(_notifications.stop(_batchId));
    _batchRunning = false;
    _batchStarted = false;
    _batchActiveKey = null;
  }

  // ── 进度 ───────────────────────────────────────────────

  /// 进度 → 通知（单任务或批量：按「当前曲目是否属于批量」路由）。
  ///
  /// 未起过 / 已收尾的 id 由端口 / 原生侧忽略（收尾后迟到的进度不复活通知）。
  void reportProgress(String key, int received, int? total) {
    if (!_enabled) return;
    final id = _batchActiveKey == key ? _batchId : _taskId(key);
    final now = _clock();
    final last = _sentAt[id];
    final complete = total != null && total > 0 && received >= total;
    if (last != null && !complete && now - last < _intervalMs) return;
    _sentAt[id] = now;
    unawaited(_notifications.update(id: id, progress: received, max: total));
  }
}
