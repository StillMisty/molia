/// 同步观测面的紧凑格式化（设置页 / 名册页 / 日志页共用）。
library;

import 'package:intl/intl.dart';

/// 时间戳 → `MM-dd HH:mm`（日志行、状态行与「最后成功于」共用）。
String syncTimeText(int millisecondsSinceEpoch) =>
    DateFormat('MM-dd HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch));

/// 字节数的紧凑展示（KB/MB 千位制；同步快照常用量级）。
String syncBytesText(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
