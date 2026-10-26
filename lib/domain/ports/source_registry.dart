import '../models/source.dart';
import '../models/track.dart';
import 'music_source.dart';

/// 音源注册表：按 order 排序后的可用列表 + 按 key/曲目查找。
///
/// 由 `SourceRegistryImpl`（data/catalog）承接 `SourceManager` 的排序/启用
/// 逻辑（`lx_source_order` 原样保留）。
abstract interface class SourceRegistry {
  /// 按 order 排序后的可用列表；搜索页选择器直接消费。
  List<SourceDescriptor> get descriptors;

  /// 已启用的渠道 key（含当前不可搜索的内置平台）。
  ///
  /// 歌词来源等「非播放」场景只关心渠道是否被用户停用，不能用
  /// [descriptors]（它只含可搜索源：五个音乐平台在没有 LX 脚本时不在其中，
  /// 但它们的歌词来源仍然可用）。
  Set<String> get enabledChannelKeys;

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
