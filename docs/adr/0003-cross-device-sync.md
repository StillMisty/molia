# ADR-0003：跨设备数据同步（口令信任根 + 全量合并 + 双传输）

- 状态：已采纳
- 日期：2026-10-11
- 相关：`lib/domain/models/device_sync.dart`、`lib/domain/ports/sync_transport.dart`、
  `lib/data/sync/**`、`lib/providers/sync_provider.dart`、`lib/pages/sync_settings_page.dart`

## 背景

用户要求把「各个平台」的数据在多设备间同步：**歌单与收藏、音源（LX 脚本与配置）、
应用设置，以及听歌统计、AI DJ 配置与 API Key**。应用是纯本地单机架构，无账号与
官方服务端；此前只有 F 面向最近播放上下文的全量导出/导入。

两个必须显式记录的产品决策：

1. **API Key / any-listen token 也要同步**，因此快照离开设备前必须加密；
2. **「允许同步了就代表设备完全被信任」**——不做逐设备审批、不做脚本接收确认、
   不做凭证类别警告；加入同步组即完全互信。

## 决策

1. **信任模型：同步口令即信任根**。首台设备生成 32 字符口令（约 160 bit 熵），
   其它设备输入同一口令即加入；能解密快照的设备即已授权。撤销 = 重置口令
   （所有设备重新加入）。设置页不提供逐设备审批或黑名单。
2. **全量合并模型**：每台设备持有自己已知的完整视图（记录 = `key + updatedAt +
   updatedBy + data`，删除为墓碑记录），交换快照后逐键 LWW
   （`(updatedAt, updatedBy)` 字典序大者胜，deviceId 决平局保证确定性）。
   天然幂等、无版本向量；推送前裁剪 90 天前的墓碑防止无限膨胀。
3. **加密**：`gzip(JSON)` → PBKDF2-HMAC-SHA256（120k 迭代，salt/迭代数随帧携带）
   → AES-256-GCM；帧 = `magic(9) | version(1) | salt(16) | iterations(4) | nonce(12)
   | 密文+GCM tag`，头部作 AAD。服务端 / 局域网抓包只见密文；API Key 随凭证类别
   一并进入密文。
4. **传输与引擎解耦**：`SyncTransport` 端口（`pull` / `push` / `incoming`），
   首期两个实现同时可用、可分别开关：
   - **局域网直连**：UDP 广播探测（`molia-sync.probe`）+ 每设备内置 HTTP 快照端点
     （`GET/POST /molia-sync/v1/snapshot`，密文传输）；
   - **用户自备 WebDAV**：每设备上传 `<remoteDir>/<deviceId>.msync` 密文文件，
     PROPFIND 列表 + GET/PUT 读取其余设备快照；跨网络、异步。
5. **同步内容与粒度**（类别可开关，关闭后本机既不推送也不应用该类）：
   - `playlists` / `playlistTracks`：列表引入稳定 `syncId`（收藏固定常量），
     逐行 LWW + `sync_tombstones`；
   - `sources`：LX 脚本按 `importedAt` 取新（删除用登记墓碑），渠道顺序 / 停用 /
     音质 / any-listen 连接配置；
   - `settings`：**跟人走**的键（主题、语言、导航、歌词显示、默认播放模式等）；
     省流、缓存策略、字体、桌面歌词悬浮窗开关等**设备相关项不同步**；
   - `credentials`：AI DJ 配置 + AI Key + any-listen token；
   - `statistics`：`play_events` 按 `syncKey` 去重合并（v5 迁移列；存量行导出时
     按内容哈希回填）；
   - `history`：`play_history` 按 `(sourceKey, songId)` 合并、时间戳 = `playedAt`；
     用户删除（单条 / 批量 / 清空）写墓碑，上限淘汰不写墓碑；
   - `session`：上次播放会话（队列 / 下标 / 进度 / 模式）单例记录，时间戳 = 会话
     写入时间（`savedAt`），用于换设备接着听；**本地清空不回传删除**（停止播放
     只影响本机，远端更新的会话仍按 LWW 重新填充）。
6. **设置同步的变化检测用「登记哈希」**：同步层登记每个键的值哈希与时间戳，
   每轮对比当前值判定本地修改，应用远端后同步登记——不改造散落在 19 个文件里的
   SharedPreferences 写入方。
7. **落位与接线**：领域模型 / 端口在 `lib/domain`；引擎、适配器、传输、状态存储在
   `lib/data/sync`；`SyncProvider` 提供 UI 状态；组合根在 `main.dart` 创建并在
   启动 / 数据变更去抖 / 每 10 分钟 / 回前台时触发同步。Web 隐藏入口（传输依赖
   dart:io，且无接收端）。同步应用后的定向重载（主题 / 导航 / 语言 / 音源等）
   经 `PrefsSyncAdapter.onApplied` 在组合根接线。
8. **完整备份（导出/导入）复用同一 envelope**：`SyncEngine.exportBackupJson` /
   `importBackupJson` 经适配器收集与合并，不要求启用同步或口令；
   **凭证类默认排除**（避免 API Key 落进明文备份文件），调用方可显式包含。
   数据与存储页的导出/导入在同步可用时走完整备份，否则退回旧的最近播放导出。

## 后果

- 加入同步的设备可读全部同步数据（含可执行脚本与 API Key）：口令泄露 = 全部失守，
  UI 明示「重置口令即撤销」；这是完全信任模型的应有代价，不再加防呆；
- 时钟不可信时以 `deviceId` 决平局：时钟大幅漂移的设备可能持续输给对端，
  属可接受的个人设备场景；LWW 保证多设备收敛；
- 并发编辑同一歌单的顺序可能有轻微错序（行级 LWW 的已知限制）；删除语义依赖墓碑
  保留期（90 天），超期离线设备的旧数据理论上可复活；
- 局域网同步要求两端应用同时在线（移动端后台限制）；WebDAV 可异步收敛；
- WebDAV 各家实现有差异（坚果云应用密码、Nextcloud 等），协议实现只依赖
  MKCOL / PROPFIND / GET / PUT 四个方法；
- `play_events` 新增同步列与 `syncKey` 唯一索引（DB v5），旧行在首次导出时回填；
- 播放历史删除（含「清空」）在设备间传播（一致性优先）；刷新上限淘汰不写墓碑；
- 会话同步是「轻量接着听」：非实时、不控制对端；正在播放的设备持续刷新时间戳
  从而抢占，闲置设备的旧会话只会在对端有新活动时被更新；
- 完整备份默认不含凭证（API Key 不落明文文件）；需要携带凭证时使用同步本体
  （快照整体加密）。
