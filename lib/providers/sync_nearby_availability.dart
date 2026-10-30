/// 附近设备卡片的可用性分层（纯 Dart，便于映射测试）。
///
/// 附近设备空态不能只说「没有发现设备」：权限被拒、传输未启动、移动数据、
/// 省电模式、本机 UDP 不可用都会让搜索根本跑不起来。这里把本机原因归成
/// 一组可解释的状态，由 UI 映射成不同的标题 / 副标题与下一步。
///
/// 判定顺序即优先级：先看「本机还没准备好」（权限 / 开关 / 传输），再看策略
/// 暂停（移动数据 / 省电），最后才是发现能力降级（UDP / 配对端口）。
enum SyncNearbyAvailability {
  /// 局域网权限未授予（或已被系统拒绝），需要先完成上方授权。
  permissionDenied,

  /// 局域网传输开关关闭。
  lanOff,

  /// 开关已开但传输没有真正运行（启动失败 / 尚未启动）。
  transportUnavailable,

  /// 移动数据下配对发现被策略禁用。
  cellular,

  /// 省电模式暂停自动同步与附近搜索。
  powerSave,

  /// 本机 UDP 的 IPv4 / IPv6 两族都不可用，自动发现无法工作。
  discoveryUnavailable,

  /// 传输在跑、UDP 可用，但配对探测端口不可用（配对服务未就绪）。
  pairingUnavailable,

  /// 可以正常扫描附近设备。
  available,
}

/// 把本机状态解析成附近设备可用性（纯函数；provider 只做字段取值）。
///
/// [transportUnavailable] 表示开关已开但传输没有在运行或带启动类失败原因；
/// [discoveryAvailable] 对应 UDP 两族至少一族有端口；[pairingAvailable]
/// 对应 MSP 探测端口是否可用（配对服务 / 发现层是否接线）。
SyncNearbyAvailability resolveSyncNearbyAvailability({
  required bool lanEnabled,
  required bool permissionDenied,
  required bool transportRunning,
  required bool transportUnavailable,
  required bool discoveryAvailable,
  required bool pairingAvailable,
  required bool onCellular,
  required bool powerSaveActive,
}) {
  if (permissionDenied) return SyncNearbyAvailability.permissionDenied;
  if (!lanEnabled) return SyncNearbyAvailability.lanOff;
  if (!transportRunning || transportUnavailable) {
    return SyncNearbyAvailability.transportUnavailable;
  }
  if (onCellular) return SyncNearbyAvailability.cellular;
  if (powerSaveActive) return SyncNearbyAvailability.powerSave;
  if (!discoveryAvailable) return SyncNearbyAvailability.discoveryUnavailable;
  if (!pairingAvailable) return SyncNearbyAvailability.pairingUnavailable;
  return SyncNearbyAvailability.available;
}
