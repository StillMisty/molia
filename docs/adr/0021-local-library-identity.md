# ADR-0021：本地导入的稳定身份（schema v3）

- 状态：已采纳
- 日期：2026-11-14
- 相关：`lib/data/molia_database.dart`、`lib/data/local_identity.dart`、
  `lib/data/local_identity_migration.dart`、`lib/services/local_cover_identity_sweep.dart`、
  ADR-0003 / ADR-0005 / ADR-0008 / #56

## 背景

本地导入此前是下载记录的一个特例：`downloads.originSongId` 直接存文件绝对
路径，本地曲目 id 是 `local:<绝对路径>`。路径一变（移动 / 重命名 / 重定位），
收藏、列表、播放历史、恢复的会话、统计与自定义封面会同时失联；用户也看不到
「文件不见了」的状态。

下载副本不受影响：它的 `originSongId` 是原音源键（如 `wy:123`），本地曲目 id
就是 `wy:123`，本来就不依赖路径。

## 决策

### 1. schema v3（一次迁移，两个 spec 共享）

`downloads` 新增：

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `localKey` | `TEXT NULL` + 部分唯一索引（非空时唯一） | 导入的稳定身份 `file:<uuid v4>` |
| `mtimeMs` | `INTEGER NULL` | 增量扫描 / 探测的技术字段 |
| `missingAt` | `INTEGER NULL` | 确认文件不见的时间 |

`playlists` 同一次迁移新增 `description` / `coverKey` / `folder`（行为归列表
增强 spec；本 spec 只保证一次 v3，不另发 v4）。

### 2. 身份规则

- 导入：`localKey = file:<uuid>`；`originSongId` 镜像它，记录键稳定为
  `local:<localKey>`；**领域身份**是 `TrackId(local, localKey)`。
  迁移后的 `localSongId` 直接返回 `localKey`，绝不返回 `local:file:<uuid>`。
- 下载副本：`localKey = null`，领域身份仍是 `TrackId(local, <原音源键>)`。
- 路径只存在 `filePath` 与 payload `path`，扫描 / 重定位 / 移动只改路径，
  不改身份。
- 同路径重复导入按 `filePath` 找到旧记录并复用 `localKey`。

### 3. 迁移顺序（固定的三阶段）

1. **结构**：`stepByStep(from2To3)` 加列；整步（含下面的数据改写）包在一个
   drift 事务里，失败整体回滚、库仍停在 v2。
2. **数据改写**（`LocalIdentityMigration.rewrite`，≤500 行 / 批）：
   - 导入记录生成 / 复用 `localKey`，`originSongId` 改写为同一值；
   - `playlist_tracks` / `play_history` / `play_tracks` 的
     `sourceKey = local` 且旧 `local:<path>` 引用的行改写 `songId`；
     `raw` 能解析时同步改 `payload.songId`，解析失败保留原文；
   - 播放会话 JSON 的 `id` 与 `payload.songId` 改写；解析失败跳过该行，
     不阻断迁移；
   - 孤儿引用（没有下载记录）也为同一路径分配同一个新 key；
   - `sync_tombstones` / `sync_known` 里引用本地曲目的行直接删除；append-only
     的 `sync_journal` 不重写（适配器本来就过滤 `sourceKey = local`）。
3. **封面键清扫**（`LocalCoverIdentitySweep`）：封面索引在偏好里，不能进
   SQLite 事务。只改索引键（`local:<path>` → `localKey`），文件 / 哈希 /
   更新时间不变；成功后写设备本地完成标记，失败下次启动重试，重复执行幂等。
   导入封面不再进入 `covers` 同步；旧版本已同步的远端记录不主动删除。

### 4. 路径解析端口

`local` 音源不直接依赖下载服务：`LocalPathResolver` 是「稳定身份 → 当前
路径」的窄回调，组合根在下载记录就绪后接线；没有记录时回退 payload 里的
路径。重定位只需要改一条记录。

## 后果

- 旧引用在升级后一次性收敛到一个稳定 id；路径变化不再破坏收藏 / 列表 /
  历史 / 会话 / 统计 / 本地自定义封面。
- 旧版本无法打开 v3（内部迭代期接受）；迁移前的数据库文件由用户自行备份，
  本方案不做自动备份 / 恢复。
- 统计是历史快照：改标题不更新 `play_tracks`；但身份迁移会更新
  `play_tracks.songId`，否则统计与曲库断开。
- 重命名 / 移动文件仍会得到「旧记录缺失 + 新记录」，需要用户手动重定位；
  不做内容哈希自动匹配。
