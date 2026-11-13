/// 诊断页状态：把服务快照、健康检查与导出动作收成一个 ChangeNotifier。
///
/// provider 挂在根 Provider 树、与应用同生命周期；页面关闭不会释放它。
/// 服务本身由组合根持有，失败记录 / 文件日志在页面未打开时照常运行
/// （只有 provider 的监听通知存在，没有额外后台任务）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/diagnostics.dart';
import '../services/diagnostics/diagnostics_bundle.dart';
import '../services/diagnostics/diagnostics_export.dart';
import '../services/diagnostics/diagnostics_service.dart';
import '../services/save_as.dart';

class DiagnosticsProvider extends ChangeNotifier {
  DiagnosticsProvider({
    required this.service,
    required this.builder,
    required this.saveAs,
    Future<DiagnosticsAppInfo> Function()? appInfo,
  }) : _appInfoLoader = appInfo {
    _subscription = service.changes.listen((_) => notifyListeners());
  }

  final DiagnosticsService service;
  final DiagnosticsBundleBuilder builder;
  final SaveAs? saveAs;
  final Future<DiagnosticsAppInfo> Function()? _appInfoLoader;

  StreamSubscription<void>? _subscription;
  Future<DiagnosticsAppInfo>? _appInfoFuture;
  DiagnosticsAppInfo? appInfo;
  bool _exporting = false;

  List<DiagnosticFailureRecord> get failures => service.failures.records;

  List<HealthRun> get healthRuns => service.healthRuns;

  HealthRun? get currentHealthRun => service.currentHealthRun;

  bool get isChecking => service.isChecking;

  bool get canStartCheck => service.health?.canStart ?? false;

  bool get hasCheckableChannels => service.healthTargetCount > 0;

  DiagnosticLogStatus get logStatus => service.logStatus;

  bool get isExporting => _exporting;

  /// 打开页面时读一次包信息（无网络、无磁盘扫描）；失败不阻塞页面。
  void ensureAppInfo() {
    if (appInfo != null || _appInfoFuture != null) return;
    final loader = _appInfoLoader;
    if (loader == null) return;
    _appInfoFuture = loader()
        .then((value) {
          appInfo = value;
          notifyListeners();
          return value;
        })
        .catchError((Object _) {
          appInfo = const DiagnosticsAppInfo();
          notifyListeners();
          return appInfo!;
        });
  }

  /// 开始一轮手动检查；冷却中 / 已在跑时返回 false。
  Future<bool> startHealthCheck() => service.startHealthCheck();

  void stopHealthCheck() => service.stopHealthCheck();

  /// 准备并保存诊断包；取消静默，失败返回 [SaveAsFailed]（页面统一提示）。
  Future<SaveAsResult> export({
    String? dialogTitle,
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (_exporting) return const SaveAsFailed();
    final target = saveAs;
    if (target == null) return const SaveAsFailed();
    _exporting = true;
    notifyListeners();
    try {
      final bytes = await builder.buildBytes(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      );
      return await target.saveBytes(
        fileName: builder.suggestedFileName(),
        bytes: bytes,
        mimeType: 'text/plain',
        relativeDir: saveAsExportsDirName,
        dialogTitle: dialogTitle,
      );
    } catch (error) {
      return SaveAsFailed(error);
    } finally {
      _exporting = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
