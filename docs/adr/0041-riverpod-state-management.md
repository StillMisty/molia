# ADR-0041：状态管理迁移到 Riverpod

- 状态：已采纳（分阶段实施中）
- 日期：2026-11-23
- 相关：`lib/app/bootstrap/`、`lib/providers/`、`lib/app/bootstrap/runtime_providers.dart`、
  `pubspec.yaml`、`docs/architecture.md` §1、`test/architecture/layering_test.dart`

## 背景

应用当前以 `provider` + `ChangeNotifier` 作为状态层：`lib/app/bootstrap/provider_tree.dart`
在 `runApp` 前一次性注册 45 个依赖，UI 通过 `context.read/watch` 取实例，测试通过
`MultiProvider` 注入假实现。随着播放会话、资料库、下载、同步等状态增长，这套模型出现三个
结构性问题：

1. **生命周期不可组合**：所有实例在启动阶段创建并常驻；页面级状态（年度报告、统计页、
   评论、歌词搜索）没有自动释放的边界，只能手写 `dispose` 与组合根顺序。
2. **依赖图隐式**：`provider_tree.dart` 的列表顺序即依赖顺序，`create:` 里用
   `context.read` 取前面的实例；新增依赖只能靠注释和启动期断言维持，无法静态检查。
3. **测试成本高**：每个用例都要手工装配 `MultiProvider` 列表；`ChangeNotifier`
   继承迫使状态类与 `flutter/foundation` 绑定，纯 Dart 单测需要 Flutter 测试绑定。

Riverpod 3 提供显式 provider 图、自动释放、`Ref` 依赖注入与 `ProviderScope` override
测试模型，可以同时解决这三点。

## 决策

### 1. 依赖与代码生成

- 依赖：`flutter_riverpod: ^3.5.0`、`riverpod_annotation: ^4.0.8`；
  开发依赖：`riverpod_generator: ^4.0.10`。
- **provider 一律手写注解 + 代码生成**（官方推荐）：`@riverpod` / `@Riverpod(...)`，
  生成物 `*.g.dart` 与 drift 生成物一样提交进仓库，不手改。
- 全局单例状态使用 `@Riverpod(keepAlive: true)`；页面 / 弹层状态使用默认的
  auto-dispose，离开消费面即释放。
- 命名：`@Riverpod(name: 'xxxProvider')` 显式给出 provider 名，避免类名后缀推断出
  `xxxProviderProvider`。新增 provider 必须有唯一名。

### 2. 状态类形态

- UI 状态用 `Notifier<State>` / `AsyncNotifier<State>`，`State` 是**不可变快照**
  （`@immutable`，字段 `final`），对外只暴露快照；命令方法在 Notifier 上，
  经 `ref.read(xProvider.notifier).command()` 调用。
- 旧 `ChangeNotifier` 的公开 getter 一一映射到状态快照；可变字段只保留在 Notifier
  内部（订阅、定时器、服务句柄），不进入 `state`。
- 服务（`lib/services/`、`lib/data/`、`lib/sources/`、`lib/playback/`）**不改成
  Notifier**：它们是纯依赖，用函数式 `Provider` 暴露、由 `ref` 注入。只有“UI 读取并
  需要重建”的状态才进入 Notifier。
- 少量仍以 `Listenable` 为接口的适配层（如桌面歌词输出）由 Notifier 额外暴露
  `changes` 信号；新代码不得依赖它。

### 3. 组合根与容器

- `app_bootstrap.dart` 在核心栈之后创建**唯一** `ProviderContainer`，用
  `settingsRegistryProvider.overrideWithValue(core.catalog.settings)` 注入启动期依赖；
  功能栈通过 `container.read(...)` 取需要参与接线的实例。
- `buildRootWidget` 用 `UncontrolledProviderScope(container: dependencies.container)`
  挂树；`main.dart` 仍是唯一 composition root。
- 迁移期允许 `ProviderScope` 内继续挂 `MultiProvider`（未迁移 provider），
  但**同一状态只能有一个来源**：已迁移的 provider 必须从 `MultiProvider` 删除，
  不得双写。

### 4. 测试

- 单元测试用 `ProviderContainer(overrides: [...])`，`addTearDown(container.dispose)`；
  通过 `container.read(xProvider)` 读快照、`container.read(xProvider.notifier)` 执行命令。
- Widget 测试用 `UncontrolledProviderScope(container: ...)` 包住旧 `MultiProvider`
  宿主；依赖注册表用 `settingsRegistryProvider.overrideWithValue(testSettingsRegistry())`。
- 不再为迁移后的状态类写 `ChangeNotifier` 专用的 `addListener` / `dispose` 断言。

## 实施顺序

按依赖方向自下而上，每批保持 `flutter analyze` 与相关测试通过后再进入下一批：

1. ✅ 基础设施：依赖、`ProviderScope`、`settingsRegistryProvider`、ADR。
2. ✅ 主题：`ThemeProvider` → `Notifier<ThemeState>`，主题作用域挂载进入 `build()`；
   主壳 / 设置 / 歌词显示页 / 启动接线与测试同步迁移。
3. 全局偏好：导航、渠道、主题外的设置 store（音源偏好、下载设置、托盘、快捷键、
   歌词显示配置、省流、音频焦点、加入收藏位置、换源开关）。
4. 搜索 / 发现 / 音源 / 评论。
5. 资料库 / 本地曲库 / 统计 / 年度报告。
6. 播放（`PlaybackProvider`、进度通道、睡眠定时、播放观察者）。
7. 歌词 / AI 推歌。
8. 下载 / 本地数据 / 同步 / 更新 / 诊断。
9. 移除 `provider` 依赖、`provider_tree.dart` 与架构守卫里的 `package:provider/`
   例外，更新 `docs/architecture.md`。

## 后果

- provider 图显式可测；页面级状态可自动释放；测试不再依赖 `ChangeNotifier` 生命周期。
- 迁移期存在两套容器，必须在每个批次内完成“provider + 全部消费方 + 测试”的闭环，
  不允许长期留下只迁移一半的 provider。
- 启动阶段仍有显式 `.read(...)` 接线；这部分随批次 3–8 逐步内聚到 provider 的
  `build()`，最终组合根只保留平台装配与容器创建。
