# ADR-0008：本地数据两档模型（缓存 / 下载）与「本地数据」页

- 状态：已采纳
- 日期：2026-10-15
- 相关：`lib/services/track_local_data_service.dart`、
  `lib/pages/track_local_data_page.dart`、`lib/widgets/track_info_view.dart`、
  `lib/services/cache_service.dart`、`lib/playback/playing_track_cache_writer.dart`、
  `lib/sources/source_track.dart`、issue #22（本 ADR 修订其措辞与呈现）

## 背景

「缓存」与「下载」是两档完全不同生命周期的东西：缓存自动产生（边播边缓存 /
预取 / 取词 / 取图）、易失（LRU / TTL / 用户清理 / 换设备即无）；下载是用户
显式动作、持久（`downloads/` + drift 记录，可分享，清缓存不影响）。issue #22
把「完整音频缓存」识别成「已下载」，方向正确（用户确实已经拥有可离线播放的
副本），但**只在音频一条线上落地**，由此暴露三个问题：

1. **音频缓存从未真正被识别**：播放 / 预取把 `SourceTrack.id`
   （`{sourceKey}:{songId}` 复合 id）当 songId 写缓存文件名
   （`kw_kw:…_320k_<hash>`），而所有读取路径按 `TrackId.id`（raw songId）
   的前缀 `kw_…_` 查找——写入侧与读取侧永不同名。于是「缓存 = 已下载」整条链
   （信息页状态、弹层标记、转存、`localUriFor` 离线取链、本地歌曲缓存行）
   全部静默失效，用户看到的是「播放完歌曲后单曲缓存页仍显示无缓存」。
2. **同一批数据被两个面各说各话**：信息页拆成「下载」行（只看下载记录 +
   音频缓存）与「缓存」行（四项缓存占用），下载弹层的歌词 / 封面行只认下载
   记录，而缓存页显示它们有缓存——用户看到「缓存页有、下载页没有」。
3. **状态判据与真实命中不一致**：单曲音频占用把半成品（`.part`）与 MIME
   边车（`.mime`）算作「有缓存」，而播放 / 转存只认完整文件；桌面端根本不写
   缓存，却和「没缓存」显示一致。

## 决策

1. **两档词表固定，全应用一致**：**已下载**（持久，可分享，清缓存不影响）>
   **已缓存**（易失，可离线播放，可转存）> **未下载**。取消「缓存副本」这种
   介于两者之间的说法（`downloadStatusCachedCopy` 退役）；缓存命中不再显示
   「已下载」。
2. **单一读取口**：`TrackLocalDataService.load(track)` 一次给出下载记录 +
   音频 / 歌词 / 封面 / 取链四项缓存占用 + 命中音质，页面只消费
   `TrackLocalData` / `LocalPartState`。页面与模块禁止各自拼缓存 key、禁止各写
   「算不算有」的判据（过去的两套口径正是分面的产物）。
3. **两个面合并为「本地数据」页**（信息页唯一入口，`showSecondaryPage`）：
   音质选择（命中缓存的音质标「已缓存」并预选）+ 音频两档状态与动作
   （下载 / 转存到本地文件夹 / 取消 / 分享导出 / 删除下载）+ 歌词 / 封面各自
   下载或转存 + 缓存占用四项（音频 / 歌词 / 封面 / 取链）逐项清理与全部清理。
   信息页只留一行副标题（两档状态 + 体积 / 音质）。
4. **缓存键唯一入口**：`SourceTrack.songId`（与 `TrackId.id` 同源，
   raw 取键 → 兜底「标题-歌手」）是平台内 id 的唯一出口；`SourceTrack.id`
   只是 `{sourceKey}:{songId}` 的包装。缓存文件名由
   `CacheService.audioCacheKeyForSource`（写入侧）与 `audioCacheKeyForTrack`
   （读取侧）产出，回归测试断言两侧同名。
