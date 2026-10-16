/// 首帧之后的启动尾巴：托盘落地 + 自动更新检查 + 音源初始化（随后首轮同步）。
///
/// 为什么留到首帧：托盘图标资源此时可读、音源脚本加载与更新检查都不占启动
/// 关键路径（原组合根的 `addPostFrameCallback` 内容，顺序不变）。
library;

import 'dart:async';

import '../../providers/sync_provider.dart';
import 'catalog_stack.dart';
import 'desktop_stack.dart';
import 'update_stack.dart';

/// 在 `WidgetsBinding.instance.addPostFrameCallback` 内调用一次。
void initAfterFirstFrame({
  required CatalogStack catalog,
  required DesktopStack desktop,
  required UpdateStack update,
  required SyncProvider syncProvider,
}) {
  // 托盘在首帧后创建：此时图标资源可读，且不占启动关键路径。
  // 宿主探测预热：关闭策略首次触发时直接读缓存结果（并留下启动日志）。
  desktop.initTray();

  // 更新检查默认关闭（用户开启后每天最多一轮），网络失败静默不打扰。
  unawaited(update.provider.maybeAutoCheck());

  // 启动后初始化音源（加载已导入的 LX 音源脚本）；随后发起首轮同步
  // （音源仓库就绪后脚本适配器才能工作）。首轮同样受调度器等级约束：
  // 省电 / 移动数据暂停时不跑，移动数据下只同步小类别。
  catalog.sourceManager.init().then((_) {
    unawaited(syncProvider.startupSync());
  });
}
