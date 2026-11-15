# ADR-0031：工具链统一到 Dart CLI，sh / ps1 / py 逐条退役

- 状态：已采纳（首批迁移中）
- 日期：2026-11-15
- 相关：`tool/agent/cli.dart`、`tool/agent/src/`、`tool/agent/*.sh`、
  `tool/agent/*.ps1`、`tool/agent/*.py`、`docs/dev_workflow.md`、`AGENTS.md`

## 背景

`tool/agent/` 里同一件事被实现了三遍：

- `*.sh`（18 个，约 3.9k 行）：Linux / WSL 专用，依赖 bash、Xvfb、`/proc`、
  `dbus-run-session`、`SIGUSR1/2`；
- `*.ps1`（5 个，约 0.5k 行）：Windows 专用采样，命令面与 sh 不成套；
- `*.py`（3 个，约 0.9k 行）：`check_docs` / `apk_size` / timeline 汇总，需要
  单独装 Python。

后果是 Windows 开发机没有 bash 就基本用不了本仓的自动化；而三套实现各自
漂移（同一个帧场景的判定、同一个 APK 约束的文案都可能只改了一边）。
Flutter 开发者一定装了 which 运行时？只有 Dart —— 这是唯一可以要求「各端都有」
的依赖。

## 决策

1. **唯一入口是 `dart run tool/agent/cli.dart <命令>`**。只用 `dart:io`，不引
   第三方包：ZIP 中央目录、`/proc` 解析这类小需求自己实现，避免给工具链加
   长期维护面。
2. **平台差异收敛到 `tool/agent/src/context.dart`**（仓库路径、`PATH` / `PATHEXT`
   查找、Android SDK、`RUN_DIR`、进程启动与超时），命令内部再按
   `Platform.isWindows` 选执行方式；平台专有能力（Win32 滚动 / 截图、Xvfb、
   `dbus-run-session`、`/proc` 采样）保留为平台后端，由 CLI 调用，而不是各写一套命令面。
3. **迁移分层，按风险递进**：
   1. 只读命令（`info`、`deps`、`size apk`、`perf report`）；
   2. 无状态编排（`analyze`、`test`、`smoke`）；
   3. 有状态编排（`app` 用 `flutter run --machine` 协议替代 `SIGUSR1/2`、`emu`）；
   4. 采样与注入（`perf`、`startup`、`cpu`、`memory`、`io`、`seed`）。
4. **旧实现的退役条件**：某条命令的 Dart 版通过 `flutter analyze` + 全量测试、
   并在 `docs/dev_workflow.md` 登记后，才删除对应的 `.sh` / `.ps1` / `.py`；
   删除前两套并存，文档标注「迁移中」。
5. **新需求只加 Dart**：除平台专有后端（Win32 / Xvfb / `/proc`）外，不再新增
   `.sh` / `.ps1` / `.py` 工具；一次性需求仍按 `docs/dev_workflow.md`「原则」第 6 条走
   官方命令。

## 追加：Windows 采样改为 Dart + FFI（2026-11-15）

`*.ps1`（memory / frames / startup / scroll）原来承担 Windows 侧全部采样。
现已迁到 `win mem|scroll|frames|startup`（`tool/agent/src/win32.dart` 只绑定
user32 / psapi / kernel32 的必要函数，不引第三方包）。`.ps1` 保留为
Windows 侧验证通过前的兜底，不在 CLI 路径上——除 `win` 覆盖的四类采样外，
Windows 上其它命令明确报错并指向 Linux/WSL。

## 后果

- Windows 开发机第一次有了与 Linux 等价的入口；`deps` / `size apk` 这类门禁
  命令可以在三端跑同一条命令。
- 热重载从信号（`SIGUSR1/2`，Windows 没有）改成 `flutter run --machine` 协议，
  顺带解决 Windows 上「脚本化热重载」缺位的问题。
- 迁移期内仓库里会同时存在 `.sh` 与 Dart 同功能实现，`docs/dev_workflow.md`
  必须标注哪条命令已经迁移，避免两边各改一半。
- 工具逻辑进了 `test/tool/`，可以像业务代码一样被 `flutter test` 覆盖
  （首批已有 ZIP 中央目录、APK 约束、frames 汇总的用例）。
