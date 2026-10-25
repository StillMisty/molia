/// 首帧之后的启动尾巴：桌面外壳（托盘 + 任务栏按钮）落地 + 更新准备/自动检查
/// + 音源初始化 → 同步启动与首轮同步。
///
/// 为什么留到首帧：托盘图标资源此时可读；更新读包信息/偏好、同步引擎读安全
/// 存储口令、调度器电量/网络探针都不参与首帧内容（见各自 start 的注释）；
/// 音源脚本加载与更新检查同理；同步传输启动要过局域网权限门（Android 系统
/// 对话框）并绑套接字，早于首帧会让窗口等一个用户看不见的对话框（顺序不变）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/cache_service.dart';
import 'catalog_stack.dart';
import 'desktop_stack.dart';
import 'library_stack.dart';
import 'local_data_stack.dart';
import 'startup_trace.dart';
import 'sync_stack.dart';
import 'update_stack.dart';

/// 在 `WidgetsBinding.instance.addPostFrameCallback` 内调用一次。
void initAfterFirstFrame({
  required CatalogStack catalog,
  required LocalDataStack local,
  required LibraryStack library,
  required DesktopStack desktop,
  required UpdateStack update,
  required SyncStack sync,
}) {
  // 托盘与 Windows 任务栏按钮在首帧后创建：此时图标资源可读，且不占启动
  // 关键路径。宿主探测预热：关闭策略首次触发时直接读缓存结果（并留下启动日志）。
  desktop.initDesktopSurfaces();

  // 首帧后的本地数据尾巴：省流网络探测 / 下载记录加载 / 音频缓存维护。
  // 这几项都要过平台通道或磁盘，继续留在 runApp 前会把首帧整体推后。
  final dataSaverWatch = Stopwatch()..start();
  unawaited(
    local.dataSaver.startMonitoring().whenComplete(
          () => markStartupStep('sub.dataSaver.monitor（首帧后）', dataSaverWatch),
        ),
  );
  final downloadWatch = Stopwatch()..start();
  unawaited(
    local.downloadService.init().whenComplete(
          () => markStartupStep('sub.downloadService.init（首帧后）', downloadWatch),
        ),
  );
  unawaited(() async {
    // 半成品清扫只可能清理本进程启动前的残留；放在首帧后不影响下载语义。
    await CacheService.instance.cleanupAudioPartials();
  }());

  // 同步身份的安全存储备份：正常启动 prefs 已一致时是空操作；首装把
  // Keystore 写入从首帧路径挪到这里（读取仍留在 init，身份恢复需要）。
  unawaited(library.syncState.backupDeviceId());

  // 资料库启动尾巴：全库最大戳种子 → 统计收尾/裁剪
  // （`startLibraryAfterFirstFrame` 内部会等种子完成再跑统计维护）。
  startLibraryAfterFirstFrame(library);

  // 更新：包信息 / 偏好 / 平台信息在这里读（start 完成前不动更新状态；
  // 设置页此刻也还没机会被打开），读完才做启动自动检查——开关与节流
  // 都来自偏好，必须排在 start 之后。可选子系统：初始化失败只记日志。
  unawaited(() async {
    try {
      await update.provider.start();
    } catch (e) {
      debugPrint('[Molia] 更新初始化失败（继续启动）: $e');
    }
    await update.provider.maybeAutoCheck();
  }());

  // 同步：引擎 init（安全存储读口令）+ 调度器启动（电量/网络探针）→ 音源
  // 初始化（音源仓库就绪后脚本适配器才能工作）→ 传输先起（状态面立刻可见）、
  // 再跑首轮；首轮同样受调度器等级约束：省电 / 移动数据暂停时不跑，
  // 移动数据下只同步小类别。
  unawaited(() async {
    // 同步应用/导出会补 syncId 并取版本戳；先等首帧后的种子完成，避免
    // 在种子前取号（也避免在 DB 事务里等一个还没开始的查询）。
    await library.syncState.stampSeedReady;
    await startSync(sync);
    await catalog.sourceManager.init();
    unawaited(sync.provider.startTransports());
    unawaited(sync.provider.startupSync());
  }());
}
