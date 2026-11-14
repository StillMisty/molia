# ADR-0019：单渠道搜索与 Ctrl+F 渠道切换

- 状态：已采纳（2026-11）
- 相关：`lib/providers/search_provider.dart`、`lib/providers/discover_provider.dart`、
  `lib/pages/library.dart`、`lib/widgets/global_search_overlay.dart`、
  `lib/widgets/channel_search_bar.dart`、`lib/widgets/search_results_view.dart`、
  `lib/app/bootstrap/provider_tree.dart`、`lib/data/settings/settings_keys.dart`、
  `docs/architecture.md`、`docs/pitfalls.md`
- 取代：ADR-0018 的跨音源聚合搜索、来源过滤与 Ctrl+F 多来源预览部分

## 背景

ADR-0018 把搜索做成「当前搜索类型 × 所有可搜索来源」的并行聚合，并让搜索
来源与发现渠道各自持久化。实际使用中暴露出三个问题：

1. **同一页出现多个平台的同名结果**，用户还要先理解「来源 chips」才能收敛
   到一个平台；对「我现在就在 QQ 音乐里找歌」这种主路径反而更慢。
2. **发现页渠道与搜索来源分叉**：切热榜渠道不会切搜索，Ctrl+F 里也没有
   渠道入口；用户看到的热榜平台和搜出来的平台经常不是同一个。
3. **全局搜索遮罩的左缘被回退箭头占用**，却没有地方显示 / 切换当前渠道；
   聚合分组、每源预览上限和来源 chips 让遮罩与结果页都多了一层概念。

## 决策

1. **全局唯一当前渠道**：`DiscoverProvider.channelKey`（持久化键
   `kDiscoverChannelKey`）同时决定热榜 / 歌单与搜索。`SearchProvider` 不再
   持有来源过滤偏好，`kSearchSourceFilter` 与来源 chips 全部删除。
2. **搜索只搜当前渠道**：`SearchProvider.activeSourceKey` 与
   `DiscoverProvider.channelKey` 同源；`hasActiveSearchSource` 以
   `supportedSearchKinds.isNotEmpty` 为准（已注册但 search / artist /
   lyricSearch 全 false 的渠道仍算不可搜索）。`supportedSearchKinds` 只看当前
   渠道能力位，当前类型不被支持时回退到第一个支持的 kind（优先 `song`）。
3. **切换渠道即重搜**：`setActiveSource` 清空所有旧结果并按当前关键词在
   新渠道重搜；空 key 回到第一个可搜索渠道，**不再表示「全部来源」**。
   当前渠道不可搜索（脚本未加载 / 无搜索能力）时不发请求，等 registry
   出现该渠道后按当前关键词补首屏（即使切渠道时已清空执行体，也要主动重搜）。
4. **发现页渠道常显**：顶部渠道下拉在搜索 / 热榜 / 歌单所有 tab 左侧常显
   （手机 icon-only tab、桌面 icon + 文案，保持单行）。字段宽度按最长启用
   渠道名实测，上限扣掉可见 tab 的最小槽位；弹层宽度跟随字段，未选中 item
   不再为右侧打勾预留固定槽位（只有选中行显示勾），长名称在弹层里尽量完整
   显示（超长脚本名仍单行省略）。当前渠道
   任一搜索能力（song / artist / lyricSearch）都没有时才隐藏搜索 tab；当前
   渠道既不能搜索也没有发现内容时保留顶部下拉，正文显示
   「当前渠道没有可用内容」；只有全部渠道停用才显示设置引导。
5. **Ctrl+F 组合搜索条**：遮罩顶部是**一颗** M3E 风格搜索胶囊，内部左侧
   透明背景 + `outlineVariant` 描边的渠道 chip 直接占据原搜索图标位置，
   右侧是裸输入 + 清除键；不再嵌套第二层
   `AppSearchBar`。删除回退箭头，关闭仍用 Esc / 点击遮罩。选择渠道后同步发现
   与搜索，并把焦点还给输入框。只有 ≥2 个启用渠道时显示 chip；单渠道时回退到
   标准搜索栏（左侧搜索图标）。当前渠道不支持搜索时面板显示专用空态，chip
   仍可切换。chip 与发现页共用同一个下拉选择器，渠道名在弹层里尽量完整显示。
6. **结果面单源化**：`SearchResultsView` 不再渲染来源 chips / 分组标题 /
   每组独立加载更多；保留单源结果行、宽屏表格、触底分页、失败重试与类型
   分段。遮罩最多预览 8 行，以「查看全部结果」收尾。

## 后果

- 发现页与 Ctrl+F 的「当前平台」永远一致，用户不需要维护两份来源偏好。
- 聚合搜索的分组 / 公平预览 / 来源过滤代码与设置键被删除；`SearchProvider`
  仍复用 `FanOutSearchSession` / `PagedFanOutRun` 的单源执行与查询代际协议，
  但目标来源最多一个。
- 当前渠道不可搜索时不会偷偷搜别的平台：发现页隐藏搜索 tab，Ctrl+F 显示
  空态并保留渠道选择作为逃生口。
- 旧设置 `search_source_filter` 不再读取、不迁移；搜索渠道完全由
  `discover_channel_key` 决定（内部快速迭代，不兼容历史数据）。
- Ctrl+F 的组合条是自定义 TextField，需要自己维护 Esc、清除键、焦点环与
  文本缩放；它与 M3E 搜索栏共用 `appSearchBarLayoutFor` 的自适应高度 / 字号。

## 补充（2026-11）

同一轮改版还调整了发现页版式与热榜封面（不改搜索语义）：

- 发现页内容栏全宽自适应：删除 960 内容上限与 `DiscoverContentFrame`，资料页
  `ResponsivePageContainer` 传 `maxWidth: double.infinity`；列数仍按实际内容宽
  计算，最多 6 列。
- 热榜磁贴改为 56dp 封面 + 名称；`DiscoverProvider.loadLeaderboardCover` 按
  board.id 缓存 / single-flight，平台轻量封面优先，失败用首曲封面兜底，再失败
  显示平台色占位。榜单详情页复用同一份缓存 / future，封面未就绪不阻塞曲目首屏。
