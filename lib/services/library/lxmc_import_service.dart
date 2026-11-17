/// `.lxmc` 导入的 data 边界适配：把解码异常翻译成 UI 可消费的稳定原因。
///
/// 为什么需要这层：文件选择与提示属于 UI，落库属于 provider / data 层；
/// widget 不应为了识别解码失败而直接依赖 `lib/data/lxmc_decoder.dart`。
/// 服务只做错误形态转换，导入语义与文案选择仍留在调用方。
library;

import 'dart:typed_data';

import '../../data/lxmc_decoder.dart' show LxmcDecodeException;
import '../../domain/models/library.dart';

/// 导入动作：由 composition root / provider 注入（测试可传假实现）。
typedef LxmcImportBytesCommand = Future<LxmcImportResult> Function(
  Uint8List bytes, {
  String? fileName,
});

/// 解码失败原因（机器可读，UI 据此选 l10n 文案）。
class LxmcImportException implements Exception {
  const LxmcImportException(this.reason);

  /// `unsupported` / `no_tracks` / 其它解码器返回的原因。
  final String reason;

  @override
  String toString() => 'LxmcImportException($reason)';
}

/// `.lxmc` 导入服务：把 data 层解码异常收敛为 [LxmcImportException]。
class LxmcImportService {
  const LxmcImportService({required this._importBytes});

  final LxmcImportBytesCommand _importBytes;

  /// 导入文件字节；解码失败抛 [LxmcImportException]，其余异常原样透传。
  Future<LxmcImportResult> importBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    try {
      return await _importBytes(bytes, fileName: fileName);
    } on LxmcDecodeException catch (error) {
      throw LxmcImportException(error.reason);
    }
  }
}
