# ADR-0013：Android 通知栏「收藏」动作与按钮位置

- 状态：已采纳
- 日期：2026-10-19
- 相关：`lib/playback/local_audio_handler.dart`（`favoriteActionId` /
  `attachFavoriteActions` / `refreshFavoriteState`）、`lib/app/bootstrap/library_stack.dart`
  （`wireNotificationFavorite`）、`lib/main.dart`、
  `android/app/src/main/res/drawable/ic_notification_favorite{,_filled}.xml`、
  `android/app/src/main/res/raw/keep.xml`、`.github/workflows/release.yml`、
  ADR-0010、`docs/pitfalls.md` #61 / #62

## 背景

Android 真机（ColorOS 17 / Android 17）上，通知栏 / 快捷面板的媒体控制器只
有「播放顺序 / 上一首 / 播放暂停 / 下一首」四个按钮，缺「收藏」；用户要求
「收藏放左侧、播放顺序放右侧」。

事实（读 Media3 1.5.1 源码 + 真机截图核对）：

- 通知由 `flutter_media_session 3.0.9` 的 Media3 `MediaSessionService` +
  `DefaultMediaNotificationProvider` 构建（本仓库不持有 provider）；
- `getMediaButtons()` 固定先产出 `[上一首][播放/暂停][下一首]`，再把自定义动作
  **按 Dart 传的顺序追加**；`createNotification()` 先把非自定义
  （`COMMAND_CODE_CUSTOM`）按钮全部过滤掉，所以 `setCustomLayout` /
  `setMediaButtonPreferences` 里的标准按钮顺序**不生效**；
- 唯一的位置旋钮是 `CommandButton` 的 extras
  `androidx.media3.session.command.COMPACT_VIEW_INDEX`（只管折叠态 3 个槽），
  而插件把我们的 `customExtras` 塞进 `SessionCommand` 的 extras、不是
  `CommandButton` 的——Dart 侧够不到；
- **真机上按钮位置由系统 UI 决定**：通知动作列表顺序是
  `[上一首][播放][下一首][播放顺序]`，ColorOS 的媒体卡片实际画成
  `[播放顺序][上一首][暂停][下一首]`（自定义动作贴左），点击有效
  （确认就是我们的 `lx.playMode` 自定义动作）。

## 决策

1. **加 `lx.favorite` 自定义动作**（与 `lx.playMode` 同一机制）：图标两态
   （`ic_notification_favorite` / `ic_notification_favorite_filled`），
   文案随界面语言（`favoriteAdd` / `favoriteRemove`），点击切当前曲目的收藏；
2. 自定义动作之间按 **`[收藏, 播放顺序]`** 的顺序下发——这是 Dart 侧唯一能控制
   的相对顺序；`[收藏][上一首][播放][下一首][播放顺序]` 这种精确排布做不到
   （系统 UI 重排，见上）；
3. **不 vendor `flutter_media_session`**：vendored 后覆盖
   `DefaultMediaNotificationProvider.getMediaButtons()` 只能改「通知动作列表」的
   顺序，而真机是系统重排，收益不确定、代价是自持补丁（升级要手工贴）。记为
   后备方案：若以后某台机器确实需要精确顺序，再走这条路；
4. 收藏走**唯一写路径** `LibraryProvider.toggleFavoriteSourceTrack`
   （与托盘菜单 / Windows 任务栏按钮同一入口），读用 `LibraryProvider.isFavorite`；
   handler 先于 provider 创建，因此用 `attachFavoriteActions` 晚绑定 +
   `refreshFavoriteState`（值变了才重发动作，图标空心 ↔ 实心）；
5. release 包资源保护：两个新 drawable 进 `raw/keep.xml`，并进
   `release.yml` 的「shrinkResources 不能删掉通知图标」校验列表（已知坑 #34）。

## 后果

- 通知控制器多一个收藏按钮（点击后 App 内收藏态、图标、数据库同步变化）；
- 按钮位置由系统决定：ColorOS 17 实测自定义动作贴左，预期
  `[收藏][播放顺序][上一首][播放][下一首]` 或
  `[收藏][上一首][播放][下一首][播放顺序]`（装机后确认，两者都不满足「播放顺序最右」，
  这是本决策接受的取舍）；
- 其它平台不受影响：`updateAvailableActions` 只是多了一个动作名，iOS / macOS /
  Windows（SMTC）不渲染自定义动作，Linux（MPRIS）该接口是空实现。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（`local_audio_handler_test.dart` 新增「收藏动作」5 条：
  图标随收藏态、收藏态未变不重发、通知点击落到注入写入并立即换图标、未绑定回调时空操作、
  语言切换文案跟随；另有 1 条**接线回归**——真 `LibraryProvider` + 假仓库走
  「点收藏 → 曲库写入 + 图标换实心」，锁住读写键口径，见已知坑 #62）；
- `tool/agent/test.sh linux`：端到端通过（`wireNotificationFavorite` 不改变启动路径）；
- **待人工**：Android 真机 / 模拟器上展开媒体控制器，确认收藏按钮存在、位置、点击生效，
  且在 release（shrinkResources）包上图标不丢（`release.yml` 的校验在打 tag 时兜底）。
