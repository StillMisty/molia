# ADR-0037：曲间无缝（gapless）播放

- 状态：已采纳（决定暂不实现）
- 日期：2026-11-18
- 相关：ADR-0010、ADR-0034、ADR-0035、ADR-0036、issue #64、
  `lib/playback/local_playback_service.dart`、`lib/playback/next_track_preloader.dart`、
  `lib/playback/queue_projection.dart`、`lib/playback/playback_session_coordinator.dart`、
  `lib/playback/fade_envelope.dart`、`lib/playback/audio_focus_policy.dart`、
  `docs/platform_media_checklist.md`

## 背景

「曲间无缝」指相邻曲目之间没有可听的静音或解码器重建空档，通常还要求正确处理有损编码
的 encoder delay / padding。它和「下一首预取」不是同一件事：预取只缩短等待，不负责接缝。

用户报告与代码审查里反复出现同一问题：单曲 / 专辑连播时能听到曲间空档。本文把它记录为
一次明确的架构决策，避免每次评审都重新讨论同一组方案。

**测量口径说明**：本轮没有做端到端接缝测量，因此下文只把**代码路径**记为事实，不宣称
具体毫秒数。若未来推进，先用可复现的音轨接缝样本测量「上一首结束 → 下一首可听」的
空档，再决定方案。

## 当前行为（事实）

1. **每次切歌都是一次完整的停止 → 取链 → 单源重建。**
   `LocalPlaybackService` 在需要卸载旧源时先 `_player.stop()`（释放解码器 / 平台播放器），
   然后 await 取链（`_resolver`），再对**单一 source** 调用 `setAudioSource`，最后
   `play()`。旧源不会在取链期间继续出声，也不存在「下一首已解码、等待接缝」的状态。
2. **下一首预取只预热 URL / 字节，不做交接。**
   `NextTrackPreloader` 在起播后取下一首的完整 `PlayableStream`（命中 CatalogService 的
   取链缓存），并在策略允许时把音频字节预下载到缓存文件；它不会把准备好的 source 交给
   播放器，也不持有第二个解码器。命中缓存能减少取链等待，但 stop + 单源重建仍然存在。
3. **队列顺序与播放会话的所有权不在播放器里。**
   `queue_projection.dart` 与 `PlaybackSessionCoordinator` 共同拥有当前下标、上一首 /
   下一首 / 历史、播放模式与恢复态；`LocalPlaybackService` 只播放「当前一首」。
   任何把多首交给播放器的方案都会引入第二份顺序状态。
4. **可播流请求头与直链时效是全路径契约。**
   `PlayableStream.headers` 必须随每次 `AudioSource.uri` / `LockCachingAudioSource` 传递；
   远程直链带 `expiresIn`，提前解析的地址可能在真正播放前过期（B 站等平台尤其明显）。
5. **失败恢复以「当前一首」为单位。**
   `PlaybackErrorRecovery` 失效当前曲目的取链缓存、原地重取、整首重试、再换源；它假设
   播放器里只有一个当前 source。播放器自动前进会绕过这条恢复链。

## 方案评估

矩阵列与 issue #64 的评估口径一致。接缝质量是「能否做到样本级连续」，不是「听起来是否
好一点」。

| 方案 | 接缝质量 | 平台覆盖 | 与队列投影 / 会话所有权冲突 | 取链缓存 | 直链 header 过期 | 错误恢复 | 工作量 / 风险 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A. 播放器内 playlist / audio-source window（`setAudioSources` / 播放列表） | 最好：平台支持时可做到连续；Android / 桌面 / Apple 的实现与限制不同，仍需逐端验证 | 所有 `just_audio` 平台都有列表 API，但真正无缝取决于后端：桌面需要 media_kit 的实验性 `prefetchPlaylist`（mpv `--prefetch-playlist`），Apple 侧要确认 AVPlayer / AVQueuePlayer 的队列行为 | **高**：播放器持有第二份顺序；队列编辑、shuffle、恢复态、上一首语义都要双向同步 | 会提前持有已解析 source，弱化「按需取链」 | **高**：远程地址提前解析后可能在播到它之前过期；需要刷新 / 重新解析机制 | 播放器可能自动前进，失败时当前下标与真实播放错位；现有恢复链要重写 | 中高：跨端差异大，回归面覆盖队列 / 会话 / UI |
| B. 双播放器预加载 + 交接（第二个 `AudioPlayer` 或双 source 轮换） | 接近无缝，但取决于交接调度精度；不是所有后端都能样本级对齐 | 所有平台可做，但移动端后台策略、桌面 mpv、Apple 后端各自有预加载与时钟差异 | **高**：第二播放器会复制媒体会话、输出端口、淡变包络、缓存写入与当前曲目所有权；需要显式 handoff 状态机 | 可复用下一首缓存 / 已解析流 | 中：窗口比 A 短，但仍需处理过期与重解析 | **高**：交接中下一首失败要回退到单源路径，且不能重复写缓存 / 重复上报会话 | 高：最容易引入「两个播放器同时出声」或「会话指向错误曲目」 |
| C. 仅本地窄路径（本地文件 + 已完成缓存条目） | 好：没有网络取链，接缝只剩解码器调度；可先做到「本地专辑连播无明显空档」 | 覆盖所有平台的本地子集；远程曲目继续走现有单源路径，行为可预测 | **中**：仍要决定「相邻两首是否都本地」的交接规则，但队列 / 会话继续是唯一权威，窄路径可随时回退 | 不需要取链；缓存条目已是完整文件 | 无（本地文件 / 完成缓存没有远程直链） | **低**：任一侧不满足条件就回退到现有逐曲路径，恢复链不变 | 中低：范围可控，可先用现有播放器能力验证，不承诺全平台样本级无缝 |

