# ADR-0032：Windows 贴靠布局、虚拟桌面跟随与窗口位置分组

- 状态：已采纳
- 日期：2026-11-15
- 相关：`lib/services/window/window_chrome_io.dart`、
  `lib/services/window/window_bounds_store.dart`、`lib/services/window/window_bounds.dart`、
  `lib/app/desktop/window_controls.dart`、`lib/app/desktop/now_playing_bar.dart`、
  `lib/pages/nowplaying.dart`、`lib/widgets/now_playing_layout_metrics.dart`、
  `windows/runner/flutter_window.{h,cpp}`、`windows/runner/CMakeLists.txt`、
  `docs/pitfalls.md` #109 / #110、ADR-0004

## 背景

桌面端隐藏原生标题栏后，三件与「窗口位置分组」有关的能力缺失：

1. **Win11 贴靠布局失效**：系统最大化键随标题栏一起消失；Windows 只有在窗口
   对 `WM_NCHITTEST` 在最大化键区域返回 `HTMAXBUTTON` 时，才会在悬停时弹出
   贴靠网格（Snap Layouts）并让 Win+Z 有锚点。自绘按钮完全没有告诉系统
   「最大化键在哪」。
2. **贴靠区放不下**：原最小窗口 900×600。微软要求最小宽度 ≤500 epx 才能覆盖
   主流贴靠布局（1080p 四宫格 = 480 宽、1366 三栏 = 455）；即使网格弹出，
   窗口也会被最小尺寸顶出区域。
3. **虚拟桌面不跟随、位置不分组**：窗口只在创建时归属当时的活动桌面。关闭到
   托盘后用户切到另一个桌面，`ShowWindow` 不会把窗口搬过去，表现为「点了托盘
   没反应」；全局只存一份窗口矩形，不同虚拟桌面无法各记各的位置。

Snap Groups 本身由系统维护，应用侧只需要「窗口可贴靠 + 最大化键可识别」；
Win32 没有公开接口把「已贴靠」状态跨进程重启恢复，因此本次只恢复矩形。

## 决策

1. **上报最大化键矩形，恢复贴靠布局**（Windows only）
   - `WindowChrome.setMaximizeButtonBounds(Rect?)` 调 nativeapi 的
     `Window.setMaximizeButtonBounds`；坐标是逻辑像素、相对内容区左上角，
     空矩形清除。
   - UI 侧 `MaximizeButtonSnapRegion` 包住最大化键，用 `RenderProxyBox` 在每次
     布局后按帧测量并只在矩形变化时上报；卸载（如收进托盘的休眠树）时清空。
   - 非 Windows / 窗口未就绪 / 原生不支持时为空操作，构建期调用不会碰原生
     测试环境（pitfalls #30）。
2. **最小窗口 480×400**（`kMinimumWindowSize`）
   - 宽度对齐微软的 ≤500 epx 建议；高度只影响手动缩放，贴靠区通常 ≥480。
   - 桌面骨架配套窄版式：底栏在 <720 时换 64dp 紧凑单行（曲目 + 传输 + 队列，
     模式 / 音量留在播放页）；播放页两栏只在 expanded（≥840）启用（左栏
     360–480 自适应、优先保右栏 420），窄窗口走单栏；小屏完整播放器的标题 /
     进度排预留高度随 `textScaler` 放大。
3. **虚拟桌面跟随**（Windows only）
   - runner 新增窗口通道 `ensureOnCurrentDesktop`：
     `CoCreateInstance(CLSID_VirtualDesktopManager)` →
     `IsWindowOnCurrentVirtualDesktop`；不在当前桌面时，用一个 1×1、屏幕外、
     不激活的 `WS_POPUP | WS_VISIBLE` 探针窗口拿当前桌面 GUID（新窗口落在
     当前桌面），`MoveWindowToDesktop` 把主窗口搬过去，然后销毁探针。
   - `WindowChrome.show()` 在显示前调用（300ms 超时，失败按原行为显示），
     覆盖托盘恢复与单实例 `reopen` 两条路径。
   - 只用公开的 `IVirtualDesktopManager`，不碰未公开的桌面切换接口。
4. **按虚拟桌面分组记忆几何**（Windows，`rememberBounds` 开启时）
   - 存储键：`window_bounds_by_desktop` / `window_maximized_by_desktop`，
     键是原生规范化的桌面 GUID（小写、无大括号），每条带 `savedAt`；
     每个分组最多 8 条，按最近使用淘汰。旧 `window_bounds` /
     `window_maximized` 四键只读兜底。
   - 恢复优先级：该桌面 → 最近使用的分组 → 旧全局键；最大化标记只认同一
     桌面（某桌面有几何但从未最大化时不继承其它桌面的状态）。
   - 托盘 / 单实例恢复且真的搬过桌面时，在 show 之前套用**目标桌面自己的**
     几何（没有该桌面的记录就保持当前几何，不继承其它桌面）；窗口还隐藏，
     用户看不到跳变；先在最大化态下 `unmaximize` 再应用 bounds，show 后按
     分组补 `maximize`。
   - 保存路径仍分两条：几何防抖 600ms，最大化事件即时写入；各自写自己的键，
     不互相覆盖。

## 取舍与限制

- **Snap 状态不跨重启**：只保存矩形；重启后是普通浮窗而不是贴靠组成员。
  Windows 对 Win32 应用没有公开的「恢复贴靠状态」接口。
- **桌面 GUID 只在桌面存在期间稳定**：删除 / 重建虚拟桌面会留下旧键；靠 8 条
  上限淘汰，恢复时回退最近分组，不会丢窗口。
- **探针窗口依赖系统行为**：极少数环境（远程桌面 / Windows Sandbox / 虚拟
  桌面服务不可用）可能拿不到 GUID；失败时不做任何移动，窗口按原行为显示。
- **Win10**：贴靠布局只在 Win11 出现；Win10 悬停只显示最大化 tooltip，点击与
  hover 仍正常（nativeapi 在同一命中区把客户端消息转发回 Flutter）。
- **非 Windows**：贴靠、虚拟桌面跟随、按桌面分组全部空操作；Linux 工作区 /
  macOS Space 不在本次范围。
- **不新增设置项**：贴靠与虚拟桌面跟随默认生效；分组记忆沿用「记住窗口位置」
  开关。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（含贴靠区矩形上报、按桌面分组存储、480 / 900 /
  1280 宽桌面布局与 200% 字号）；
- `dart run tool/agent/cli.dart test linux`：窗口 chrome / 托盘端到端不回归；
- 集成测试 Windows 分支：写入最大化键矩形 → 原生回读一致 → 清空；
- Windows 11 真机人工清单：
  - 悬停最大化键弹出贴靠网格、Win+Z 有锚点、点击仍最大化 / 还原；
  - 100% / 150% / 混合 DPI 下网格锚点不偏；
  - 贴靠两窗后任务栏悬停显示 Snap Group；
  - 1080p 四宫格 / 1366 两栏能落进区域，480×400 无溢出；
  - 托盘隐藏 → 切虚拟桌面 → 恢复，窗口出现在当前桌面；
  - 桌面 1 / 2 各摆不同位置并最大化，重启后按所在桌面恢复。

## 未验证

- Windows 真机构建与上述人工清单（本机为 Linux，`flutter build windows` 需在
  Windows 侧执行）；探针窗口在远程桌面 / 虚拟桌面服务异常时的行为只按「失败
  静默」设计，未实测。
