# ADR-0001：取色模型（基础配色 + 封面覆盖 + 消费面独立来源）

- 状态：已采纳
- 日期：2026-10-11
- 相关：`lib/theme/scheme_builder.dart`、`lib/services/artwork_palette_service.dart`、
  `lib/providers/theme_provider.dart`、`docs/architecture.md` §6

## 背景

主题取色此前由三个并列开关组成（动态取色 / 莫奈取色 / 主题色 + 纯黑），
真实优先级（莫奈 > 封面 > 种子色）只写在代码里，UI 无法表达：

- 开着动态取色去选「主题色」不生效；开莫奈后动态取色静默失效；
- 取色触发点在播放页 widget（`_updateThemeIfNeeded`），非 UI 场景无法复用；
- 海报固定用「当前主题」四套角色混搭预设，桌面歌词只有「自定义 / 主题角色」，
  两者与全局取色的关系没有任何统一说法，也没有「跟随封面」的显式选项。

## 决策

**全局主题：两层 + 一个正交修饰。**

1. 基础配色（单选）：`wallpaper`（系统壁纸 / 莫奈）或 `custom`（自定义种子色）；
2. 封面覆盖（开关，默认开）：当前曲目有封面取色结果时用封面 seed 覆盖基础配色
   （包括盖过莫奈）；无封面时清除并回退基础配色；取色失败保持现色；
3. 纯黑背景（独立开关）：仅深色模式覆盖 surface 系列，与取色来源正交可叠加。

解析唯一：`封面 > 壁纸（基础=壁纸且平台可用）> 自定义` → `applyPureBlackScheme`。

**派生唯一**：`buildColorScheme(seed, brightness)` 是全 App 唯一的 ColorScheme
工厂；`ArtworkPaletteService` 是唯一的封面取色入口（像素 → seed → 双亮度方案 +
LRU + 并发合并），由组合根监听 `PlaybackProvider` 触发（任何页面 / 后台切歌同一
链路；省流模式本地缓存可取色，未命中保持现色）。任何模块不得二次提取封面像素。

**消费面独立来源**：桌面歌词分组与海报各有 `SurfaceColorSource`
（`appTheme` / `artwork`；海报另有 `custom` 专属任意色），经
`resolveSurfaceScheme` 解析，封面方案缺失回退应用主题。海报删除四套预设样式，
改为「来源方案 → 单一角色映射」（`PosterPalette`）。每行的自定义颜色与来源正交。

**持久化迁移**：`dynamic_color_enabled → follow_artwork_enabled`、
`monet_color_enabled → color_base`（新版键存在时不做迁移，旧键保留不清理）。
纯黑键不变。

## 后果

- 行为可预知：开关状态即真实生效语义；封面覆盖期间设置页明示「覆盖 / 回退」；
- 桌面歌词「跟随封面」随切歌实时重下发（`ThemeProvider` 在封面 seed 变化时
  即使主题输出不变也会通知，调度据此重解析）；
- 旧键只读一次迁移；直接使用新键的用户不受影响；
- 省流模式行为变化：本地已缓存封面仍可取色（不再硬跳过），未命中保持现色。
