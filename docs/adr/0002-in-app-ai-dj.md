# ADR-0002：内置 AI 推歌（用户自备 Key + 闭卷生成 + 本地解析）

- 状态：已采纳
- 日期：2026-10-11
- 相关：`lib/services/ai/**`、`lib/providers/ai_dj_provider.dart`、
  `lib/domain/models/ai_dj.dart`、`lib/playback/local_playback_service.dart`（enqueue）、
  issue #9；能力输入来自 Phase 1 听歌统计（issue #8）

## 背景

项目定位原为「纯播放器，**明确不含 AI 功能**」。项目 owner 提出「根据历史听歌让 AI
推荐歌曲」的需求，且明确了形态：**应用内**调用在线 LLM（非导出到外部工具），
用户自备 API Key，同时保留导出 JSON 的能力。Phase 1 已完成事件级听歌统计
（`play_events` + 导出 JSON），天然可作为画像输入。

需要一次显式的定位变更记录：应用将首次出现「把用户数据发往第三方服务」的通道。

## 决策

1. **定位调整**：AI 推歌是**可选功能**（默认关闭、入口在设置›数据管理与统计页），
   不属于核心播放链路；AGENTS.md 的「明确不含」移除「AI 功能」。
2. **形态**：内置在线 LLM，OpenAI-compatible Chat Completions 协议
   （Base URL / API Key / 模型可配，预设 DeepSeek / OpenAI / 自定义）。
   **不提供内置 Key 与服务端中转**；Key 存 `flutter_secure_storage`。
   Web 平台隐藏入口（CORS 与密钥安全）。
3. **数据边界**：上行「聚合画像 + 最近 200 条明细 + 已听排除清单」
   （上限集中在 `TasteProfileBuilder`）；不含 raw payload、不含设备信息；
   首次开启前置隐私确认弹窗；错误信息不含 Key。
4. **生成方式：闭卷生成 + 本地解析**。LLM 只负责选歌（纯 JSON：
   `title/artist/reason`），本地 `CatalogService.search` 在用户已启用的可搜索
   音源解析成可播放曲目，解析失败丢弃（页面折叠展示「未找到」）。
   推荐结果 100% 可播放，且不依赖平台相似度 API。
5. **模式（电台）语义**：批次 20 首；队列剩余 ≤5 首后台续推；跳过 = 被切走时
   未达 `min(30s, 50%×时长)`（复用统计口径），**只做曲目级排除**；
   喜欢 = 收藏（回流下一批）；连续 3 次失败自动停止续推；退出模式保留队列。
6. **播放内核新增 enqueue**：`PlaybackFacade/Backend.enqueueTracks` +
   `LocalPlaybackService.enqueueTracks`——顺序模式追加队尾；洗牌模式把新下标
   扩展到排列尾部（`PlaybackShuffleOrder.extend`），轮末重洗覆盖全队列。

## 后果

- 应用出现首条用户数据外发通道：默认关闭 + 确认弹窗 + 只发聚合/近期数据，
  关闭开关不采集（统计侧另有独立开关），删 Key 即断联；
- 播放内核获得队列追加能力（AI 续推使用；未来队列面板可复用），
  洗牌追加语义有单测覆盖（老歌不被重排、追加歌轮内可播）；
- LLM 的可用性与费用由用户自己的 Key 承担；失败统一归一化为 `SourceFailure`
  并保留当前播放（不打断听歌）；
- Phase 1 的逐事件统计与导出 JSON 直接作为画像输入与兜底能力，无需返工；
- 定位文档（AGENTS.md）与术语（GLOSSARY）随实现更新。
