/// 异常退出标记：把「上次最后可见状态」写进设备本地设置。
///
/// 只记前台 / 后台 / 正常关闭、最后时间与版本，不记页面、曲目或账号。
/// 判定规则保持保守：只有上次停在 [DiagnosticSessionPhase.foreground] 才认为
/// 可能被系统或用户强制关闭；后台被系统回收不算异常。文案由 UI 层决定，
/// 这里不写用户可见文本。
library;

import 'package:logging/logging.dart';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../domain/models/diagnostics.dart';

final _logger = Logger('molia.diagnostics.session');

/// 读取 / 写入上一次进程状态，并生成本次 [DiagnosticSessionInfo]。
///
/// 所有存储失败只记日志：退出标记不值得打断启动或退出，也不应把异常抛给
/// 生命周期回调。
class DiagnosticSessionTracker {
  DiagnosticSessionTracker({
    DeviceSettings? settings,
    DateTime Function()? now,
    String Function()? version,
  }) : _settings = settings ?? DeviceSettings(),
       _now = now ?? DateTime.now,
       _version = version ?? (() => 'unknown');

  final DeviceSettings _settings;
  final DateTime Function() _now;
  final String Function() _version;

  DiagnosticSessionInfo? _info;
  Future<DiagnosticSessionInfo>? _startFuture;

  DiagnosticSessionInfo? get info => _info;

  /// 读取上次状态并生成本次信息，随后立刻写为前台。
  ///
  /// 幂等：重复调用返回同一次启动的结论，不会把「上次退出」改写成本次。
  Future<DiagnosticSessionInfo> start() => _startFuture ??= _start();

  Future<DiagnosticSessionInfo> _start() async {
    final stored = await _readState();
    final previousExitAt = stored.lastSeenAtMs <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(stored.lastSeenAtMs);
    final info = DiagnosticSessionInfo(
      startedAt: _now(),
      previousExitAt: previousExitAt,
      previousVersion: stored.version.isEmpty ? null : stored.version,
      previousAbnormalExit: stored.phase == DiagnosticSessionPhase.foreground,
    );
    _info = info;
    await _write(DiagnosticSessionPhase.foreground);
    return info;
  }

  Future<void> onResumed() => _write(DiagnosticSessionPhase.foreground);

  Future<void> onPaused() => _write(DiagnosticSessionPhase.background);

  Future<void> onHidden() => _write(DiagnosticSessionPhase.background);

  Future<void> onDetached() => _write(DiagnosticSessionPhase.closed);

  /// 明确走正常退出路径时调用（与 [onDetached] 等价，语义更清楚）。
  Future<void> markCleanExit() => _write(DiagnosticSessionPhase.closed);

  Future<DiagnosticSessionState> _readState() async {
    try {
      return await _settings.readJson(kDiagnosticSessionStateKey) ??
          kDefaultDiagnosticSessionState;
    } catch (error) {
      _logger.warning('读取上次退出状态失败，按正常退出处理: $error');
      return kDefaultDiagnosticSessionState;
    }
  }

  Future<void> _write(DiagnosticSessionPhase phase) async {
    try {
      await _settings.writeJson(kDiagnosticSessionStateKey, (
        phase: phase,
        lastSeenAtMs: _now().millisecondsSinceEpoch,
        version: _version(),
      ));
    } catch (error) {
      _logger.warning('写入退出状态失败（不阻塞生命周期）: $error');
    }
  }
}