5. **只认完整文件**：音频索引 / 单曲占用 / 命中探测排除 `.part` / `.predl` /
   `.mime`，半成品单独统计为「写入中」并如实展示；启动清扫中断残留半成品；
   旧命名（复合 id 时代）文件一次性清理（prefs 版本键，文件本来就命中不了）。
6. **桌面端也「听过就有缓存」**：播放侧不能边播边缓存的平台
   （`platformSupportsAudioCaching` 为假）由 `PlayingTrackCacheWriter` 起播后
   后台下载当前曲目字节（`platformSupportsAudioPrefetch`，IO 非 Web；
   `.predl` → 原子改名 → LRU），播放仍走网络，重播经 `localUriFor` 命中
   `file://`；与移动端 LockCaching 互斥（同一文件不双写），省流 / 开关 / 上限
   规则共用。

### 2026-10-25 修订：删除旧数据迁移

一次性迁移与旧数据兜底已删除，当前行为如下：

- **音频缓存**：不再执行旧命名迁移，也不再读写 `cache_audio_naming_version`
  prefs 版本键。旧命名（复合曲目 id 时代）文件不再自动扫描或清理，也无法被任何读取
  路径命中，留在磁盘上（只计入缓存目录总量）；新文件只按 `{sourceKey}_{songId}_{quality}`
  命名。
- **歌词缓存**：生产组合根仍用 `LyricsCache.appSupport()` 写
  `<appSupport>/lyrics_cache/{md5(trackId)}.json`，但旧版 `lyrics_cache_{trackId}`
  prefs 条目不再懒迁移，历史 `manual_lyrics_cache_*` 键也不再特殊处理（不读、
  不清）；目录不可用时仍回退 prefs。
- **下载**：旧下载根（应用支持目录 `downloads/`）的迁移逻辑与下载管理页的迁移
  入口已删除；管理页只保留 `.part` 清扫、孤儿文件回收与 Android 补发布。
  `DownloadRecordAssembler` 不再有 `relocated` 形态，只保留 `forAudioDownload` /
  `forPartialDownload` / `forLocalImport` / `republished`；本地导入（就地引用）
  既不迁移也不补发布。
- 上面「决策 5」、影响清单与「取舍」里关于旧命名清理、迁移的表述仅记录历史。

## 取舍

- **缓存命中仍会离线可播**（`localUriFor` 回退）与**转存不触网**保留 #22 的
  用户价值，只改呈现与词表：不把易失副本说成「已下载」。
- **代价是多一次目录列举 / prefs 读**：`load` 用一次 `audioCacheIndex` 列举
  完成「占用 + 命中音质」，不作 N 次文件探测。
- **桌面后台缓存会多一份流量**（播放 1x + 缓存下载 1x）：与移动端 LockCaching
  的边播边写同量级；省流开关、缓存开关、容量上限、LRU 全部照旧生效。
- **不迁移旧命名缓存文件**：旧文件永远无法被任何读取路径命中，属纯垃圾，
  清理比迁移划算（迁移还需要猜旧前缀规则）。
- **缓存不参与同步**（换设备即无），下载记录同步策略不变。

## 影响

- `lib/services/track_local_data_service.dart`（新，替代 `track_cache_service.dart`）
- `lib/pages/track_local_data_page.dart`（新，替代 `track_cache_page.dart` +
  `widgets/download_sheet.dart`）
- `lib/sources/source_track.dart`（`songId`）、`lib/data/mapping/track_mapper.dart`
- `lib/services/cache_service.dart`（键入口 / 完整文件口径 / 半成品清扫与迁移）、
  `lib/services/cache_types.dart`（半成品后缀常量 / seam `deleteWhere`）
- `lib/playback/local_playback_service.dart`、`playing_track_cache_writer.dart`、
  `audio_predownloader.dart`、`lib/services/audio_cache_platform.dart`
