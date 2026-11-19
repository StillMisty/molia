# ADR-0038：原生互操作层、生成流程与迁移边界

- 状态：草案（阶段 0 落地护栏；阶段 1–5 按本文推进）
- 日期：2026-11-19
- 相关：issue #65、issue #66、`lib/platform/`、`tool/jnigen.dart`、
  `tool/ffigen_system.dart`、`tool/pigeon/`、`test/architecture/native_interop_test.dart`、
  `.github/workflows/ci.yml`、ADR-0020、ADR-0031、ADR-0034、ADR-0036

## 背景

Molia 的原生能力目前分在两处：

- 17 条手写 `MethodChannel`：方法名与 Map 字段靠两端约定，权限、Activity、
  前台服务、SAF、桌面 runner 各自手写载荷，签名漂移只能在运行期暴露；
- 5 个文件里的手写 `dart:ffi`（进程存活、前台激活、工作集回收、`Abi` 读取、
  更新安装器）：每次调用都做动态符号查找，平台分支与 ABI 细节散在业务文件里。

Flutter 3.50 把 FFIgen（C / Objective-C）与 JNIgen（Java / Kotlin）转为 stable，
本仓尚未使用。同时，Pigeon 的 native interop 模式仍是 preview 且不支持
Windows / Linux；全量重写会把权限、生命周期、桌面 runner 变成高风险区。因此
需要先建立**边界与生成物流程**，再按收益逐项迁移。

## 决策

### 1. 单一原生互操作层：`lib/platform/`

所有生成绑定与薄适配器只允许放在 `lib/platform/**`：

```
lib/platform/
  android/   # JNIgen：<name>.g.dart
  apple/     # FFIgen Objective-C：<name>.g.dart
  desktop/   # FFIgen C：<name>.g.dart（Win32 / POSIX / allocator）
  <域>.dart  # 手写薄适配器：平台守卫、参数校验、失败静默、类型投影
```

命名选 `platform` 而不是 `native` / `interop`：这一层不仅放生成物，也放每个
原生平台**最多一个**的薄适配器 seam；`services` 已经是领域服务位置，继续把
平台细节塞进去会让「服务」同时承担端口实现与 ABI 细节。目录按目标平台分，
避免同一份绑定同时被 Android / 桌面 / Apple 引用。

边界规则（`test/architecture/native_interop_test.dart` 强制）：

- `lib/domain/**`、`lib/providers/**`、`lib/pages/**`、`lib/widgets/**`、
  `lib/app/**` 禁止直接 import `dart:ffi`、`package:jni/`、
  `package:jni_flutter/`、`package:win32/`、`package:posix/`、
  `package:objective_c/`，也禁止直接 import `lib/platform/**`；业务层继续只
  依赖既有端口。组合根不设例外：平台适配器由 services 在内部消费并通过既有
  端口注入，`lib/app/**` 只做装配，不直接拿生成绑定。若将来确有组合根装配
  需求，再在本文开最小路径例外，不静默放过；
- `lib/platform/**` 是薄适配器，反向依赖 `lib/domain|data|sources|playback|
  services|providers|pages|widgets|app` 或 `lib/main.dart` 同样失败：绑定层
  不能持有业务规则、降级策略、音源 / 播放后端或端口实现；
- 阶段 0 白名单里的现存手写 FFI 共 5 条：
  - 阶段 1 桌面迁移：`services/memory/app_memory_manager.dart`、
    `services/window/foreground_activation.dart`、
    `services/window/process_liveness.dart` 改为 `lib/platform/desktop/**` 的
    生成绑定，删除 3 条；
  - 阶段 2 ABI 迁移：新增 `lib/platform/abi.dart`（纯 Dart，包装
    `Abi.current()` 的平台 / 架构映射，不做 FFI 调用），
    `UpdateInstaller.platformInfo` 与 `AppInfo` 改用它，删除
    `services/diagnostics/app_info.dart` 与
    `services/update/update_installer_io.dart` 2 条；此时白名单清空；
  - 白名单**只减不增**：文件迁走或改用端口后，测试因陈旧条目失败，强制删除；
- 生成物统一 `<name>.g.dart`，由脚本写出并提交进仓库；`*.g.dart` 已被
  `module_layout_test.dart` 排除在单文件体积棘轮之外，不另开豁免。

### 2. 选型矩阵

