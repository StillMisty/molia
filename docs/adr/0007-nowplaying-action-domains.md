# ADR-0007：播放页操作域划分（歌词域 / 曲目域 / 播放域）

- 状态：已采纳
- 日期：2026-10-14
- 相关：`lib/widgets/lyrics.dart`、`lib/widgets/track_info_view.dart`、
  `lib/widgets/track_actions.dart`、`lib/pages/track_cache_page.dart`、
  `lib/providers/comments_provider.dart`、`lib/services/track_cache_service.dart`

## 背景

播放页（`lib/pages/nowplaying.dart`）有三个操作面：展开态播放器进度排、
歌词页快捷操作栏、歌曲信息页。此前操作入口按「UI 状态」而不是「数据归属」
分布——歌词栏同时承载歌词操作（居中跟随 / 复制模式 / 选择海报）与曲目操作
（换源 / 评论），而展示曲目数据（渠道 / 音质 / 缓存）的信息页没有任何曲目
操作入口。由此产生的错位：

1. **音频换源有数据没入口**：信息页展示渠道 / 音质 / 取链缓存，但换源页
   音频 tab 只能从歌词栏进，且默认落在歌词 tab（想换掉坏渠道要先切 tab）；
2. **评论入口与能力来源分家**：评论能力位来自渠道（信息页数据），入口却只在
   歌词栏；同一判定有两份实现（歌词页内联读 `SourceRegistry` 与
   `CommentsProvider.supports`）；
3. **歌词来源有数据无展示**：`LyricsState.providerName` 无人消费；
4. **跨页不刷新**：歌词换源 / 封面补取写缓存后，信息页缓存占用陈旧
   （`TrackInfoView` 只在切歌或本页清理后重算）；
5. **清缓存一点即清**：信息页四个缓存行与全局缓存页单分区清理都无确认，
   与「删除下载」的确认口径不一致；
6. **音频缓存状态撒谎**：边播边缓存只在 Android / iOS / macOS 启用
   （`LocalPlaybackService._platformSupportsAudioCaching`），桌面 / Web
   一律显示「无缓存」，把「平台不缓存」当成了「没有缓存」。

## 决策

1. **操作按作用对象分三域**：
   - **歌词域**（歌词会话 / 来源 / 展示 / 导出）→ 歌词页；
   - **曲目域**（身份 / 渠道 / 音质 / 缓存 / 下载 / 评论）→ 歌曲信息页；
   - **播放域**（播放模式 / 收藏 / 定时关闭）→ 播放器进度排 + 信息页（定时）。
2. **歌词页操作收敛为 FAB menu**（`M3EFabMenu`，带文字 label）：
   换歌词、复制模式、歌词选择 / 海报、居中跟随（仅手动滚动 + 同步歌词时入列）；
   无歌词时 = 换歌词 + 歌词显示设置（凑 `M3EFabMenu` 的 2 项下限）；无曲目时
   隐藏。换源 / 评论从歌词栏移除。显隐语义不变（收起态或复制模式必须可见；
   同步 + 可滚动只在手动暂停时显示；不同步 / 不可滚动手动滚动临时 3 秒；
   隐藏态 `IgnorePointer` 不挡「到顶下拉」）。
3. **信息页新增「曲目操作」区**：换源（默认音频 tab，本地曲目隐藏）、评论
   （能力位单一来源 `CommentsProvider.supports`，不支持时行内说明）；歌词行
   展示来源 + 缓存占用，点击进入歌词操作（换歌词 / 重新获取歌词）。
4. **单曲缓存清理收敛到子页**：信息页缓存区一行入口 → 单曲缓存子页
   （四项占用 + 逐项确认清理 + 全部清理）；全局缓存管理页补单分区确认。
   缓存占用经 `TrackCacheService.revision` 跨页刷新。
5. **音频缓存状态如实呈现**：平台不支持 / 缓存已关闭 / 未缓存 / 已缓存
   分开展示，不再一律「无缓存」。
6. **复制模式保留单曲循环副作用但明示**：进入时提示已切单曲循环、退出恢复
   原模式（不改动播放域状态本身）。
7. **下载**：下载时选音质（默认偏好音质，列出可用音质 + 体积）；所选音质的
   完整缓存文件命中时直接拷贝到下载目录，不触网；公共目录策略见 #17
   （桌面默认系统公共下载目录下 `Molia/`，Windows 走 Known Folder；Android
   播放副本在应用目录、默认另存一份到 `Download/Molia`；导出同口径）。

## 取舍

- **换歌词保留两个入口**（歌词页 FAB + 信息页歌词行）：快捷面与数据面各取
  所需，共用同一打开编排（`lib/widgets/track_actions.dart`）；其余操作单入口。
- **`M3EFabMenu` 不支持 disabled 项**：条件项只能增删，因此无歌词时用
  「换歌词 + 显示设置」凑 2 项下限，而不是展示禁用项。
- **不做「信息页只读」**：曲目操作必须与曲目数据同页（此前「信息页不额外加
  按钮」的取向被本 ADR 取代）。
- **不做**换源页默认 tab 的自适应（入口各按域给默认 tab：歌词页 → 歌词，
  信息页 / 收藏页 → 音频）。

## 影响

- 歌词页底部胶囊换为 FAB menu，`_bottomOverlay` / `_tailSpace` 锚点按 FAB
  尺寸重算；`nowplaying_test` 的换源入口断言随入口迁移更新；
- `TrackInfoView` 新增对 `LyricsProvider`（来源 / 占用）与
  `CommentsProvider`（能力位）的依赖；缓存区改为子页入口；
- 新增 `lib/pages/track_cache_page.dart`（单曲缓存子页）与
  `lib/widgets/track_actions.dart`（曲目操作打开编排）；
- `docs/architecture.md` 的评论 / 换源 / 下载 / 缓存 UI 段落同步更新。

## 后续（ADR-0008，2026-10-15）

本 ADR 的「曲目域」划分与「清理需确认」保留不变；其中「下载弹层 + 单曲缓存
子页」两个面在 ADR-0008 中合并为**「本地数据」页**
（`lib/pages/track_local_data_page.dart`），`TrackCacheService` 更名
`TrackLocalDataService`，缓存命中不再显示「已下载」而是「已缓存」（可离线
使用 / 转存）。上文的文件路径为决策当时的记录，不再回改。
