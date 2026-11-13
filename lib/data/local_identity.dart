/// 本地导入文件的稳定身份规则（纯 Dart，无 drift / Flutter 依赖）。
///
/// 为什么独立成模块：迁移改写、下载记录、封面键、扫描器与重定位都要回答同
/// 一个问题——「这个字符串是旧路径身份还是新的 `file:` 稳定身份」。规则只
/// 写一次，避免各处用 `startsWith('local:')` 猜（下载副本的 `local:wy:123`
/// 也以 `local:` 开头，不能一概当成导入）。
library;

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 新身份前缀（`file:<uuid v4>`）。
const String kLocalKeyPrefix = 'file:';

/// 旧导入身份的固定前缀（`local:<绝对路径>`）。
const String _legacyLocalPrefix = 'local:';

/// 是否为新的稳定本地身份（`file:<uuid>`）。
bool isStableLocalKey(String value) => value.startsWith(kLocalKeyPrefix);

/// 是否为**旧导入**曲目 id（`local:<绝对路径>`）。
///
/// 下载副本的 id 是 `local:wy:123`（原音源键带一层 `local:`），不含路径
/// 分隔符，因此不会被误判；已经迁移过的 `local:file:<uuid>` 也不算旧身份。
bool isLegacyLocalIdentity(String songId) {
  if (!songId.startsWith(_legacyLocalPrefix)) return false;
  final rest = songId.substring(_legacyLocalPrefix.length);
  if (rest.isEmpty || isStableLocalKey(rest)) return false;
  return rest.contains('/') || rest.contains('\\');
}

/// 旧导入身份里的原始路径（非旧身份时为 null）。
String? legacyLocalPathOf(String songId) => isLegacyLocalIdentity(songId)
    ? songId.substring(_legacyLocalPrefix.length)
    : null;

/// 旧导入记录的文件路径对应的旧曲目 id（`local:<path>`）。
String legacyLocalIdentityOf(String path) => '$_legacyLocalPrefix$path';

/// 路径比较键：平台大小写规则（Windows / macOS 不敏感，Linux / Android
/// 敏感），只用于比较与去重；存库 / 展示保留用户看到的原始大小写。
///
/// macOS 的个例（大小写敏感卷）按不敏感处理，是有意接受的边界。
String localPathKey(String path) {
  final normalized = p.normalize(path);
  return Platform.isWindows || Platform.isMacOS
      ? normalized.toLowerCase()
      : normalized;
}

/// 是否为「设备本地」封面键：新导入身份 `file:<uuid>`，或旧的导入路径键
/// `local:<path>`。
///
/// 下载副本的 `local:<原音源键>`（如 `local:wy:123`）不属于此列——它仍按
/// 在线曲目封面同步。
bool isDeviceLocalCoverKey(String key) =>
    key.startsWith(kLocalKeyPrefix) || isLegacyLocalIdentity(key);

final Random _secureRandom = Random.secure();

/// 生成 `file:<uuid v4>`。
///
/// 项目没有直接的 uuid 依赖（只有传递依赖，不能 import）；随机源与格式在
/// 这里实现，测试可注入 [random] 得到确定值。
String newLocalKey([Random? random]) {
  final source = random ?? _secureRandom;
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int from, int length) => [
    for (var i = from; i < from + length; i++)
      bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join();
  return '$kLocalKeyPrefix${hex(0, 4)}-${hex(4, 2)}-${hex(6, 2)}-'
      '${hex(8, 2)}-${hex(10, 6)}';
}
