import '../models/device_sync.dart';

/// 同步已知版本的登记键：类别 + 记录键（与 `sync_tombstones` 的主键同构）。
typedef SyncKnownKey = ({SyncCategory category, String key});

/// 同步已知版本登记端口：引擎合并后只把版本与该登记不同的胜者交给适配器
/// （变更集应用），因此一轮的落地量与日志计数 ∝ 本轮变更量。
///
/// 登记的是「最后一次交给适配器的胜者版本」，与本地是否真的写入无关：
/// 适配器内部的新旧判定保留作兜底（登记缺失的首轮仍正确跳过）。登记不随
/// 墓碑清理删除——清理后同一键的旧记录不能因为登记消失而被重新判为新记录。
abstract interface class SyncKnownStore {
  /// 全部登记（启动后一次加载，之后由引擎在内存里维护）。
  Future<Map<SyncKnownKey, SyncVersion>> knownVersions();

  /// 写入/更新登记（只传变化项；实现按主键 upsert）。
  Future<void> putKnownVersions(Map<SyncKnownKey, SyncVersion> versions);
}
