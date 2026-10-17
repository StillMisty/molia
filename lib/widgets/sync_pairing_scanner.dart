import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../services/play_services_availability.dart';
import '../theme/app_semantic_colors.dart';

/// 扫码能力的平台判定 + 扫码页入口。
///
/// 入口可用性 = 平台支持 × 运行环境可用（[isAvailable]）：
/// - 平台：只支持 Android / iOS（mobile_scanner 的移动实现），桌面三平台
///   不构建扫码入口，只给「粘贴配对码」；
/// - 运行环境：Android 走 **unbundled** ML Kit（识别模型由 Play 服务下载），
///   没有 GMS（AOSP / 部分国产 ROM）时同样隐藏入口；iOS 走系统 Vision，恒可用。
///
/// [isSupportedPlatform] 为 false 或 [isAvailable] 为 false 时，调用方不得
/// 构建扫码按钮、也不得调用 [showSyncPairingScanner]。
abstract final class SyncPairingScanner {
  /// 平台能力判定覆盖（widget 测试注入；生产为 null = 按 [defaultTargetPlatform]）。
  @visibleForTesting
  static TargetPlatform? debugPlatformOverride;

  /// 运行环境可用性覆盖（widget 测试注入；生产为 null = 按 GMS 探测）。
  @visibleForTesting
  static Future<bool> Function()? debugAvailabilityOverride;

  /// 平台是否支持相机扫码（Android / iOS；不问 GMS）。
  static bool get isSupportedPlatform {
    final platform = debugPlatformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  /// 扫码入口是否可用（平台 × 运行环境）。
  static Future<bool> isAvailable() async {
    if (!isSupportedPlatform) return false;
    final override = debugAvailabilityOverride;
    if (override != null) return override();
    // iOS 在平台判定后就短路（Vision 不需要 GMS）：与
    // [PlayServicesAvailability] 的 iOS 分支同义，也保证测试里
    // [debugPlatformOverride] 能决定整条可用性路径。
    if ((debugPlatformOverride ?? defaultTargetPlatform) ==
        TargetPlatform.iOS) {
      return true;
    }
    return PlayServicesAvailability.isAvailable();
  }
}

/// 扫码失败的处置分支（纯函数判定，单测直接覆盖三条路径）。
enum SyncScanErrorKind {
  /// 相机权限被拒：给「去系统设置 / 改用粘贴」。
  cameraPermission,

  /// 识别模型缺失 / 下载失败（unbundled ML Kit 需要访问 Google 服务）：
  /// 给「重试 / 改用粘贴」。
  modelUnavailable,

  /// 其它失败（相机被占用 / 硬件不可用 / 控制器状态错）：只给「改用粘贴」。
  unavailable,
}

/// 异常 → 处置分支。
///
/// mobile_scanner 对 ML Kit 的模型下载失败只给 `genericError`，细节在
/// `errorDetails` 的 code / message 里（各平台文案不同）；这里按关键词兜底
/// 识别，识别不到就归 [SyncScanErrorKind.unavailable]（仍然不是死胡同）。
SyncScanErrorKind scanErrorKind(MobileScannerException error) {
  if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
    return SyncScanErrorKind.cameraPermission;
  }
  final details = [
    error.errorCode.name,
    error.errorDetails?.code ?? '',
    error.errorDetails?.message ?? '',
    '${error.errorDetails?.details ?? ''}',
  ].join(' ').toLowerCase();
  if (details.contains('mlkit') ||
      details.contains('model') ||
      details.contains('download') ||
      details.contains('barcode')) {
    return SyncScanErrorKind.modelUnavailable;
  }
  return SyncScanErrorKind.unavailable;
}

/// 打开扫码页；识别到内容返回原始文本，用户放弃 / 权限被拒返回 null。
///
/// [onOpenSettings] 由调用方注入（复用「去系统设置」的既有实现，不在扫码
/// 模块里再开一个平台通道）。
Future<String?> showSyncPairingScanner(
  BuildContext context, {
  required Future<void> Function() onOpenSettings,
}) async {
  return Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => SyncPairingScannerPage(onOpenSettings: onOpenSettings),
    ),
  );
}

/// 扫码页：相机预览 + 取景框；识别到第一个条码后停止并回传文本。
///
/// 相机权限由 mobile_scanner 插件自管（不引入 permission_handler，见
/// `docs/pitfalls.md` 40）；unbundled ML Kit 的首次模型下载失败按
/// [SyncScanErrorKind.modelUnavailable] 给「重试 / 改用粘贴」。
class SyncPairingScannerPage extends StatefulWidget {
  const SyncPairingScannerPage({super.key, required this.onOpenSettings});

  final Future<void> Function() onOpenSettings;

  @override
  State<SyncPairingScannerPage> createState() => _SyncPairingScannerPageState();
}

class _SyncPairingScannerPageState extends State<SyncPairingScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value.trim());
      return;
    }
  }

  /// 模型下载失败等错误后的重试：重新启动控制器（错误视图随状态更新）。
  Future<void> _retry() async {
    try {
      await _controller.start();
    } catch (_) {
      // 重试失败保持错误视图（用户还有「改用粘贴」）。
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncPairingScanTitle),
        automaticallyImplyLeading: true,
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: (context, error) => _ScannerErrorView(
          error: error,
          onOpenSettings: widget.onOpenSettings,
          onRetry: _retry,
        ),
      ),
    );
  }
}

/// 相机不可用 / 权限被拒 / 模型下载失败：按分支给出路而不是死胡同。
class _ScannerErrorView extends StatelessWidget {
  const _ScannerErrorView({
    required this.error,
    required this.onOpenSettings,
    required this.onRetry,
  });

  final MobileScannerException error;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final kind = scanErrorKind(error);
    final permissionDenied = kind == SyncScanErrorKind.cameraPermission;
    final modelUnavailable = kind == SyncScanErrorKind.modelUnavailable;
    final semantic = AppSemanticColors.of(context);
    final message = switch (kind) {
      SyncScanErrorKind.cameraPermission => l10n.syncPairingCameraDenied,
      SyncScanErrorKind.modelUnavailable => l10n.syncPairingModelUnavailable,
      SyncScanErrorKind.unavailable => l10n.syncPairingCameraUnavailable,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              permissionDenied
                  ? Icons.no_photography_rounded
                  : Icons.warning_amber_rounded,
              size: 40,
              color: semantic.warning,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (permissionDenied)
              M3EButton.filled(
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => onOpenSettings(),
                label: Text(l10n.syncOpenSystemSettings),
              ),
            if (modelUnavailable)
              M3EButton.filled(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => unawaited(onRetry()),
                label: Text(l10n.syncRetry),
              ),
            // 「改用粘贴」是相机不可用时永远成立的出路（返回添加设备弹层）。
            M3EButton.text(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.syncPairingUsePaste),
            ),
          ],
        ),
      ),
    );
  }
}
