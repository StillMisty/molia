# ADR-0035：平台音频会话生命周期与 Android 混播焦点

- 状态：已采纳
- 日期：2026-11-18
- 相关：ADR-0010、issue #62、`lib/playback/platform_audio_port.dart`、
  `lib/playback/audio_session_lifecycle.dart`、`lib/playback/audio_focus_guard.dart`、
  `lib/playback/audio_focus_policy.dart`、`lib/playback/local_playback_service.dart`、
  `lib/app/bootstrap/playback_stack.dart`、`docs/pitfalls.md` #113 / #114

## 背景

三条缺陷同一个根因：平台音频会话的生命周期没人拥有，Android 焦点的请求方式
又和「与其他应用同时播放」的设置相反。

1. **iOS 冷启动抢音频**：组合根在首帧前初始化系统媒体会话，Darwin 后端在激活
   路径里自行 `setCategory(.playback)` + `setActive(true)`，覆盖了 `audio_session`
   配置的 `mixWithOthers`。仅仅打开 Molia 就会打断其他应用。
2. **从不释放**：`just_audio` 在 `play()` 里激活会话、从不 `setActive(false)`；
   应用也没有任何释放调用。暂停 / 停止后仍占着会话与焦点，其他播放器无法恢复。
3. **Android 混播不混**：会话配置从 `AudioSessionConfiguration.music()` 派生
   （普通 `gain`）并把 `willPauseWhenDucked` 固定为 true；起播就请求完整焦点，
   导航提示还会被升级成 transient 暂停，而混播分支忽略它——既不暂停也不压低。

## 决策

### 唯一所有者与端口

- 新增 **`PlatformAudioPort`**（`lib/playback/platform_audio_port.dart`）：
  `configure` / `activate` / `deactivate(notifyOthers:)`、中断 / 输出丢失 /
  设备变化三条流、`start` / `dispose` 与 `supported` 能力位。移动端适配器
  包装 `audio_session`；桌面（含 macOS）是 no-op，P1 的桌面输出监听复用同一
  端口。**除适配器外，任何模块不得直接调用 `audio_session` 或平台音频 API。**
- **`AudioSessionLifecycle`**（`audio_session_lifecycle.dart`）是配置 / 激活 /
  释放的唯一决策者，状态机 `inactive → active → releasePending → inactive`。
  它不碰队列、会话存储、provider 与 UI，平台失败只记日志并继续。
- `LocalPlaybackService` 构造播放器时同时关闭
  `handleInterruptions: false` 与 **`handleAudioSessionActivation: false`**，
  所有起播路径走同一个「先激活、后 play」helper。服务只向生命周期报告
  起播 / 暂停 / 停止 / 退出；组合根在系统媒体会话工厂返回 handler 后通知
  生命周期（失败不通知）。服务从 `dispose()` 与 `shutdownAudioForQuit()`
  两个入口幂等地释放生命周期与端口。

### 生命周期契约

- **起播**：取消待释放 → 配置（设置变更后）→ 激活。激活被拒（通话 / 焦点被占）
  时保留播放意图，等一次中断结束重试一次；5 秒内没有恢复则按可重试播放失败
  上报并清掉意图，不静默挂起。
- **暂停**：落地后安排 **20 秒**宽限（可注入，单一命名常量）；宽限内续播直接
  取消释放、不重新激活。
- **停止 / dispose / 退出收尾**：立即释放，并取消待释放。
- 释放定时器带代次：被取消 / 被新一次起播取代的 timer 永远不会晚到一步关掉
  刚激活的会话。释放幂等。
- **中断导致的暂停不立即放弃焦点**：Android 上放弃焦点会把本应用移出焦点栈，
  系统就再也不会发 gain 事件，通话结束后无法自动续播。守卫结算这次中断且
  没有续播后才开始宽限计时。
- **永久失焦没有 `end` 事件**：中断暂停会标记「焦点可能已丢」，下一次起播即使
  状态仍是 active 也重新请求一次焦点；正常暂停（非中断）与已结算的中断不会。
- **启动释放只对 iOS**：只有 Darwin 媒体会话后端会绕过端口激活
  `AVAudioSession`；Android 的媒体会话后端不请求焦点，启动钩子是 no-op。
- **平台端口异常不是焦点被拒**：显式 `false` 才等待中断重试；插件缺失 / 通道
  异常降级为「无会话也能播」，不阻塞播放。
- **播放中切换混播设置**：重配置；Android 额外放弃旧焦点再请求一次（gain 类型
  属于请求本身），播放状态与位置不动。
- 每次释放都带 notify-others（iOS 生效，Android 忽略）。

### iOS 启动

系统媒体会话激活成功后：重新应用 `audio_session` 配置（恢复 `mixWithOthers`），
若还没有播放则带 notify-others 立即释放并保持 `inactive`；已经在播放（恢复态
自动起播）则只重配置、不释放。

**回退开关**：若真机矩阵证明暂停释放导致 Now Playing 卡片消失比冷启动打断更糟，
唯一的回退点是「只在停止时释放」——启动释放与其余契约不变。它是文档化的策略
常量，不新增用户设置。当前选择先按完整契约实现，等矩阵结论再决定是否回退。

### Android 混播

- 混播开：`gainTransientMayDuck` + `willPauseWhenDucked: false`（其他播放器
  压低而不是停止；系统提示以 duck 事件到达）。
- 混播关：普通 `gain` + `willPauseWhenDucked: true`（保留独占语义）。
- 纯决策表（`audio_focus_policy.dart::audioFocusActionFor`）：
  - 混播开 Android：`unknown`（永久失焦）→ none 继续播放；`pause` → 暂停；
    `duck` → 压低。
  - 混播关 / Apple / 其它：任何 begin → 暂停。
  - 结束事件：只有本应用暂停过才 `resume`，只有本应用压过才 `restore`。
- **duck 倍数**：默认 0.2，经唯一有效音量路径（用户基值 × 淡变包络 × duck）
  生效，80ms 短斜坡避免爆音。恢复回到**当前**基值（含中途改音量 / 静音）。
  暂停、停止、切歌、永久失焦与起播都复位为 1，duck-end 丢失也不会让下一首
  一直发闷。duck 不改播放状态、位置、队列或历史。

## 后果

- iOS 冷启动不再打断其他应用；混播设置在冷启动后仍然有效。
- 暂停 20 秒 / 停止 / 退出后释放会话与焦点，其他应用可以恢复。
- Android 混播真正「同时播放」，导航 / 语音提示压低音乐并自动恢复。
- 暂停释放后 Now Playing 卡片可能消失或变暗（iOS 主要风险）；回退开关见上。
- **真机验证仍需人工执行**：iOS（设置开 / 关冷启动、宽限内 / 外恢复、通话 /
  Siri、拔耳机 / 蓝牙断开、释放后的锁屏控制、恢复态冷启动）与 Android（两个
  播放器、导航 duck、通话暂停续播、永久失焦忽略、宽限后另一播放器恢复、独占
  模式回归、媒体通知）。结论补写到本文档 / issue。

## 验证

- 纯策略表、焦点守卫（duck / restore / 暂停 / 永久失焦 / 手动取消 / 重新
  attach / detach）与生命周期（fake_async + 记录型端口）单测；
- 播放服务用脚本化假播放器 + 假端口覆盖激活早于 play、宽限期、停止 / 退出
  释放、激活拒绝、duck 音量数学与复位；
- 组合根工厂 seam 覆盖「返回 handler 后才通知、失败不通知」；
- `flutter analyze --no-pub`、`flutter test --no-pub`、`dart run tool/agent/cli.dart docs check`。
