import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/sync_pairing_scanner.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码错误 → 处置分支的纯函数判定（三条路径各有用例）。
///
/// 为什么单独测：unbundled ML Kit 的模型下载失败只报 `genericError`，
/// 分类靠 `errorDetails` 的关键词兜底；这里把「什么算模型问题」钉死，
/// 实现改动（关键词 / 分支）会立刻在这里红。
void main() {
  MobileScannerException error(
    MobileScannerErrorCode code, {
    String? detailsCode,
    String? message,
  }) =>
      MobileScannerException(
        errorCode: code,
        errorDetails: MobileScannerErrorDetails(
          code: detailsCode,
          message: message,
          details: null,
        ),
      );

  test('相机权限被拒 → cameraPermission（去系统设置 + 改用粘贴）', () {
    expect(
      scanErrorKind(error(MobileScannerErrorCode.permissionDenied)),
      SyncScanErrorKind.cameraPermission,
    );
    expect(
      scanErrorKind(error(
        MobileScannerErrorCode.permissionDenied,
        message: 'whatever',
      )),
      SyncScanErrorKind.cameraPermission,
    );
  });

  test('模型 / MLKit 下载失败 → modelUnavailable（重试 + 改用粘贴）', () {
    // 各平台文案不同：按关键词兜底（mlkit / model / download / barcode）。
    for (final message in const [
      'MLKitException: model not downloaded',
      'Failed to download barcode model',
      'com.google.mlkit.vision.barcode is not available',
    ]) {
      expect(
        scanErrorKind(error(MobileScannerErrorCode.genericError, message: message)),
        SyncScanErrorKind.modelUnavailable,
        reason: message,
      );
    }
    expect(
      scanErrorKind(error(
        MobileScannerErrorCode.genericError,
        detailsCode: 'mlkitModelDownload',
      )),
      SyncScanErrorKind.modelUnavailable,
    );
  });

  test('其它失败（相机占用 / 硬件 / 状态错）→ unavailable（只给改用粘贴）', () {
    for (final code in const [
      MobileScannerErrorCode.genericError,
      MobileScannerErrorCode.unsupported,
      MobileScannerErrorCode.controllerUninitialized,
      MobileScannerErrorCode.controllerDisposed,
    ]) {
      expect(
        scanErrorKind(error(code, message: 'camera is busy')),
        SyncScanErrorKind.unavailable,
        reason: code.name,
      );
    }
  });
}
