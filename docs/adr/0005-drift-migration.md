# ADR-0005：本地数据库迁移到 drift（fresh 基线）

- 状态：已采纳（迁移策略见「修订（2026-10-17）」）
- 日期：2026-10-13
- 相关：`lib/data/molia_database.dart`、`lib/data/molia_database.g.dart`、
  `lib/data/library_repository.dart`、`lib/data/play_statistics_repository.dart`、
  `lib/providers/local_database_provider.dart`、`build.yaml`、`drift_schemas/`、
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
8. **未来 schema 变更走 `make-migrations`**（2026-10-17 修订校准：v1–v5
   测试版库打开即整库重建，**v6 起恢复增量迁移承诺**）：改表 → 提
   `schemaVersion` → `dart run build_runner build` +
   `dart run drift_dev make-migrations`，在 `drift_schemas/molia/` 留快照、
   按需在 `test/drift/molia/` 生成迁移测试，用 `stepByStep` 写增量迁移并保留
   数据。当前基线是 v6 快照（`drift_schemas/molia/drift_schema_v6.json`）；
   单版本时 `make-migrations` 只写快照，不生成 steps/测试文件。

## 后果

- **升级到本版本后测试版旧数据不可见**：最近播放 / 播放历史 / 歌单 / 听歌统计
  从空开始（v1–v5 库一次性重建的既定取舍）；旧库文件保留在原目录，回退旧版本
  仍可读；**v6 之后不再接受「升级即清空」**；
- 生成物是源码的一部分：`lib/data/molia_database.g.dart` 与 `drift_schemas/`
  下的 schema 快照必须提交；改数据库类/表结构后要重跑 `build_runner`，
  v6 起改表还要跑 `make-migrations` 并写迁移（见修订）；
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

测试版（v1–v5）存量库**不迁移**：打开即整库重建（数据不保留）。**v6 是清空
测试版历史后的新基线（等同从 1 重新开始）**——从这条基线起**恢复增量迁移承诺：
改表结构必须写迁移、保留数据**。

- **版本号保持 6（不回 1）**：声明为 1 时，恰好停在 v1 的旧测试库会被 drift
  视为「版本一致」而跳过任何迁移回调，新代码直接跑旧 schema（缺列/旧列）静默
  炸库；保持 6 + `from < 6` 重建能覆盖所有测试版库；
- 运行时代码（`lib/data/molia_database.dart`）的分层策略：
  - `onCreate`：建全表；
  - `from < 6`（测试版库）：drop 掉 `allSchemaEntities` 里的全部实体再
    `createAll`——`Migrator.drop()` 生成 `DROP <kind> IF EXISTS`
    （表/索引/触发器/视图），幂等且顺序无关；迁移发生在 `beforeOpen` 之前，
    外键约束尚未开启，互有引用的表可以按任意顺序 drop；
  - 降级（`to < from`）：同样整库重建（drift 2.35.2 的 `MigrationStrategy`
    没有单独的 `onDowngrade` 回调，升降级都走 `onUpgrade`）；
  - `from >= 6 && to > from`：**throw**（缺迁移步骤是开发错误，绝不静默重建）；
- 迁移工具链**保留**：`build.yaml` 的 `databases:` 块 + `drift_schemas/`
  （当前 v6 快照，未来迁移的基线）+ `dart run drift_dev make-migrations`；
  `.steps.dart` 在接入第一条增量迁移时由 `stepByStep` 生成（当前策略不使用
  stepByStep，`build_runner` 不会生成它）；
- v1–v5 的 schema 快照与旧 `stepByStep` 链已删除（只服务于被重建的测试版库），
  需要时从 git 历史取回；
- 测试：`test/database_fresh_rebuild_test.dart` 钉住 v5 / 降级重建与
  「v6 起缺迁移步骤抛错」；`test/database_schema_test.dart` 继续钉建表 DDL；
- 为什么与代价（**一次性**）：测试版期间结构与同步/备份格式仍在快速迭代，
  逐个版本维护快照 + 增量迁移成本高于价值；升级到本版本时本地数据（最近播放 /
  歌单 / 统计 / 下载记录）不保留，用户可用 JSON 备份 / 跨设备同步重建。
  **v6 之后不再接受「升级即清空」**：改表 = 写迁移，保留数据。
