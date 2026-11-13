/// 本地曲目的路径解析端口：稳定身份 → 当前文件路径。
///
/// 为什么单独一层：`local` 音源只认曲目身份，路径可能因重定位 / 扫描 / 用户
/// 移动而变；让音源直接依赖下载服务会形成「sources → services」的反向依赖。
/// 组合根在下载记录就绪后把查询函数挂进来（`attach`），音源只消费这个窄回调；
/// 测试直接注入假实现。
library;

import '../../domain/models/track.dart';

/// 稳定身份 → 当前路径；返回 null 表示没有可用记录（调用方回退 payload）。
typedef LocalPathLookup = Future<String?> Function(Track track);

class LocalPathResolver {
  LocalPathLookup? _lookup;

  /// 组合根接线（下载记录就绪后调用一次）。
  void attach(LocalPathLookup lookup) => _lookup = lookup;

  /// 解析当前路径；没有接线 / 没有记录时返回 null。
  Future<String?> resolve(Track track) async {
    final lookup = _lookup;
    if (lookup == null) return null;
    try {
      return await lookup(track);
    } catch (_) {
      // 记录表不可用（启动早期 / 已释放）不是播放失败：交给 payload 路径。
      return null;
    }
  }
}
