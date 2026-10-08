import '../models/source.dart';
import '../models/track.dart';
import 'music_source.dart';

/// 音源注册表：按 order 排序后的可用列表 + 按 key/曲目查找。
///
/// 阶段 0 只定义契约；阶段 2 由 `SourceRegistryImpl` 承接
/// `SourceManager` 的排序/启用逻辑（`lx_source_order` 原样保留）。
abstract interface class SourceRegistry {
  /// 按 order 排序后的可用列表；搜索页选择器直接消费。
  List<SourceDescriptor> get descriptors;

  MusicSource? byKey(String key);

  /// 按 `track.id.sourceKey` 查找。
  MusicSource? forTrack(Track track);

  /// 脚本启停/登录态变化后调用。
  Future<void> refresh();

  /// 持久化用户排序。
  Future<void> setOrder(List<String> keys);

  /// 变更通知（全应用统一用流或 ChangeNotifier，二选一；此处用流）。
  Stream<void> get changes;
}
