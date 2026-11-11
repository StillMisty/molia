import '../../domain/models/device_sync.dart';

/// 纯记录源：只负责把本地存储导出为同步记录、把远端记录写回本地。
///
/// 行表类适配器（歌单 / 历史 / 统计）只实现这一层；指纹缓存、fresh 绕过与
/// 「落地后缓存失效」由 `ChangeDetectingAdapter` 装饰器统一拥有。版本戳与
/// 增量日志仍留在各自的数据写入事务里（ADR-0003 要求与数据写入同事务），
/// 不在这一层重复实现。
abstract interface class SyncRecordSource {
  Set<SyncCategory> get categories;

  /// 本轮是否可工作（如音源仓库尚未初始化时跳过，避免误判删除）。
  bool get ready;

  /// 读取并导出本机视图（每次调用都读存储；缓存由装饰器负责）。
  Future<Map<SyncCategory, List<SyncRecord>>> exportRecords();

  Future<SyncApplyOutcome> apply(Map<SyncCategory, List<SyncRecord>> records);
}

/// 数据类别适配器：把本地存储导出为同步记录，或把合并结果写回本地。
///
/// 约定：
/// - [collect] 允许做「变化检测」副作用（登记设置键哈希、补脚本墓碑），
///   同一轮内先 collect 后 apply；行表类适配器的廉价指纹缓存与 fresh 绕过
///   由 `ChangeDetectingAdapter` 装饰器统一拥有，适配器不再各写一份；
/// - [apply] 只处理自己认识的键，遇到未知记录计入 skipped，不抛异常；
/// - 写入必须幂等：重复应用同一份合并结果不得产生新的本地变更；
/// - 引擎只把启用类别的记录交给适配器；普通适配器在关闭期间仍可持续登记
///   本地变化（重新开启后直接参与合并），代价高的适配器实现
///   [CategoryScopedSyncAdapter]，类别未请求时整轮跳过。
abstract interface class SyncAdapter {
  Set<SyncCategory> get categories;

  /// 本轮是否可工作（如音源仓库尚未初始化时跳过，避免误判删除）。
  bool get ready;

  /// 导出本机视图。
  ///
  /// [fresh] 为 true 时绕过「廉价指纹缓存」重新读行：anti-entropy 的全量校验
  /// 必须看到真实内容（行被直接改写时指纹（行数 + 最大版本）不会变化）。
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false});

  Future<SyncApplyOutcome> apply(Map<SyncCategory, List<SyncRecord>> records);
}

/// 可选能力：释放适配器为「上轮 collect 复用」保留的内存缓存。
///
/// 只清可由存储重新导出的派生缓存（记录列表 / base64 等），不清持久化
/// 数据、同步登记或用户内容；实现必须幂等。引擎在轮间（托盘隐藏 / 系统
/// 低内存）通过类型检查调用，避免把释放逻辑写进每个适配器的存储层。
abstract interface class SyncAdapterCacheReleaser implements SyncAdapter {
  void releaseCaches();
}

/// 类别受限适配器：收集时额外拿到「本轮请求的类别集合」。
///
/// 封面这类收集成本高（读文件 + 哈希 + base64）的适配器实现本接口：类别
/// 不在请求集合里时立即返回空，不读盘、不编码，也不增长缓存。普通适配器
/// 不需要实现——引擎仍调用 [SyncAdapter.collect] 并在聚合时按类别过滤。
abstract interface class CategoryScopedSyncAdapter implements SyncAdapter {
  /// 只收集 [categories] 中的本适配器类别（其余类别忽略）。
  Future<Map<SyncCategory, List<SyncRecord>>> collectForCategories(
    Set<SyncCategory> categories, {
    bool fresh = false,
  });
}

/// 适配器应用结果计数。
class SyncApplyOutcome {
  final int applied;
  final int skipped;

  const SyncApplyOutcome({this.applied = 0, this.skipped = 0});

  static const SyncApplyOutcome none = SyncApplyOutcome();

  SyncApplyOutcome operator +(SyncApplyOutcome other) => SyncApplyOutcome(
    applied: applied + other.applied,
    skipped: skipped + other.skipped,
  );
}

/// 类别指纹的组合键（按类别枚举序拼接，与 Map 迭代顺序无关）。
///
/// 适配器用它作为「上轮记录缓存」的键：指纹未变直接复用缓存，不读行。
String syncFingerprintKey(Map<SyncCategory, String> fingerprints) {
  final entries = fingerprints.entries.toList()
    ..sort((a, b) => a.key.index.compareTo(b.key.index));
  return entries.map((entry) => '${entry.key.name}=${entry.value}').join(';');
}
