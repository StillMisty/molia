/// 本地文件存在性探测端口。
///
/// 默认走 `dart:io`；组合根在本地数据栈建好后 `attach` 到下载存储的
/// 存在性探测，Android 的 `content://` locator 因此也走 SAF bridge，
/// 不再由 `LocalMusicSource` 误用 `File.exists()`。
library;

import 'local_file_probe_io.dart' as platform;

/// 本地 locator 存在性探测（`path` / `file:` / `content:`）。
class LocalFileProbe {
  LocalFileProbe({Future<bool> Function(String locator)? probe})
    : _probe = probe ?? platform.localFileExists;

  Future<bool> Function(String locator) _probe;

  /// 组合根接线（本地数据栈就绪后调用一次；幂等）。
  void attach(Future<bool> Function(String locator) probe) => _probe = probe;

  Future<bool> probe(String locator) => _probe(locator);
}

/// 便捷函数（不持有接线状态；测试 / 简单调用方使用）。
Future<bool> localFileExists(String path) => platform.localFileExists(path);
