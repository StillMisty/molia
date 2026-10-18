# ADR-0012：Windows 任务栏缩略图按钮与应用身份（图标）

- 状态：已采纳
- 日期：2026-10-19
- 相关：`windows/runner/taskbar_thumb_bar.{h,cpp}`、`windows/runner/shell_identity.{h,cpp}`、
  `windows/runner/flutter_window.{h,cpp}`、`windows/runner/win32_window.cpp`、
  `windows/runner/main.cpp`、`windows/runner/resource.h` / `Runner.rc`、
  `windows/runner/resources/thumbbar/*.ico`、`tool/gen_taskbar_icons.py`、
  `lib/services/window/taskbar_thumb_bar*.dart`、`lib/app/bootstrap/desktop_stack.dart`、
  `.github/workflows/ci.yml`（`windows-dev`）、ADR-0009 / ADR-0011、
  `docs/pitfalls.md` #59 / #60

## 背景

Windows 真机上用户报了两件事：

1. 右击任务栏按钮弹出的菜单，**头部图标是 Flutter 默认图**（按钮本身的图标却是
   品牌图）；
2. 鼠标悬浮任务栏按钮时的预览浮层里**没有播放控制**。

排查结论（都在真机与产物上核对过）：

- molexe 的图标资源（`IDI_APP_ICON`，16…256 共 8 档）与 shell 缓存的 exe /
  快捷方式图标**都是品牌图**；任务栏按钮也是品牌图；
- 窗口只有**类图标**（`GCLP_HICON`），`WM_GETICON` 返回 none、`GWL_HICON` 为 0；
- 进程只调了 `SetCurrentProcessExplicitAppUserModelID`，但
  `HKCU\Software\Classes\AppUserModelId\top.stillmisty.molia` **不存在**，
  也没有自己的跳转列表。

即：任务栏按钮走「窗口 / 类图标」这条实时路径（品牌图 ✓），而右键菜单头部走
shell 按 AUMID 解析并**缓存**的应用身份图标——旧构建（2026-10-16 换图标之前）
留下的记录仍是 Flutter 默认图。这两条路径分裂是本次两个问题的共同根因。

## 决策

1. **启动时落地应用身份**（`shell_identity.cpp`）：写
   `HKCU\Software\Classes\AppUserModelId\top.stillmisty.molia` 的
   `DisplayName` = `Molia`（见 ADR-0011）与 `IconUri` = 当前 exe 全路径，
   值未变化不写（不每次启动都刷新注册表时间戳）。AUMID 与安装器
   `[Icons]`、`main.cpp` 三处保持同一个常量。
2. **窗口显式设图标**（`win32_window.cpp`）：窗口类补 `hIconSm`（`LoadImage` 到
   `SM_CXSMICON`，句柄由类持有并在注销时销毁），`CreateWindow` 之后补
   `WM_SETICON`(ICON_BIG/ICON_SMALL)。让 shell 的所有取图表面都命中确定的图标，
   而不是各自回退。
3. **任务栏缩略图工具栏 = Windows 侧播放控制**（`taskbar_thumb_bar.{h,cpp}`，
   `ITaskbarList3::ThumbBarAddButtons`）：4 个按钮「收藏 / 上一首 / 播放暂停 /
   下一首」，悬浮预览浮层里可用。要点：
   - 按钮只能在窗口**已经出现在任务栏上**之后挂 → `WM_SHOWWINDOW(TRUE)` 时挂，
     失败留给下一次（`ThumbBarAddButtons` 的返回值决定是否重试）；
   - Explorer 重启会清空工具栏 → 监听 `RegisterWindowMessage("TaskbarCreated")`
     重新挂（nativeapi 的托盘 watcher 是另一个窗口，互不影响）；
   - 图标必须是 **32 位、`SM_CXICON`×`SM_CYICON`** 的 HICON，从 `Runner.rc`
     资源载入（`.ico` 覆盖 16…64 全档位，避免系统拉伸）；任务栏**不随主题反色**，
     因此准备两套字形（深色任务栏用亮字形 / 浅色用暗字形），按
     `SystemUsesLightTheme` 切换并在 `WM_SETTINGCHANGE` / `WM_THEMECHANGED` 时重载；
   - 图标资源由 `tool/gen_taskbar_icons.py` 生成（rsvg-convert + PNG 条目 ico），
     产物提交进仓库。