补充说明：

- A 的「lazy prepend（临近曲末才把下一首加入播放器列表）」只是把冲突推迟，不消除第二份
  顺序状态；远程地址过期与失败前进仍然存在。
- 任何方案都不能绕过 `PlayableStream.headers` 契约；把 headers 丢在播放器列表外会让 B 站
  直链 403。
- Android 的 gapless 能力与编码 / 容器有关（Media3 会处理部分格式的 encoder delay /
  padding）；桌面 mpv 的 `--gapless-audio` 与 `--prefetch-playlist` 是不同开关，前者是
  解码连续性，后者是预取，二者都不能替代本仓的队列所有权设计。参考：
  [Media3 media sources](https://developer.android.com/media/media3/exoplayer/media-sources)、
  [Media3 glossary: gapless](https://developer.android.com/media/media3/exoplayer/glossary)、
  [AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)、
  [mpv `--gapless-audio`](https://mpv.io/manual/master/#options-gapless-audio)、
  [mpv `--prefetch-playlist`](https://mpv.io/manual/master/#options-prefetch-playlist)、
  [`just_audio` `setAudioSources`](https://pub.dev/documentation/just_audio/latest/just_audio/AudioPlayer/setAudioSources.html)、
  [`JustAudioMediaKit.prefetchPlaylist`](https://pub.dev/documentation/just_audio_media_kit/latest/just_audio_media_kit/JustAudioMediaKit/prefetchPlaylist.html)。

## 决策

**本次不实现 gapless，任何形式都不实现。** 包括：播放器内播放列表、lazy prepend、双播放器
交接、开启上游 `prefetchPlaylist`、为无缝而更换播放后端。

理由：

- 收益集中在「专辑连播」这一较窄场景，但成本落在播放服务、队列投影、会话持久化、错误
  恢复与三端播放后端，属于高回归面改动；
- 现有预取已经把「取链等待」压到较低，真正剩下的接缝需要样本级测量才能判断是否值得；
- 队列 / 会话所有权是本仓的核心不变量（ADR-0034 的模块边界、ADR-0035 的音频会话、
  ADR-0011 / ADR-0017 的会话恢复），不应为了接缝引入第二份顺序状态。

**如果未来推进，先做方案 C（仅本地窄路径）**：只在相邻两首都已经是本地文件或完整缓存
条目时尝试无缝交接，远程 / 未缓存曲目继续走现有逐曲路径。它不引入取链 / header 过期
问题，失败时可以直接回退，也不需要先解决全平台播放列表所有权。

## 后果

- 远程曲目与本地曲目都保留当前可听的曲间空档；本 ADR 不改变任何播放行为。
- 不新增依赖、不新增设置、不改变队列 / 会话 / 媒体会话 / UI。
- 评审中再出现「为什么不做 gapless」时，指向本文，而不是重新开一轮方案讨论。
- 若未来实现方案 C，仍需要：本地接缝样本、缓存条目完整性判定、回退路径测试、三端
  真机听感验证；这些都不在本工作流内。

## 重新评估的触发条件

满足任一条件再开新决策（不是待办清单）：

1. **持续的专辑接缝投诉**：多个独立用户报告同一类「专辑连播有可听空档」，而不是单次
   主观偏好；
2. **上游桌面预取转正**：`just_audio_media_kit` 的 `prefetchPlaylist`（mpv
   `--prefetch-playlist`）不再是「highly experimental」，且行为在 Windows / Linux 可复现；
3. **播放后端变更让顺序所有权变便宜**：例如新的后端原生接受队列、且不需要应用维护第二份
   当前下标 / 会话状态；这时重新评估方案 A，而不是直接套用本文的矩阵。

## 验证

本决策不改变运行时行为，因此没有新的播放测试。已执行的仓库门禁：

- `flutter analyze --no-pub`；
- `flutter test --no-pub`（含 `test/architecture/platform_config_test.dart`）；
- `dart run tool/agent/cli.dart docs check`。

若未来实现：至少需要本地专辑接缝样本、缓存条目命中 / 未命中、远程曲目回退、下一首失败
恢复、媒体会话当前曲目一致性五组测试，再加三端真机听感验证。
