/// 同步观测面的紧凑格式化（设置页与日志页共用）。
///
/// 纯格式函数：不发请求、不读设置。时间戳的两处消费面同源——同步状态行 /
/// 日志行 / 配对弹层的「最后成功于」，以及收藏页播放历史列表的播放时间列。
library;

import 'package:intl/intl.dart';

/// 时间戳 → `MM-dd HH:mm`（日志行、状态行与「最后成功于」共用）。
String syncTimeText(int millisecondsSinceEpoch) =>
    DateFormat('MM-dd HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch));

/// 字节数的紧凑展示（KB/MB 按 1024 进位；同步快照常用量级）。
String syncBytesText(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
