# ADR-0005：本地数据库迁移到 drift（fresh 基线）

- 状态：已采纳
- 日期：2026-10-13
- 相关：`lib/data/molia_database.dart`、`lib/data/molia_database.g.dart`、
  `lib/data/library_repository.dart`、`lib/data/play_statistics_repository.dart`、
  `lib/providers/local_database_provider.dart`、`build.yaml`、`drift_schemas/`、
  `test/database_schema_test.dart`、`test/support/memory_database.dart`

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
   `main()` 里的调用一并移除）。库文件落在**应用支持目录**（Windows
   `%APPDATA%\top.stillmisty\molia`、Linux `~/.local/share/top.stillmisty.molia`，
   与设置等数据同处；该目录不可用时回退文档目录）。数据库对象是懒加载单例
   （`MoliaDatabase.instance`），首个查询
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
8. **schema 变更走 `make-migrations`**：改表 → 提 `schemaVersion` →
   `dart run build_runner build` + `dart run drift_dev make-migrations`，生成
   `drift_schemas/molia/` 的 schema 快照与 `lib/data/molia_database.steps.dart`，
   用 `stepByStep` 写增量迁移并保留数据；迁移测试在
   `test/drift/molia/migration_test.dart`（空库 schema 校验 + 带数据升级）。
   当前迁移链：`v1` 基线 → `v2` 新增 `sync_known`（同步已知版本登记）
   → `v3` 新增增量日志（`sync_journal` + `sync_journal_state`）。

## 后果

- 生成物是源码的一部分：`lib/data/molia_database.g.dart` 与 `drift_schemas/`
  下的 schema 快照必须提交；改数据库类/表结构后要重跑 `build_runner` +
  `make-migrations` 并写增量迁移；
- 测试统一用 `MoliaDatabase(NativeDatabase.memory())`
  （`test/support/memory_database.dart`）；`flutter test` 会经 sqlite3 的 build
  hook 在场生成原生库，不再有 `sqfliteFfiInit()`；
- 仓储/提供者的注入缝从 `Future<Database> Function()` 变为
  `MoliaDatabase Function()`（生产默认 `MoliaDatabase.instance`），调用方由
  `await _db` 改为同步 getter；
- `sqflite` 仍作为 `flutter_cache_manager` 的传递依赖存在（封面缓存元数据，
  与本地库无关），不再被项目直接依赖；
- 同步 / 备份的 JSON 键与列名一致（camelCase）。

