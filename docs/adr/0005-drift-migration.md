# ADR-0005：本地数据库迁移到 drift（fresh 基线）

- 状态：已采纳（迁移策略见「修订（2026-10-17）」）
- 日期：2026-10-13
- 相关：`lib/data/molia_database.dart`、`lib/data/molia_database.g.dart`、
  `lib/data/library_repository.dart`、`lib/data/play_statistics_repository.dart`、
  `lib/providers/local_database_provider.dart`、`build.yaml`、
  `test/database_schema_test.dart`、`test/database_fresh_rebuild_test.dart`、
  `test/support/memory_database.dart`

## 背景

本地数据库层原先是 sqflite + 手写 SQL：`lib/data/database_helper.dart` 手写
建表语句与 v1 → v5 的升级链（建表 / ADD COLUMN / 回填），表结构只能靠手写迁移
测试（`test/database_migration_test.dart`）与源码肉眼核对；桌面端还要在
`main()` 里做 `initDatabaseFactoryIfNeeded()`（Linux/Windows 切 sqflite FFI）。

随着 schema 增长（最近播放 / 播放历史 / 歌单与曲目 / 跨设备同步列与墓碑 /
听歌统计事件），手写 SQL 与迁移链的维护成本持续上升：列名靠字符串对齐、
行读取是 `Map<String, dynamic>`、新增列要同时改 CREATE TABLE、ALTER TABLE
与迁移测试三处。

## 决策

1. **存储层换 drift**（`drift ^2.35.2` + `drift_flutter ^0.3.1`，代码生成
   `drift_dev`）。表/列声明是 Dart 类型，读写有类型检查；官方迁移工具链提供
   schema 快照与「对比旧快照」的迁移测试。
2. **fresh 基线，不迁移历史数据**。新库文件名 `molia_database.sqlite`，
   `schemaVersion = 1` 一次性建出全部 6 张表（`play_contexts` / `play_history` /
   `playlists` / `playlist_tracks` / `sync_tombstones` / `play_events`），不带
   任何 v2–v5 的历史迁移代码与旧数据导入。取舍：迁移旧库需要读 sqflite 库文件、
   逐表映射再写回，代码量与测试面都不小，而应用处于早期、数据可由用户以 JSON
   备份 / 跨设备同步重建；旧库文件 `molia_database.db` 不主动删除，回退旧版本
   仍可读取与导出。
3. **schema 逐字平移**：表名、列名（保持 camelCase）、类型、NOT NULL、默认值、
   UNIQUE、外键级联、索引文本与 sqflite 时代完全一致，repository 的 SQL/口径
   不需要改写。两条部分唯一索引（`idx_playlists_syncId` / `idx_play_events_syncKey`）
   用 `@TableIndex.sql('CREATE UNIQUE INDEX ... WHERE ...')` 保留原文；表级
   `UNIQUE` 与外键用 `customConstraints` 原样声明；`build.yaml` 的
   `case_from_dart_to_sql: preserve` 让 drift 不把列名转成 snake_case。
   平移由 `test/database_schema_test.dart` 钉住（PRAGMA 逐列 + 索引 SQL 原文 +
   外键级联 + UNIQUE/部分唯一索引行为）。
4. **执行器用 `drift_flutter`，默认后台 isolate**：`driftDatabase(name: ...,
   native: DriftNativeOptions(databaseDirectory: ...))` 内部走
   `NativeDatabase.createBackgroundConnection`，SQL 与结果解码不占 UI 线程；
   桌面端不再需要数据库工厂初始化（`lib/data/database_factory_init*.dart` 已删除，
   `main()` 里的调用一并移除）。文档目录不可用时（Linux 缺 xdg-user-dirs）仍回退
   应用支持目录。数据库对象是懒加载单例（`MoliaDatabase.instance`），首个查询
   才真正开库。
5. **原生 SQLite 由 Dart build hooks 提供**：`sqlite3 ^3.7.0` 经 Dart hooks 打包
   预编译 `libsqlite3`（Android / iOS / macOS / Windows / Linux），不再使用
   `sqlite3_flutter_libs`（该包已是 EOL 空壳，drift_flutter 仍会带它进来，但不做
   任何事）。Android 侧实测 16 KB 页对齐（LOAD 段 `Align=0x4000`），满足
   Android 15+ 设备与 Google Play 2027-02 起的强制要求；
   `android/app/build.gradle` 里 sqflite 时代针对 `**/libsqlite3.so` 的 packaging
   剔除已随本次迁移删除——Android 现在同样随包携带并使用这个库。