| 方案 | 类型 | 稳定性 | 平台 | 线程 / 引用 | 打包成本 | 适用 | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| JNIgen | Java / Kotlin 直接互操作，生成 `package:jni` 绑定 | stable（Flutter 3.50） | Android（JVM 测试也可用） | 调用线程需 attached；`package:jni` 管理本地 / 全局引用；阻塞调用不能放 UI isolate | 运行期成本低，JNI 插件已在依赖树；需 `@Keep` / R8 规则 | 微秒级系统 getter：`StatFs` 总容量、电池快照、ABI | **采用**（阶段 2，先试点） |
| FFIgen | C / Objective-C 直接互操作，生成 `dart:ffi` 绑定 | stable（Flutter 3.50） | Windows / Linux / macOS / iOS | 同步 C 调用；阻塞调用移出 UI isolate；ObjC UI 类需主线程 | 桌面无需额外运行时；Apple 走 static link + 生成的 `.m` | 进程存活、前台激活、工作集 / allocator trim、纯查询系统 API | **采用**（阶段 1 / 3） |
| Pigeon（channel 模式） | 生成两端接口的 typed MethodChannel | stable | Android / iOS / macOS / Windows / Linux | 平台线程执行，回复回 UI isolate；无共享内存 | 只多生成代码，无原生库 | 继续走通道、需要消除手写 Map / 方法名的域 | **采用**（阶段 4，按域） |
| Pigeon native interop preview | 生成 direct interop | **preview** | 不支持 Windows / Linux | 与 direct interop 相同，但契约未稳定 | 预览期行为可能变化 | 无 | **不采用**（不上生产） |
| 手写 MethodChannel（现状） | 字符串方法名 + Map 编解码 | 稳定 | 全部 | 平台线程 | 无 | 权限、Activity result、前台服务、SAF、runner / 菜单 / 音频路由 | **保留**（不迁） |

### 3. 线程规则

- **JNI**：只在需要微秒级结果的 getter 上调用；调用发生在哪个 isolate 就在
  哪个线程 attached（`package:jni` 负责附着）。阻塞型 I/O（文件枚举、网络、
  大量 `StatFs` 汇总）不得在 UI isolate 调用；必须平台线程执行的调用（例如
  需要 Looper 的 API）显式切平台线程，不在 Dart 侧模拟。
- **FFI**：生成绑定是同步调用。`kill(pid, 0)`、`OpenProcess`、
  `malloc_trim` / `malloc_zone_pressure_relief` 都按现有语义在调用线程执行，
  失败静默；任何可能阻塞的 C 调用放到 worker isolate。
- **Objective-C**：只迁纯查询（字体族、低电量模式）；UIKit / AppKit 的 UI 与
  菜单调用必须在主线程，且继续走通道或现有 runner，不在 FFI 里直接触碰。
  阶段 3 的 FFIgen 生成物会 import `package:objective_c`：生成前必须把它从
  传递依赖转为直接依赖（否则触发 `depend_on_referenced_packages`），生成的
  `.m` 交给 build hook 编译。
- **Pigeon / MethodChannel**：契约调用本身不保证主线程；实现侧继续按平台要求
  切线程，Dart 侧仍按 Future 消费，不新增同步等待。
- 所有迁移点保留现有失败降级语义：查询失败返回「未知 / 空 / 保守存活」，
  不把异常抛到 UI。

### 4. R8 / 打包规则

- 应用内被 JNIgen 引用的 Kotlin 互操作类必须 `@Keep`，或进入
  `android/app/proguard-rules.pro` 的
  `-keep class top.stillmisty.molia.interop.** { *; }`（类名、方法、字段都由
  生成代码在运行期按字符串查找，混淆后直接 `ClassNotFoundException` /
  `NoSuchMethodError`）。
- 不为互操作关闭 minify / shrinkResources；只加最小 keep 规则。
- release APK 启动冒烟是发布门禁：至少覆盖 JNI 类加载与一次系统 getter 调用。
- 桌面发布包剔除未使用的 JNI 原生库；体积检查加入跨端工具 CLI，防止回流
  （阶段 5）。Android 现有原生库排除规则不变，不误删运行期真正需要的库。

### 5. 生成流程

生成物提交进仓库；改输入必须重跑并提交产物，CI 用 `git diff --exit-code`
拦截漂移。

