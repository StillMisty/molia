# ADR-0034：模块布局与文件体积守卫

- 状态：已采纳
- 日期：2026-11-17
- 相关：`test/architecture/module_layout_test.dart`、`test/architecture/layering_test.dart`、
  `docs/architecture.md` §1、`lib/domain/models/`、`lib/services/`、`lib/utils/`、
  `docs/adr/0025-cast-and-auto-out-of-scope.md`

## 背景

重构地基阶段发现四类结构债务，单靠评审无法阻止其继续增长：

- 领域模型分散在 `lib/domain/models/` 与顶层 `lib/models/` 两处，导入路径不稳定；
- 服务散落在 `lib/managers/` 与 `lib/services/`，同一职责没有唯一归属；
- 部分文件已超过 800 行，继续堆叠会让模块边界与评审范围一起失效；
- `lib/utils/` 逐步吸收 UI / provider / 服务依赖，`pages/widgets` 也直接
  import 数据层，绕过了 provider 与领域端口。

`layering_test.dart` 只约束大层方向（domain / data / UI），不覆盖模块位置、
文件体积与这两个局部依赖方向。本 ADR 固定 Phase 0 的守卫，后续搬迁在守卫下进行。

## 决策

1. **领域模型唯一位置**：`lib/domain/models/`。退役顶层 `lib/models/`，不再新增
   目录意义上的第二模型层；模型保持纯 Dart（仍由 `layering_test.dart` 的 R1 强制）。
2. **服务归入 `lib/services/`**：按领域分子目录（如 `artwork/`、`memory/`）。
   退役 `lib/managers/`。投屏预研代码 `lib/services/cast/` 按 ADR-0025 继续保留，
   不因目录收敛而删除。
3. **`lib/utils/**` 保持纯工具**：禁止 import `lib/widgets/`、`lib/providers/`、
   `lib/services/`、`lib/data/`、`lib/pages/`、`lib/l10n/`，也禁止
   `material_ui` / `material_3_expressive`。当前违规文件登记白名单，只减不增；
   UI 相关逻辑应移到消费方，而不是让工具层反向依赖。
4. **800 行体积棘轮**：扫描 `lib/**/*.dart`，排除 `*.g.dart`、
   `lib/data/molia_database.steps.dart`、`lib/l10n/**` 与 vendored 字符表。
   本 ADR 落地时已超限的文件登记白名单；新增超限文件直接失败，白名单文件降回
   800 行以内后必须删除条目（陈旧条目同样失败）。
5. **`pages/widgets` 禁止 import `lib/data/**`**：UI 通过 provider 或领域端口访问
   数据；现存 6 个文件登记白名单，只减不增。
6. **守卫实现**：`test/architecture/module_layout_test.dart` 扫描真实文件与 import，
   失败信息列出违规文件；白名单不做"新豁免"通道，新增违规必须修复。

## 后果

- 搬迁（models / managers）与后续拆文件都在同一套守卫下完成；行为与视觉不变。
- 白名单是显性技术债：清理一条就删除一条，不能静默扩大。
- 超过 800 行的文件需要拆成更小的深模块；如果确有必要长期保留，应重新评估阈值
  并另开 ADR，而不是往白名单里加条目。
- `lib/services/cast/` 仍无生产入口；本 ADR 只收敛位置，不改变 ADR-0025 的范围决定。
