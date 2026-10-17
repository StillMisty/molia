/// 本地文件存在性探测（`dart:io` 实现）。
///
/// 供 `LocalMusicSource` 在解析本地下载曲目时校验文件是否仍在；
/// 路径不可读时恒为 false（本地下载整体不可用时同样按不存在处理）。
library;

import 'local_file_probe_io.dart' as platform;

Future<bool> localFileExists(String path) => platform.localFileExists(path);
