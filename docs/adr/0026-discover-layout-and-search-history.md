# ADR-0026：发现页不设浏览侧栏，搜索不保留历史

- 状态：已采纳
- 日期：2026-11-14
- 相关：`lib/pages/library.dart`、`lib/widgets/discover_leaderboards_tab.dart`、
  `lib/widgets/discover_playlists_tab.dart`、`lib/widgets/channel_search_bar.dart`、
  `lib/providers/search_provider.dart`、`lib/providers/search_assist_controller.dart`、
  `lib/domain/search/search_assist.dart`、`lib/widgets/search_assist_panel.dart`、
  `docs/architecture.md`、`GLOSSARY.md`

## 背景

发现页（资料库）已经有「搜索 / 热榜 / 歌单」顶部 tab，但 expanded 宽度下又加过
一条左侧分栏，把热榜 / 歌单再列一遍。同一组入口在顶部 tab 和左栏各有一份选中态，
既挤占内容宽度，也让「发现页的入口到底在哪」出现第二套答案；热榜 / 歌单的列表本身
已经是全宽网格，不需要再多一层导航。

搜索辅助曾按渠道在设备本地保存最近 20 条查询（`SearchHistoryStore`），空词聚焦
显示「最近搜索 + 热搜」，输入建议与零结果纠错同时混用历史与热搜。实际使用中
「最近搜索」长期不清理、与热搜经常重复，查询文本还要单独落盘并维护存储损坏 /
跨渠道隔离 / 清理入口；搜索主路径并不依赖它。

## 决策

1. **发现页只有顶部 tab，没有浏览侧栏。** 所有宽度统一走 `M3ETabsView` / 单 tab；
   删除 `libraryBrowseSplit` / `libraryBrowsePane-*` 与 expanded 分栏判定。热榜 /
   歌单的切换只存在于顶部 tab。收藏页的合集侧栏与桌面导航轨不是发现页的浏览入口，
   保持现状。以后不要在发现页再引入第二套一级入口（左侧列表、抽屉、常驻卡片都算），
   需要改版时先改顶部 tab 本身。
2. **搜索不保存历史。** 删除 `SearchHistoryStore`、显式提交时的记录、历史参与的
   建议 / 纠错，以及「最近搜索 + 清除」UI 与 l10n。空词聚焦只显示发现页缓存的
   热搜（≤6），输入建议与零结果纠错也只使用热搜词；热搜只读缓存，聚焦 / 输入 /
   提交都不发网络请求。

## 后果

- 发现页在任何宽度都只有一个入口层级：expanded 不再因左栏挤压内容宽度，也不会
  出现两份 tab 选中态；热榜 / 歌单的网格列数与全宽布局不受额外侧栏影响。
- 搜索查询文本不再落盘（设备本地也不存），隐私面更小；最近搜索的清理按钮、历史
  存储容错、跨渠道历史与相关测试全部删除，搜索辅助只剩「热搜 chips + 输入建议」。
- 没有匿名热搜的渠道，空词聚焦时搜索辅助面板不占位；搜索与纠错仍然可用。
- 若将来要恢复其中任一项，需要新 ADR 给出真实用户证据与替代方案，不能以「别的
  播放器有」或「多一种选择」为由直接加回来。
