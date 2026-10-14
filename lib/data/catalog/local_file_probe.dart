/// 本地文件存在性探测（Web 编译安全：条件导入 dart:io 实现）。
///
/// 供 `LocalMusicSource` 在解析本地下载曲目时校验文件是否仍在；
/// Web / 不支持平台恒为 false（本地下载在 Web 整体不可用）。
library;

import 'local_file_probe_stub.dart'
    if (dart.library.io) 'local_file_probe_io.dart' as platform;

Future<bool> localFileExists(String path) => platform.localFileExists(path);
