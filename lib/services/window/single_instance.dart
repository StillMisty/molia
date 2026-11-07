/// 桌面单实例（Linux / Windows / macOS）：出口与 `window_chrome.dart` 同构。
///
/// **强制行为，不做用户开关**：桌面窗口应用的第二份进程只会带来重复托盘
/// 图标、两份播放会话与两份设置写入，而再次启动的意图几乎总是「把已有
/// 窗口拉到前台」——后来的进程请主实例显示窗口后自行退出。
///
/// **每用户一个 primary**：Dart 侧用 OS 文件锁（进程崩溃自动释放）作为
/// 最终仲裁；Windows 命名 mutex / Linux GApplication 只是同会话的
/// 「引擎启动前退出 + 激活」快速路径，跨会话与 macOS 直接执行二进制仍
/// 回落到这里。
///
/// 组合根只经本入口访问：`dart:io` 的 Socket / 锁文件都收在实现文件里
/// （与 app_tray / window_chrome 同一约束），非桌面平台 [SingleInstance.acquire]
/// 直接按主实例返回。
library;

export 'single_instance_io.dart';
export 'single_instance_lock.dart';
