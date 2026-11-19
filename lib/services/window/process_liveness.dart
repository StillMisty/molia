/// 进程存活探测：单实例 metadata 的快速校验。
///
/// 新锁协议（ADR-0020）由 OS 文件锁判断所有权，不再依赖 pid 清陈旧锁；这里
/// 只用来避免向已退出的 pid / 失效端口发显示请求，以及给 Windows 旧 Roaming
/// 锁的升级守卫做存活判定。
///
/// 窗口能力只在 Linux / Windows / macOS 使用（`WindowChrome.isSupported`）；
/// 其它平台保守返回 true，不参与该路径。原生调用与失败语义见
/// `lib/platform/desktop/process_liveness.dart`（ADR-0038）。
library;

import '../../platform/desktop/process_liveness.dart' as platform;

/// 目标 pid 是否仍存活。
///
/// 查询失败 / 权限不足时保守返回 true：宁可多等一次连接，也不要误删活实例
/// 的锁、多开一个窗口。
bool isProcessAlive(int pid) => platform.isProcessAlive(pid);
