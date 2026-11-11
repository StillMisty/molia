import '../data/sync/sync_adapter.dart';
import '../data/sync/sync_state_codec.dart';
import '../domain/models/device_sync.dart';
import '../domain/models/sync_nearby_pairing.dart';
import '../services/local_endpoints_service.dart';
import '../services/manual_peer_service.dart';
import 'sync_ui_state.dart';

/// 用户动作面：设置页 / 弹层只经这些命令改同步状态。
///
/// 与 [SyncUiState] 分开：读是每次通知后重建的不可变快照，写是低频命令。
/// provider 仍是 Provider 树里的绑定对象，但 UI 不再直接摸引擎 / 控制面 /
/// 调度器 / 权限门 / 备份 / 配对六个协作者。
abstract interface class SyncCommands {
  /// 配对 / 附近扫描 / 备份 / 本机地址各自收成子命令，避免一个类继续膨胀。
  SyncPairingCommands get pairing;
  SyncNearbyCommands get nearby;
  SyncBackupCommands get backup;
  SyncLocalEndpointsCommands get endpoints;

  /// 开 / 关一路传输（传输开关即总闸）。
  Future<bool> setTransportEnabled(SyncTransportId id, bool value);

  /// 申请局域网权限（Android 17+）；授予后自动启用局域网传输。
  Future<bool> requestLanPermission();

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  Future<void> openSystemSettings();

  /// 一次写入 WebDAV 配置与密码。
  Future<void> saveWebdavConfig(WebDavConfig config, String password);

  /// 读取 WebDAV 密码（配置弹层预填；不进入 UI 投影）。
  Future<String?> readWebdavPassword();

  /// 打开 / 关闭一个同步类别。
  Future<void> setCategory(SyncCategory category, bool value);

  /// 蜂窝网络下的自动同步策略。
  Future<void> setCellularPolicy(SyncCellularPolicy value);

  Future<void> setDeviceName(String value);

  /// 重置口令：所有设备需重新输入新口令。
  Future<String> resetPassphrase();

  /// 手动地址表单的唯一命令（地址入簿 → 探测 → 立即接触）。
  Future<SyncManualPeerOutcome> saveManualPeer({
    required String host,
    int probePort = 0,
    String name = '',
    ManualPeer? editing,
  });

  /// 移除一条手动地址（不碰名册）。
  Future<void> removeManualPeer(String host);

  /// 从本机名册与地址簿移除一台设备（不撤销授权）。
  Future<void> removePeer(String deviceId);

  /// 显式清理某台设备的远端文件（不做自动删除）。
  Future<({bool removed, SyncIssue? error})> cleanupRemote(String deviceId);

  /// 跑一轮手动同步（只服务恢复动作）。
  Future<SyncRoundReport?> syncNow();

  /// 打开同步页时检查连接（经调度器，受省电 / 蜂窝策略约束）。
  Future<void> checkConnections();
}

/// 附近设备配对命令（`MSP/1` 发现 + `/pair/*`）。
abstract interface class SyncPairingCommands {
  Future<SyncPairingResult> request(SyncNearbyDevice device);

  Future<SyncPairingOutcome> respond(String requestId, {required bool accept});

  Future<void> cancel(String requestId);
}

/// 附近设备扫描命令；可用性事实在 [SyncUiState.nearbyAvailability]。
abstract interface class SyncNearbyCommands {
  Future<bool> start();

  void stop();
}

/// 完整备份命令（数据与存储页使用）。
abstract interface class SyncBackupCommands {
  Future<String> exportJson({bool includeCredentials = true});

  Future<SyncApplyOutcome> importJson(
    String json, {
    bool includeCredentials = true,
  });
}

/// 本机地址读取命令（设置页地址列表 / 手动地址探测共用同一口径）。
abstract interface class SyncLocalEndpointsCommands {
  Future<List<LocalEndpoint>> list();

  /// 失效缓存（进入设置页 / 网络切换后重进）。
  void refresh();
}