4. **状态与动作由 Dart 驱动**（`lib/services/window/taskbar_thumb_bar*.dart`）：
   通道 `top.stillmisty.molia/taskbar`，Dart→原生 `update`（有无曲目 / 播放态 /
   收藏态 / 四个 tooltip），原生→Dart `pressed`（按钮 id）。
   文案复用 `TrayMenuLabels`，动作复用桌面栈里托盘的那批闭包（
   `desktop_stack.dart`），不新增第二套播放控制路径；状态载荷与上次相同则不下发。
5. **不做的事**：`ICustomDestinationList` 跳转列表（右键菜单里的快捷任务）本次
   不做——身份注册 + 窗口图标已覆盖图标问题；若真机复核后菜单头部仍显示旧图标，
   再加显式跳转列表作为兜底（它会迫使 Windows 重建缓存）。

## 后果

- 悬浮任务栏按钮 → 预览浮层出现 4 个播放控制按钮（无曲目时整体置灰，
  播放 / 收藏态实时同步，tooltip 跟随界面语言）；
- 右击任务栏按钮的菜单头部应显示品牌图标；应用身份注册是幂等的，便携版同样生效；
- 新增原生文件与图标资源进入 Windows 构建；Linux / macOS 不受影响
  （`TaskbarThumbBar.isSupported` 仅在 Windows 为真，其余平台全部空操作）；
- 试构建链路：`ci.yml` 新增**手动触发**的 `windows-dev` job（只出 Windows 便携
  zip + 安装器，不发 Release）——`analyze` / `test` 跑在 Linux 上，覆盖不到
  `windows/runner` 的 C++，改原生代码必须靠它或真机构建验证。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（2322 条），含 `test/services/taskbar_thumb_bar_test.dart`
  的通道契约（字段名 / 按钮 id / 幂等 / 非 Windows 空操作）；
- `tool/agent/test.sh linux`：端到端通过（非 Windows 平台空操作，托盘 / 窗口用例不受影响）；
- CI 试构建（`gh workflow run ci.yml --ref feat/windows-taskbar`，run 39144947225）：
  `Analyze / Test` 与 `Windows 试构建` 两个 job 全绿——Windows runner 的 C++ 编译通过、
  Inno 安装器打包成功；
- 产物核对（`molia-0.1.0-beta.12-dev49-windows-x64`）：
  - exe 资源里 13 个图标组（101 应用图标 + 201…212 十二个按钮图标）、共 92 张图标图；
  - 版本资源 `ProductName = Molia`、`FileDescription = Molia - …`（ADR-0011 生效）；
  - 二进制里能查到通道名与方法名（`top.stillmisty.molia/taskbar`、`update`、`pressed`）
    与宽字符常量（`AppUserModelId` / `TaskbarCreated` / `DisplayName` / `IconUri`）；
- 真机运行时（同一产物，Windows 11 build 26300）：
  - `HKCU\Software\Classes\AppUserModelId\top.stillmisty.molia` 出现
    `DisplayName = Molia`、`IconUri = <该 exe 路径>`；
  - 窗口 `WM_GETICON(ICON_BIG)` 从「无」变成有效句柄，取出即品牌图（修复前三个档位
    全为 none、`GWL_HICON` 为 0）；
  - 窗口标题显示「曲名 · Molia」（品牌名统一生效）、进程正常存活。

## 未验证（需人工在任务栏上点一遍）

自动化点不到任务栏浮层（本机任务栏是 auto-hide + TranslucentTB 动态隐藏，被最大化的
浏览器压住），以下人工复核项待验证：

1. 悬浮任务栏按钮 → 预览浮层出现 4 个按钮，点击能控制播放 / 收藏，状态实时同步；
2. 右击任务栏按钮 → 菜单头部图标为品牌图（不再回退 Flutter 默认图）；
3. 隐藏到托盘再恢复、`explorer.exe` 重启后按钮仍在；
4. 浅色 / 深色任务栏切换 → 按钮字形跟随主题；
5. 用安装器升级后：开始菜单只有 `Molia`，旧「Molia 茉咏.lnk」被清掉（ADR-0011）。

