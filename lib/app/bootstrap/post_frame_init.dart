/// 首帧之后的启动尾巴：托盘落地 + 更新准备/自动检查 + 音源初始化 → 同步启动
/// 与首轮同步。
///
/// 为什么留到首帧：托盘图标资源此时可读；更新读包信息/偏好、同步引擎读安全
/// 存储口令、调度器电量/网络探针都不参与首帧内容（见各自 start 的注释）；
/// 音源脚本加载与更新检查同理；同步传输启动要过局域网权限门（Android 系统
/// 对话框）并绑套接字，早于首帧会让窗口等一个用户看不见的对话框（顺序不变）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'catalog_stack.dart';
import 'desktop_stack.dart';
import 'sync_stack.dart';
import 'update_stack.dart';

/// 在 `WidgetsBinding.instance.addPostFrameCallback` 内调用一次。
void initAfterFirstFrame({
  required CatalogStack catalog,
  required DesktopStack desktop,
  required UpdateStack update,
  required SyncStack sync,
}) {
  // 托盘在首帧后创建：此时图标资源可读，且不占启动关键路径。
  // 宿主探测预热：关闭策略首次触发时直接读缓存结果（并留下启动日志）。
  desktop.initTray();

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
    await startSync(sync);
    await catalog.sourceManager.init();
    unawaited(sync.provider.startTransports());
    unawaited(sync.provider.startupSync());
  }());
}