```bash
dart run tool/jnigen.dart          # 输入：tool/jnigen.dart 的 inputs → lib/platform/android/*.g.dart
dart run tool/ffigen_system.dart   # 输入：tool/ffigen_system.dart 的 inputs → lib/platform/**/*.g.dart
dart run pigeon --input tool/pigeon/<域>.dart   # 阶段 4；→ lib/platform/pigeon/<域>.g.dart
```

- 阶段 0 的输入为空：脚本打印「未配置输入，跳过」并正常退出；登记的输入
  缺失时打印缺失路径并以非零码退出，不静默生成半份绑定；
- 生成阶段固定 JDK 21（JNIgen 官方支持 17–21），构建阶段继续用 AGENTS.md
  的构建 JDK；两者不要求一致，也不为生成升降整仓 JDK；
  阶段 0 的 CI 生成物 drift 任务不预装 21（脚本没有 JNI 输入，且
  `docs check` 会把工作流里的 JDK 与 AGENTS.md 的构建 JDK 对比）。阶段 2
  真正接入 JNI 生成时，应把「生成 JDK」登记为工作流里的显式例外，而不是
  把构建 JDK 降到 21；
- JNIgen 配置固定 `androidSdk: AndroidSdk(addGradleDeps: true,
  androidExample: <仓库根>)`，输入源目录 / 输出文件都用绝对 `Uri`；FFIgen
  的 `entryPoints` 与输出同样用绝对 `Uri`，两者都不依赖调用时的 CWD；
- Pigeon 每个域一份 schema，命令参数写在 schema 头部；正在迁 JNI / FFI 的
  通道不做 Pigeon 迁移；
- CI（`.github/workflows/ci.yml`）：Ubuntu 跑 `build_runner` + 上述生成器并
  `git diff --exit-code`（阶段 0 对两者都是 no-op：FFIgen 阶段 1 / 3、JNIgen
  阶段 2 起才有真实输出）；Windows 编译 `flutter build windows --debug`；
  macOS 编译 `flutter build macos --debug` 与
  `flutter build ios --no-codesign`。发布工作流 `release.yml` 不改。

### 6. 明确不做

- Pigeon native interop preview（preview、无 Windows / Linux、官方不建议生产）；
- 把 17 条通道全量 JNI 化；
- 把 Windows runner 的 COM / 窗口 / 任务栏，或 Linux GTK runner 改成 C ABI；
- Swift 纯 Swift interop（swiftgen 实验）；
- 在没有 JNI vs MethodChannel 基准（10k 次中位 / P99）前，迁移桌面歌词
  4Hz 更新与桌面小组件更新；
- 为性能改 Dart 侧图片缓存、数据库、首帧装配（另立 issue）；
- 用 Pigeon 重写正在迁 JNI / FFI 的域，制造两份契约。

## 阶段与验收

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 平台层边界、架构测试、生成器骨架、ADR、CI 三平台任务 | analyze / test 全绿；架构测试能拦住故意违规；生成器无输入时跳过、输入缺失时报错 |
| 1 | 桌面 FFIgen：进程存活、前台激活、工作集回收 | Linux POSIX 分支测试；Windows 分支靠 CI 编译 + 冒烟 |
| 2 | Android JNIgen 试点：`supportedAbi`、`StatFs`、电池快照 | 与 Kotlin 共用实现；JNI vs 通道基准；release 启动冒烟 |
| 3 | Apple FFIgen spike：Runner 内 `@objc` 类 | 通过后只迁字体族 / 低电量模式；不通过则取消 Apple 迁移并在本文记录 |
| 4 | Pigeon 按域迁移 | 每域契约测试通过后删旧通道；不承诺性能收益 |
| 5 | 收尾：桌面剔除未用 JNI 库、体积门禁 | 体积检查进 CLI；文档 / 已知坑补齐 |

每个阶段独立 PR、独立回滚；旧通道 / 手写 FFI 保留到对应测试通过，A/B 验证
后再删。CI 不落地时，Windows 与 Apple 改动标注「实现但未验证」，不得合并发布。

## 后果

- 业务层不会新增原生 import；现有 5 个手写 FFI 文件是显性技术债，迁移一条
  删一条。
- 生成物可重复生成，漂移由 CI 发现；Pigeon 只解决契约一致性，不宣称性能。
- 桌面发布包不再为未使用的 JNI 运行时付体积成本（阶段 5 验收）。
- 本 ADR 不改变任何当前运行时行为；阶段 0 只新增目录、脚本、测试与 CI。
