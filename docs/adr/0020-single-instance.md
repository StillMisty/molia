# ADR-0020：桌面单实例与平台激活

- 状态：已采纳
- 日期：2026-11-07
- 相关：`lib/services/window/single_instance*.dart`、`lib/services/window/window_chrome_io.dart`、
  `lib/services/window/foreground_activation.dart`、`linux/runner/my_application.cc`、
  `windows/runner/single_instance.{h,cpp}`、`windows/runner/flutter_window.cpp`、
  `macos/Runner/AppDelegate.swift`、`docs/pitfalls.md` #41

## 背景

Molia 最初用 `File.create(exclusive: true)` 抢 `single_instance.lock`，再把
`{"pid","port"}` 写进同一文件；第二实例读到锁后连主实例的 loopback 端口发
`show`，然后 `exit(0)`。这套协议有两个问题：

1. **创建与写内容是两步**：第二进程可能在内容写入前读到空文件，把活锁误判成
   陈旧锁并删除，随后重抢成功，形成两个 primary。
2. **锁生命周期靠 pid 存活与重试**：强杀 / 更新器终止应用会留下已退出进程的
   pid；旧逻辑要等 loopback 超时才能重抢。`release()` 还会在窗口关闭前删除
   锁文件，退出过程中存在被第二实例抢占的窗口。

同时，各平台都有更合适的激活机制：

- Windows 的前台锁会阻止后台进程 `SetForegroundWindow`；第二实例需要先
  `AllowSetForegroundWindow(primaryPid)`。
- Linux 的 `GApplication` 本来就是 D-Bus 单实例 + 激活通道，并把 startup
  notification token 转发给主实例（Wayland 抢焦点必需）；原 runner 显式用了
  `G_APPLICATION_NON_UNIQUE`，等于放弃了这些能力。
- macOS 的 LaunchServices 正常启动本来就单实例，`applicationShouldHandleReopen`
  负责 Dock / 重新打开；只有直接执行 `Contents/MacOS/Molia` 才需要额外兜底。

## 决策

1. **每用户一个 primary**：同一用户同时登录两个桌面会话（Windows RDP / Linux
   多 TTY）也只有一个实例，避免两个进程同时写同一 SQLite、设置与播放会话。
   第二个会话的实例启动后退出。
2. **Dart 文件锁是最终仲裁**：`single_instance.lock` 用
   `RandomAccessFile.lock(FileLock.exclusive)` 抢占（Windows `LockFileEx`，
   Linux / macOS fcntl），进程退出或崩溃由 OS 自动释放。锁文件只做锁，
   pid / port 写到 sidecar `single_instance.json`。锁文件永不删除；`release()`
   只关闭句柄，正常退出不需要调用。
3. **原生快速路径只负责同会话的「引擎启动前退出 + 激活」**：
   - Windows：runner 在 `wWinMain` 创建 `Local\` 命名 mutex（名称带用户 SID）；
     第二实例在 Flutter 引擎创建前退出，找到主实例的隐藏宿主窗口后
     `AllowSetForegroundWindow(primaryPid)` + 投递注册消息。
   - Linux：runner 使用 `GApplication` 默认唯一标志；重复 `activate` 不再建
     第二扇窗，而是经窗口通道转 Dart `WindowChrome.show()`。无 session bus 时
     回退 `G_APPLICATION_NON_UNIQUE`。
   - macOS：维持 LaunchServices + `applicationShouldHandleReopen`；直接执行
     二进制的第二进程仍走 Dart 文件锁。
4. **移动端交给系统**：Android 保持 `launchMode="singleTask"` +
   `onNewIntent`；iOS 由系统保证单进程。不在移动端引入锁文件。
5. **测试逃生口**：`MOLIA_SINGLE_INSTANCE_DISABLED=1` 必须在 Windows / Linux
   runner 与 Dart 都生效，否则 `flutter run` / 集成测试会被原生快速路径提前退出。

## 取舍

- **不把 Windows mutex 做成跨会话全局对象**：`Global\` 命名对象对普通用户
  不可靠（需要特权）；跨会话由每用户文件锁兜底，代价是第二个会话的实例会先
  启动 Flutter 引擎再由 Dart 退出。
- **不在 Windows / Linux 删除锁文件**：删除 + 重建会造成旧 inode / 新 inode
  各锁一份的双 primary 竞态；锁文件残留的内容不参与判断。
- **不使用 macOS `LSMultipleInstancesProhibited`**：它让 LaunchServices 直接
  报错，而不是聚焦已有实例；正常启动 LaunchServices 已经单实例，锁文件负责
  直接执行二进制的兜底。
- **不改 Android 为 `singleTop`**：当前只有一个 Activity，`singleTask` 已满足
  单任务语义；改成 `singleTop` 不会增加约束，反而要额外处理任务栈。
- **原生快速路径不可用时保守回退**：文件锁打开 / 锁不可用（例如文件系统不
  支持锁）按 primary 继续，单实例不能成为启动前置条件；锁冲突但没有 metadata
  时短暂等待后按 secondary 退出，避免双开。

## 影响

- `single_instance.lock` 不再承载元数据；新增 `single_instance.json`。
- 旧版 `single_instance.lock` 内容被忽略；Windows 旧 Roaming 锁的升级守卫
  保留（`process_liveness.dart` 只服务于它）。
- Windows / Linux runner 增加单实例快速路径；Windows 新增
  `single_instance.{h,cpp}` 与隐藏宿主窗口。
- `WindowChrome._installReopenHandler` 从 macOS 扩展到三个桌面平台。
- `docs/pitfalls.md` #41、`docs/performance.md` §5.6、`GLOSSARY.md` 同步更新。

## 验证

- 并发启动多次只保留一个进程；强杀 / 更新后下次启动无陈旧锁等待。
- Windows 第二实例 <500ms 退出；窗口可见、最小化、托盘隐藏三种状态都能恢复。
- Linux Wayland / X11 第二实例在引擎启动前退出并聚焦已有窗口；无 D-Bus 时
  回退非唯一模式仍能启动。
- macOS Dock 点击、`open -a`、`open -n`、直接执行二进制行为符合预期。
- Android launcher / widget / 通知入口不产生第二个任务；iOS 冷启动 / 后台恢复
  无变化。