6. **Web 保持不初始化数据库**（现状如此）：生产代码只 import
   `package:drift/drift.dart` 与 `package:drift_flutter/drift_flutter.dart`
   （条件导出对 Web 编译安全），`package:drift/native.dart` 只出现在测试的
   内存库 helper 里。
7. **SQL 务实混合**：简单读写走 drift DSL；统计仓库的跨行聚合（汇总 / 首播时间 /
   Top 曲目 / 来源分布 / 已听曲目名）与两表 JOIN（列表+曲目数、导出列表曲目）、
   `rowid` 淘汰语句保留原 SQL 文本（`customSelect` + `Variable` / `customUpdate` /
   `customStatement`），口径常量（`PlayStatisticsLimits` 等）仍是唯一来源。
8. **未来 schema 变更走 `make-migrations`**（已由 2026-10-17 修订废止：
   改为整库重建）：改表 → 提 `schemaVersion` →
   `dart run build_runner build` + `dart run drift_dev make-migrations`，在
   `drift_schemas/molia/` 留下快照、在 `test/drift/molia/` 生成迁移测试，用
   `stepByStep` 写增量迁移。当前 v1 快照
   （`drift_schemas/molia/drift_schema_v1.json`）已作为基线提交；单版本时
   `make-migrations` 只写快照，不生成 steps/测试文件。

## 后果

- **升级到本版本后旧数据不可见**：最近播放 / 播放历史 / 歌单 / 听歌统计从空开始
  （这是 fresh 基线的既定取舍）；旧库文件保留在原目录，回退旧版本仍可读；
- 生成物是源码的一部分：`lib/data/molia_database.g.dart` 必须提交；改数据库类/
  表结构后要重跑 `build_runner`。schema 快照与增量迁移已由下方修订废止
  （不再有 `drift_schemas/`、`test/drift/`、`*.steps.dart`）；
- 测试统一用 `MoliaDatabase(NativeDatabase.memory())`
  （`test/support/memory_database.dart`）；`flutter test` 会经 sqlite3 的 build
  hook 在场生成原生库，不再有 `sqfliteFfiInit()`；
- 仓储/提供者的注入缝从 `Future<Database> Function()` 变为
  `MoliaDatabase Function()`（生产默认 `MoliaDatabase.instance`），调用方由
  `await _db` 改为同步 getter；
- `sqflite` 仍作为 `flutter_cache_manager` 的传递依赖存在（封面缓存元数据，
  与本地库无关），不再被项目直接依赖；
- 同步 / 备份的数据格式不变（列名与 JSON 键保持 camelCase），旧版本导出的 JSON
  仍可导入。

---

## 修订（2026-10-17）

放弃增量迁移，**schema 变更 = 整库重建（本地数据不保留）**。

- 运行时代码（`lib/data/molia_database.dart`）的迁移策略只剩两条路径：
  `onCreate` 建全表；版本不同（升级或降级）时 drop 掉 `allSchemaEntities`
  里的全部实体再 `createAll`——`Migrator.drop()` 生成
  `DROP <kind> IF EXISTS`（表/索引/触发器/视图），幂等且顺序无关；迁移发生在
  `beforeOpen` 之前，外键约束尚未开启，互有引用的表可以按任意顺序 drop。
  `beforeOpen` 的 `PRAGMA foreign_keys = ON` 契约不变；
- 删除迁移工具链：`lib/data/molia_database.steps.dart`、`drift_schemas/`、
  `test/drift/`（生成的 schema 快照与迁移测试）、`build.yaml` 的 `databases:`
  块。`drift_dev` 只再承担 `.g.dart` 代码生成；
- 新测试 `test/database_fresh_rebuild_test.dart` 钉住重建行为：预置
  `user_version = 5` / `99` 与旧形状的表，打开即清空旧数据、按当前 schema
  重建（含索引）且可读写；`test/database_schema_test.dart` 继续钉建表 DDL；
- 为什么：结构与同步/备份格式仍处于快速迭代期（pre-1.0），每次改表都维护
  快照 + 增量迁移 + 迁移测试，成本高于价值；升级丢本地数据的代价被接受
  （用户可用 JSON 备份 / 跨设备同步重建），且与同步「不兼容历史数据」的
  决策一致（ADR-0003 v2 §1）；
- 代价：**任何 schemaVersion 提升都会清空本地库**（最近播放 / 歌单 / 统计 /
  下载记录）；未知（不在 `allSchemaEntities` 里的）遗留表不会被清理；
  没有 schema 快照可以回放历史版本，回退旧版本应用会读到「未来版本」的库
  并触发同样的重建。