- `lib/widgets/track_info_view.dart`、`lib/utils/track_local_data_label.dart`、
  `lib/main.dart`（组合根）、l10n（en / zh）

## 2026-11-17 修订：本地歌曲缓存行改由设备本地缓存索引驱动（schema v4）

收藏页「本地歌曲」的缓存行原先由「播放历史 ∩ 完整音频缓存」推导：历史被
清空 / 单条删除 / 批量删除 / 同步墓碑删除后，缓存文件仍在磁盘，缓存行却从
列表消失。本次把「缓存行从哪来」与「播放历史」彻底解耦：

- **新增 drift 表 `local_cache_index`**（`schemaVersion = 4`，
  `from3To4` 建表；`(sourceKey, songId)` 唯一）：只存本机确认写完的曲目
  快照（展示字段 + `raw` JSON + `cachedAt`）。它没有同步版本三列、没有同步
  类别、不写同步日志，也不在 `MoliaDatabase.maxSyncVersion()` 的扫描范围；
  完整备份的类别集合同样不包含它。
- **只在缓存真正写完时写入**：移动端 `LockCachingAudioSource` 下载进度
  100% 且最终缓存文件存在（不是 `.part`）后上报；桌面 / 回退路径的
  `AudioPredownloader` 在任务完成后确认最终文件存在（`.predl` 已原子改名）
  才上报。当前曲目后台写入与下一首字节预取共用这一条完成口径；失败、取消、
  半成品都不写。播放历史写入 / 播放开始 / 同步应用历史都不写索引。
- **上限**：与播放历史同量级的 500 行，按 `cachedAt` 倒序裁剪；未播放过、
  仅由下一首预取写入的缓存也参与排序。
- **本地歌曲候选**：只读索引行，播放历史完全不参与；展示前仍做一次完整
  缓存目录扫描（LRU / 清缓存后行会消失），下载 / 导入记录优先去重并排在前。
- **写入路径只有两条**：缓存完成事件；用户手动「核对本地缓存」。播放历史
  写入 / 播放开始 / 同步应用历史都不写索引，也不再有任何启动或删除前的
  隐性扫描。
- **完成记录独立于当前曲目**：移动端缓存完成由 app 生命周期的
  `AudioCacheCompletionRecorder` 持有（完成 / 失败 / 超时 / app dispose 才
  清理），切歌 / 卸载旧源不取消监听——下载在切歌后才真正落成，仍会写索引。
- **手动核对本地缓存**：收藏页「本地歌曲」合集 ⋮ 菜单提供显式入口；当前
  播放历史只作为元数据候选，列出完整音频缓存，仅对确认存在缓存文件的曲目
  补索引行，同时清理已无缓存文件的索引行——目录列举失败时完全不动索引。
  历史为空时也允许执行（只做清理）。迁移本身不回填索引，也不从听歌统计
  回溯。
- **读取失败**：保留内存中已有行、按「已尝试」结束加载态，不把本地歌曲
  列表清空；首次装载显示加载态，避免先闪空态。
- **删除语义不变**：播放历史的清空 / 单条 / 批量 / 墓碑删除只动历史；音频
  缓存被清或 LRU 淘汰后，列表通过实时目录扫描过滤，索引行可留到下次手动
  核对清理。同步墓碑路径不触发本机核对。
- **旧版本 / 进程被杀**：旧缓存或丢失的完成事件在用户手动「核对本地缓存」
  后出现（或该曲重新缓存完成）；不再有启动 / 删除前的隐性扫描。
- **影响**：`lib/data/molia_database.dart`（v4 表 / 迁移）、
  `lib/data/local_cache_index_repository.dart`、
  `lib/services/local_cache_index_store.dart`、
  `lib/providers/local_songs_collection.dart`、`lib/playback/*`（完成信号 /
  recorder）、`lib/app/bootstrap/*`（组合根接线与首帧初始化）、
  `docs/architecture.md`。
