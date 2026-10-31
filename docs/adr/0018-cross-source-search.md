# ADR-0018：跨音源聚合搜索、来源排序与键盘模型

- 状态：已采纳（2026-10）
- 相关：`lib/providers/search_provider.dart`、`lib/providers/search_session.dart`、
  `lib/providers/search_source_group.dart`、`lib/widgets/search_results_view.dart`、
  `lib/widgets/global_search_overlay.dart`、`lib/services/key_claims.dart`、
  `lib/data/settings/settings_keys.dart`、`docs/architecture.md`

## 背景

桌面全局搜索（Ctrl+F）原先只搜「一个当前音源」。`SearchProvider` 在
`main.dart` 里 `runApp` 前构造，那时只有 B 站具备搜索 + 原生取链；五个音乐
平台要等首帧后 LX 脚本加载才变成可搜索源。`_onSourcesChanged` 只在当前源
失效时回退，不会在脚本晚加载后重新选源，于是搜索被钉死在 `bili`；唯一能改
搜索源的入口是发现页的 `syncSearchSource`，表现为「打开过发现页才有其它
平台」。

同时，全局搜索遮罩不显示当前来源、没有来源选择；发现页渠道与搜索来源被
绑在一起，用户切热榜渠道会意外改掉搜索源。

## 决策

1. **每个「搜索类型 × 来源」一个会话**：`SearchProvider` 不再持有单一
   `sourceKey`，而是按 `SearchKind` 维护 `Map<String, SearchSession<T>>`。
   每个来源复用 `PagedListController` 的首屏 / 加载更多 / 失败 / 过期响应 /
   跨页去重语义；查询按来源并行 fan-out，单源失败只挂在该来源分组。
2. **只读分组投影**：新增 `SearchSourceGroup<T>`（source / items / failure /
   isLoading / hasMore / isLoadingMore / loadMoreFailed / total / page）。
   UI 按来源分组渲染；扁平投影（`searchResults` / `filteredResults`）只服务
   播放、性能场景与旧消费面。
3. **来源变化补搜**：registry 的新来源出现、当前关键词已经在当前搜索类型
   搜过时，自动为该来源补首屏；其它类型在切过去时再补。来源移除 / 停用会
   dispose 对应会话；渠道排序变化只重排
   分组，不重发请求；descriptors 未变化时不发请求。
4. **来源过滤持久化**：`kSearchSourceFilter`（默认 `''` = 全部来源）跨重启
   记住；`selectSourceFilter` 只过滤已加载分组，来源尚未参与本轮搜索时才补
   首屏。过滤顺序严格取 `SourceRegistry.descriptors`（音源管理的渠道排序），
   「全部」固定第一。
5. **发现渠道解耦**：`DiscoverProvider.channelKey` 只决定热榜 / 歌单，使用
   独立键 `kDiscoverChannelKey`；删除 `onChannelChanged` / `syncSearchSource`。
   资料库搜索 tab 显隐只看 `SearchProvider.hasSearchableSources`；搜索 tab
   默认不显示发现渠道下拉，仅当页面只剩搜索 tab（当前渠道没有热榜 / 歌单
   能力）时保留渠道下拉，作为切回可发现渠道的逃生口。
6. **单源体验不回退**：有效分组只有一个时不渲染分组标题、保留宽屏表格列
   与触底自动分页；多分组才用分组标题 + 每组独立「加载更多」。遮罩单源
   最多预览 8 行，多分组每组最多 2 行、总计 8 行。
7. **键盘按命令面板模型**：遮罩打开期间由 `KeyClaims` 登记方向键 / Space /
   Enter（含 numpadEnter），桌面壳层的软件内快捷键命中登记时让位；页面版
   搜索结果区用 `KeyClaimScope` 在焦点进入时登记。Ctrl+F 已打开时重新聚焦
   输入框并全选；↑↓ 在扁平高亮序列上跨分组移动并跳过组标题；Enter 播放 /
   打开高亮项，Ctrl+Enter 始终打开完整结果页；Tab 由 `FocusScope`
   `closedLoop` 锁在遮罩内；IME 组合中不抢 ↑↓ / Enter。

## 后果

- 启动早期脚本尚未加载时先搜 B 站；脚本加载后自动补搜新来源，不再需要
  先打开发现页。
- 一个平台失败 / 限流不会清空其它平台的已加载结果，错误与重试挂在来源
  分组标题。
- 搜索来源与发现渠道各自持久化，互不覆盖；用户切热榜渠道不再改搜索源。
- 单源用户仍看到原来的表格 / 触底分页；多源用户获得分组与每组独立分页。
- 键盘快捷键的让位协议从 Esc 扩展到方向键 / Space / Enter；新增模态或
  可聚焦控件时必须登记，否则会被全局播放 / 音量 / seek 抢键。
