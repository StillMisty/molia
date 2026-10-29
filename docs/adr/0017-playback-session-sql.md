# ADR-0017：播放会话进主库（两表、动作落盘、Windows LocalAppData）

- 状态：已采纳（2026-10）
- 相关：ADR-0005（drift 迁移）、`lib/data/molia_database.dart`、
  `lib/data/playback_session_repository.dart`、`lib/services/playback_session_store.dart`、
  `lib/playback/playback_session_coordinator.dart`、
  `lib/data/files/app_data_directory.dart`

## 背景

播放会话（整份队列 + 下标 + 进度 + 模式 + 上下文）原先存在 SharedPreferences：
完整队列键 + 游标键 + 轻量进度键。队列 JSON 含每首曲目的原始音源 payload，
Windows 大队列实测 2MB 级；而 SharedPreferences 的任意一次 `setString` 都会
重写整个 prefs 文件。前台按 1s 写进度、后台按 15s 写，等于持续把整份队列按
MB/s 写盘（Windows 实测约 2MB/s）。同时 Windows 的应用支持目录是 Roaming：
大库 / 缓存 / 会话按规范不应漫游。

## 决策

1. **只保留一个数据库**：主库 `molia_database_v2.sqlite`。不新建独立 session
   数据库，不写 cursor 文件，不再使用 prefs 存会话。
2. **schemaVersion 1 → 2，新增两张单行表**：
   - `playback_session_payloads`：`id = 1`、`json`（整份
     `PlaybackSession.toJson()`）、`updatedAt`；只在队列 / 模式 / 上下文变化时写；
   - `playback_session_cursors`：`id = 1`、`cursorIndex`、`positionMs`、`savedAt`；
     动作时更新。
   用 drift `stepByStep` 从 v1 增量迁移（保留 v1 数据），生成
   `drift_schemas/molia/drift_schema_v2.json` 与 `lib/data/molia_database.steps.dart`；
   迁移测试覆盖 v1 带数据 → v2。
3. **动作落盘，没有周期写**：播放 / 暂停、seek 落点、切歌 / next / previous、
   队列 / 模式 / 上下文变化（含 AI 追加）、曲末完成（含单曲循环重播）、停止、
   换源、退后台、窗口隐藏 / 最小化到托盘、退出各提交一次。删除位置监听里的
   1s / 15s / 1min 定时逻辑；队列变化时 payload + cursor 同一事务，否则只
   UPDATE cursor 单行。跨设备 `savedAt` 随动作刷新，长时间无动作时接受远端
   旧会话可能压过本地——不为此重新引入定时器。
4. **旧会话不迁移**：首次读取 / `clear` 时只删除旧 prefs 键
   `playback_session_v1`、`playback_session_state_v1`、
   `playback_session_position_v1`，不读内容、不导入；删除失败只记日志。
5. **Windows 数据路径迁到 LocalAppData**：`appDataDirectory()` 在 Windows 用
   `getApplicationCacheDirectory()`（`%LOCALAPPDATA%\top.stillmisty\molia`），
   其余平台用 `getApplicationSupportDirectory()`。数据库 / 音频与封面缓存 /
   歌词缓存 / 自定义封面 / LX 脚本 / 下载 journal / 单实例锁走该 helper。
   **升级守卫**：主锁只在 LocalAppData 的 `single_instance.lock`（其余平台为
   应用支持目录）。Windows 抢新锁前只读一次旧 Roaming 锁：旧 pid 仍存活时按
   secondary 退出（连不上也不进入 primary），pid 已退出才清理旧锁继续；该
   guard 不参与新锁生命周期，也不写 legacy mirror 锁。
6. **一次性迁移策略**：
   - 主库：打开前若新目录无库、旧 Roaming 目录有库，复制 DB + `-wal` + `-shm`
     （先复制到临时名，sidecar 先 rename、主库最后 rename）；旧库保留。
     复制失败回退旧路径并记日志，下次启动重试。
   - 用户数据：`custom_covers/`、`lx_sources.json`、`download_journal/` 复制到
     新目录（已存在则跳过），并改写 `custom_cover_index_v1` 里的旧 base 路径；
     失败保留旧文件 / 回退读取，不删除旧目录。
   - 缓存可丢弃：audio_cache / artwork_cache / lyrics_cache 直接用新路径，
     不复制旧文件，也不自动删除用户目录。
   - 单实例锁：新版本只在 `appDataDirectory()` 创建 / 释放主锁；旧 Roaming
     锁只由升级守卫读取 / 清理陈旧 pid，不再作为主锁路径。

## 后果

- 进度写从「整份 prefs 文件」降到「cursor 单行 UPDATE」，大队列播放不再持续
  写盘；进程被杀最多丢最后一个动作之后的进度。
- 主库首次打开多了一次旧库复制 + v1→v2 迁移的一次性成本；`main` 里用
  `sub.db.prewarm` / `sub.session.load` 埋点观测，不改变首帧恢复态语义。
- 旧 Roaming 目录仍保留作回退 / 备份；确认稳定后可另行决定是否清理。
- 迁移只在 Windows、且新旧路径不同时执行；其余平台行为不变。
- 升级时旧版本在跑，新版本会在抢新锁前通过旧 Roaming 锁守卫识别并退出；
  DB 复制不会与旧写者并发。降级运行时新旧版本各用各的库，不共享主锁。
