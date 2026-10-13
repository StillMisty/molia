import '../domain/models/source_script.dart';

/// 渠道展示名：`名称 (key)`；渠道列表里查不到该 key 时回退 key 本身。
///
/// [channels] 应包含停用项（`SourcesProvider.channels` 的语义）：停用渠道
/// 上的曲目（队列里仍在播）也应显示可读名称而不是裸 key。
String sourceChannelLabel(Iterable<SourceEntry> channels, String key) {
  if (key.isEmpty) return key;
  for (final entry in channels) {
    if (entry.key == key) return '${entry.name} ($key)';
  }
  return key;
}
