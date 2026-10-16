import '../../domain/models/device_sync.dart';

/// 数据类别适配器：把本地存储导出为同步记录，或把合并结果写回本地。
///
/// 约定：
/// - [collect] 允许做「变化检测」副作用（登记设置键哈希、补脚本墓碑），
///   同一轮内先 collect 后 apply；行表类适配器按端口提供的廉价指纹缓存
///   上轮记录（指纹未变不读行），并在自己落地了远端记录时让缓存失效；
/// - [apply] 只处理自己认识的键，遇到未知记录计入 skipped，不抛异常；
/// - 写入必须幂等：重复应用同一份合并结果不得产生新的本地变更；
/// - 引擎只把启用类别的记录交给适配器（关闭期间 collect 仍持续登记本地
///   变化，保证重新开启后可直接参与合并）。
abstract interface class SyncAdapter {
  Set<SyncCategory> get categories;

  /// 本轮是否可工作（如音源仓库尚未初始化时跳过，避免误判删除）。
  bool get ready;

  Future<Map<SyncCategory, List<SyncRecord>>> collect();

  Future<SyncApplyOutcome> apply(Map<SyncCategory, List<SyncRecord>> records);
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
