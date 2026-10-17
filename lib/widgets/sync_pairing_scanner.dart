import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_semantic_colors.dart';

/// 扫码能力的平台判定 + 扫码页入口。
///
/// 只支持 Android / iOS（mobile_scanner 的移动实现）：桌面三平台不构建扫码
/// 入口，只给「粘贴配对码」；[isSupported] 为 false 时不得调用
/// [showSyncPairingScanner]（调用方按能力判定后再构建按钮）。
abstract final class SyncPairingScanner {
  /// 平台能力判定覆盖（widget 测试注入；生产为 null = 按 [defaultTargetPlatform]）。
  @visibleForTesting
  static TargetPlatform? debugPlatformOverride;

  static bool get isSupported {
    final platform = debugPlatformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }
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
/// `docs/pitfalls.md` 40）：被拒时给「去系统设置 / 改用粘贴」两条出路。
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
        errorBuilder: (context, error) =>
            _ScannerErrorView(error: error, onOpenSettings: widget.onOpenSettings),
      ),
    );
  }
}

/// 相机不可用 / 权限被拒：给出路而不是死胡同。
class _ScannerErrorView extends StatelessWidget {
  const _ScannerErrorView({required this.error, required this.onOpenSettings});

  final MobileScannerException error;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final permissionDenied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    final semantic = AppSemanticColors.of(context);
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
            Text(
              permissionDenied
                  ? l10n.syncPairingCameraDenied
                  : l10n.syncPairingCameraUnavailable,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (permissionDenied)
              M3EButton.filled(
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => onOpenSettings(),
                label: Text(l10n.syncOpenSystemSettings),
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
