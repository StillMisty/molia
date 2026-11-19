# ADR-0038：原生互操作层、生成流程与迁移边界

- 状态：草案（阶段 0–2、5 已落地；阶段 4 DownloadsPublisher channel 已落地，见 §10；widget native interop 试点见 §9）
- 日期：2026-11-19
- 相关：issue #65、issue #66、issue #71、`lib/platform/`、`tool/jnigen.dart`、
  `tool/ffigen_system.dart`、`tool/pigeon/`、`test/architecture/native_interop_test.dart`、
  `.github/workflows/ci.yml`、ADR-0020、ADR-0031、ADR-0034、ADR-0036

## 背景

Molia 的原生能力目前分在两处：

- 17 条手写 `MethodChannel`：方法名与 Map 字段靠两端约定，权限、Activity、
  前台服务、SAF、桌面 runner 各自手写载荷，签名漂移只能在运行期暴露；
- 5 个文件里的手写 `dart:ffi`（进程存活、前台激活、工作集回收、`Abi` 读取、
  更新安装器）：每次调用都做动态符号查找，平台分支与 ABI 细节散在业务文件里。

Flutter 3.50 把 FFIgen（C / Objective-C）与 JNIgen（Java / Kotlin）转为 stable，
本仓尚未使用。本仓只采用 FFIgen 的 **C / 桌面**能力（Win32 / POSIX / macOS
进程级 C 符号）；Apple 框架（系统字体、低电量模式等）统一走 **Swift + Pigeon**，
不引入 Objective-C 生成绑定，也不直接依赖 `package:objective_c`。同时，Pigeon
的 native interop 模式仍是 preview 且不支持 Windows / Linux；全量重写会把权限、
生命周期、桌面 runner 变成高风险区。因此需要先建立**边界与生成物流程**，再按
收益逐项迁移。

## 决策

### 1. 单一原生互操作层：`lib/platform/`

所有生成绑定与薄适配器只允许放在 `lib/platform/**`：

```
lib/platform/
  android/   # JNIgen：<name>.g.dart
  desktop/   # POSIX / allocator 的 FFIgen C 生成物（<name>.g.dart）；Win32 复用
             # package:win32，不在这里生成；桌面薄适配器也在这里
  pigeon/    # Pigeon 生成 Dart；Apple Swift host 在 ios/Runner / macos/Runner
  <域>.dart  # 手写薄适配器：平台守卫、参数校验、失败静默、类型投影
```

命名选 `platform` 而不是 `native` / `interop`：这一层不仅放生成物，也放每个
原生平台**最多一个**的薄适配器 seam；`services` 已经是领域服务位置，继续把
平台细节塞进去会让「服务」同时承担端口实现与 ABI 细节。目录按目标平台分，
避免同一份绑定同时被 Android / 桌面 / Apple 引用。Apple 的 Swift host 放在
runner 工程内（`ios/Runner`、`macos/Runner`），需要共享的 Darwin 逻辑可复用
`sharedDarwinSource` 风格，不在 Dart 平台层放 Objective-C。

边界规则（`test/architecture/native_interop_test.dart` 强制）：

- `lib/domain/**`、`lib/providers/**`、`lib/pages/**`、`lib/widgets/**`、
  `lib/app/**` 禁止直接 import `dart:ffi`、`package:jni/`、
  `package:jni_flutter/`、`package:win32/`、`package:posix/`、
  `package:objective_c/`，也禁止直接 import `lib/platform/**`；业务层继续只
  依赖既有端口。`objective_c` 目前只作为上游
  `path_provider_foundation` / `shared_preferences_foundation` 的传递依赖存在，
  我们的代码不得直接 import 或使用。组合根不设例外：平台适配器由 services
  在内部消费并通过既有端口注入，`lib/app/**` 只做装配，不直接拿生成绑定。
  若将来确有组合根装配需求，再在本文开最小路径例外，不静默放过；
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
| FFIgen | C 直接互操作，生成 `dart:ffi` 绑定 | stable（Flutter 3.50） | Windows / Linux；macOS 仅进程级 C 符号 | 同步 C 调用；阻塞调用移出 UI isolate；不生成 Objective-C / `.m` | 桌面无需额外运行时 | 进程存活、前台激活、工作集 / allocator trim、macOS 进程级 C 符号 | **采用**（阶段 1，仅桌面 C） |
| Pigeon（channel 模式） | 生成两端接口的 typed MethodChannel；Apple host 用 Swift | stable | Android / iOS / macOS / Windows / Linux | 平台线程执行，回复回 UI isolate；无共享内存 | 只多生成代码（Dart + Swift host），无原生库 | 继续走通道、需要消除手写 Map / 方法名的域；Apple 纯查询 | **采用**（阶段 3 Apple / 4 其余域） |
| Pigeon native interop preview | 生成 direct interop | **preview** | 不支持 Windows / Linux | 与 direct interop 相同，但契约未稳定 | 预览期行为可能变化 | Android widget 试点：`WidgetApi.update`（issue #78，§9） | **仅试点**（其余域不采用、不上生产） |
| 手写 MethodChannel（现状） | 字符串方法名 + Map 编解码 | 稳定 | 全部 | 平台线程 | 无 | 权限、Activity result、前台服务、SAF、runner / 菜单 / 音频路由 | **保留**（不迁） |

桌面 C 绑定的来源（阶段 1）：Win32 / POSIX **优先复用上游生成绑定**
（`package:win32` / `package:posix`），不自己声明系统 API；上游没有、或语义
不适配的符号用 vendored 头 `third_party/system_shim/system_shim.h` +
`tool/ffigen_system.dart` 生成 `lib/platform/desktop/system_ffi.g.dart`。本阶段
实际使用 `package:win32`（`OpenProcess` / `WaitForSingleObject` /
`AllowSetForegroundWindow` / `EmptyWorkingSet`）加 FFIgen shim（`kill` / errno /
`malloc_trim` / `malloc_zone_pressure_relief`）；不使用 `package:posix` 的
`kill`：它把 errno 包装成抛异常的 `PosixException`，无法保留现有
ESRCH（已退出）/ EPERM（存活）分支。

### 3. 线程规则

- **JNI**：只在需要微秒级结果的 getter 上调用；调用发生在哪个 isolate 就在
  哪个线程 attached（`package:jni` 负责附着）。阻塞型 I/O（文件枚举、网络、
  大量 `StatFs` 汇总）不得在 UI isolate 调用；必须平台线程执行的调用（例如
  需要 Looper 的 API）显式切平台线程，不在 Dart 侧模拟。
- **FFI（桌面 C）**：生成绑定是同步调用，只覆盖 Win32 / POSIX 与 macOS 的进程级
  C 符号。`kill(pid, 0)`、`OpenProcess`、`malloc_trim` /
  `malloc_zone_pressure_relief` 都按现有语义在调用线程执行，失败静默；任何
  可能阻塞的 C 调用放到 worker isolate。
- **Swift（Apple）**：Apple 原生实现统一放在 Pigeon 的 Swift host
  （`ios/Runner` / `macos/Runner`）；需要主线程的方法显式回主线程，纯查询
  失败按未知 / 默认值降级。不使用 `package:objective_c`，也不使用 FFIgen
  Objective-C。
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
- 桌面发布包剔除未使用的 JNI 原生库；`size desktop --check` 扫描 bundle 拦回
  回流（阶段 5 已落地，见 §8）。Android 现有原生库排除规则不变，不误删运行期
  真正需要的库。

### 5. 生成流程

生成物提交进仓库；改输入必须重跑并提交产物，CI 用 `git diff --exit-code`
拦截漂移。

```bash
dart run tool/jnigen.dart          # 输入：tool/jnigen.dart 的 inputs → lib/platform/android/*.g.dart
dart run tool/ffigen_system.dart   # 桌面 C：tool/ffigen_system.dart 的 inputs → lib/platform/desktop/*.g.dart
dart run pigeon --input tool/pigeon/<域>.dart   # 阶段 3（Apple Swift host）/ 4（其余域）
                                                 # → lib/platform/pigeon/<域>.g.dart + ios|macos/Runner 的 Swift host
tool/pigeon/generate.sh            # widget native interop 试点（JDK 21）：编译 Kotlin → Pigeon/JNIgen
                                   # → lib/platform/pigeon/widget*.dart + android/.../pigeon/WidgetApi.g.kt
```

- 阶段 0 的输入为空：脚本打印「未配置输入，跳过」并正常退出；登记的输入
  缺失时打印缺失路径并以非零码退出，不静默生成半份绑定；
- 生成阶段固定 JDK 21（JNIgen 官方支持 17–21），构建阶段继续用 AGENTS.md
  的构建 JDK；两者不要求一致，也不为生成升降整仓 JDK；
  阶段 0 的 CI 生成物 drift 任务不预装 21（脚本没有 JNI 输入，且
  `docs check` 会把工作流里的 JDK 与 AGENTS.md 的构建 JDK 对比）。阶段 2
  的结论见下一节：JNIgen 也没有进 drift，`docs check` 因此暂时不需要例外；
- JNIgen 配置固定 `androidSdk: AndroidSdk(addGradleDeps: true,
  androidExample: <仓库根>)`，输入源目录 / 输出文件都用绝对 `Uri`；FFIgen
  的 `entryPoints` 与输出同样用绝对 `Uri`，两者都不依赖调用时的 CWD；
- Pigeon 每个域一份 schema，命令参数写在 schema 头部；Apple 域生成 Dart +
  Swift host（`ios/Runner` / `macos/Runner`，共享逻辑可复用
  `sharedDarwinSource` 风格），不需要 `package:objective_c`；正在迁 JNI / FFI
  的通道不做 Pigeon 迁移；
- CI（`.github/workflows/ci.yml`）：Ubuntu 跑 `build_runner` + 上述生成器并
  `git diff --exit-code`。当前纳入 drift 的是 desktop FFI 与 Pigeon channel
  （`downloads_publisher.dart`，阶段 4）；JNIgen（阶段 2）、Apple Swift host
  （阶段 3）与 widget native interop 试点（§9）需要 macOS / JDK 21 / Android
  构建环境，仍在本机生成并提交。Windows 编译 `flutter build windows --debug`；
  macOS 编译 `flutter build macos --debug` 与
  `flutter build ios --no-codesign`。发布工作流 `release.yml` 不改。

### 6. 明确不做

- Pigeon native interop preview（preview、无 Windows / Linux、官方不建议生产）；
  **唯一例外**是 widget 域的 Android 试点（§9），保留旧通道 fallback，不推广
  到其他域或 Windows / Linux；
- 把 17 条通道全量 JNI 化；
- 把 Windows runner 的 COM / 窗口 / 任务栏，或 Linux GTK runner 改成 C ABI；
- 直接 Swift FFI（swiftgen 实验）：Apple 走 Pigeon 的 Swift host，不生成
  Swift FFI 绑定；
- 在没有 JNI vs MethodChannel 基准（10k 次中位 / P99）前，迁移桌面歌词
  4Hz 更新与桌面小组件更新；
- 为性能改 Dart 侧图片缓存、数据库、首帧装配（另立 issue）；
- 用 Pigeon 重写正在迁 JNI / FFI 的域，制造两份契约。

### 7. 阶段 2 实际结论（2026-11-19）

- **ABI**：新增 `lib/platform/abi.dart`，`UpdateInstaller.platformInfo` 与
  `AppInfo` 改用纯 Dart `Abi.current()`（Android x64 → `x86_64`，桌面 x64 →
  `x64`），删除 Kotlin `supportedAbi` 分支；`app_info.dart` /
  `update_installer_io.dart` 两条白名单已删除，白名单清空。
- **Kotlin 共用实现**：新增 `android/app/src/main/kotlin/.../interop/SystemInterop.kt`
  （`@Keep`，`initialize` 保存 applicationContext）；`BatteryChannelHandler`
  与 `device_storage` 通道都委托它，JNI 与通道不存在第二套读取逻辑。
  `MainActivity.configureFlutterEngine` 首行初始化。
- **JNIgen 生成**：`tool/jnigen.dart` 登记 `system_interop`。Kotlin 源不能被
  javac 摘要，脚本先跑 `flutter build apk --config-only` + Gradle
  `:app:compileReleaseKotlin`，再把编译产物 classPath 交给 `asm` 后端；
  生成物 `lib/platform/android/system_interop.g.dart` 提交进仓库。
- **JDK**：生成必须 JDK 21。JDK 27 下 JNIgen 自带的 ApiSummarizer 构建
  （Gradle 9.6 + Groovy）报 `Unsupported class file major version 71`；构建
  仍用 JDK 27，未升降整仓 JDK。
- **生成器兼容**：jnigen 1.1.0 把 `JniVersionCheck` 期望版本硬编码为 1.2.0，
  但 pub 上最新 `package:jni` 是 1.1.2；脚本生成后把断言校正成 `1.1`
  （`_alignJniVersionCheck`）。移除条件：jni 发布 1.2.0 或 jnigen 修正常量。
- **CI drift**：JNIgen 需要 JDK 21 + Android SDK + Gradle 编译，暂不进入
  Ubuntu drift job（该 job 没有 Android 构建环境，且 `docs check` 会拦截
  工作流里的 JDK 21）。待有 Android 生成任务后再补，期间以「本地重跑 +
  提交生成物」为准。
- **基准**（Android 37 模拟器，10k 次）：`totalBytes` JNI 中位 **17µs** /
  P99 **141µs**，MethodChannel 中位 **158µs** / P99 **1749µs**；桌面歌词
  4Hz 的 `desktop.update` 单次中位 **150µs** / P99 **1328µs**。JNI 有约 9×
  中位收益，但桌面歌词一次 250ms 的更新中通道只占 0.06%，迁移无用户可感
  收益：**不迁**桌面歌词 4Hz 与小组件更新，保持现状。数字与复测方式见
  `docs/performance.md` §12。
- **release 冒烟**：`@Keep` + proguard `-keep class ...interop.**`；R8 release
  APK 启动后 `readBatterySnapshot()` / `readTotalSpaceBytes()` 均返回真实值，
  无 `ClassNotFoundException` / `NoSuchMethodError`。本地 release 构建需先
  让 Flutter 以 release 模式重写插件注册文件（`flutter build apk --release`
  不带 `--no-pub`），否则 debug 遗留的 `integration_test` 注册会编译失败。

### 8. 阶段 5 实际结论（2026-11-19）

- **桌面不加载 JNI**：`jni` / `jni_flutter` 只为 Android 的 JNIgen 试点存在；
  Linux / Windows 构建仍会把运行时装进发布 bundle（`libdartjni.so` /
  `dartjni.dll`），但桌面代码没有调用方，属于死重量。
- **发布剔除**：`release.yml` 的 Linux job 在 `flutter build linux --release`
  之后、`tool/agent/check_linux_bundle.sh` / strip 之前，只删除
  `bundle/lib/libdartjni.so`（同机实测 157,288 B），不碰 `libsqlite3.so` /
  quickjs / `libcnativeapi.so`；Windows job 在构建后、复制到 `$stage` 之前，
  按 `*dartjni*` glob 删除 `build/windows/x64/runner/Release` 下的运行时
  （实际文件名以 CI 日志为准）。两处删除后都显式复查，存在即失败。
- **门禁**：`dart run tool/agent/cli.dart size desktop --check <bundle>`
  递归扫描原生库（`.so` / `.dll` / `.dylib`）：文件名含 `dartjni` 即违规；
  Linux bundle 必须保留 `libapp.so` 与 `libflutter_linux_gtk.so`；Windows
  要求入口 exe 与 `data/flutter_assets/`。release 的 Linux / Windows 打包
  步骤都调用它，人为把库放回 bundle 会在发布前失败。
- **不动 Android**：`android/app/build.gradle` 的 `jniLibs.excludes` 与
  `libsqlite3.so` / quickjs / dartjni 的保留规则不变；桌面剔除只针对桌面
  bundle，不影响 APK / AAB。
- **验证**：Linux release bundle 删除后仍能首帧启动（直接运行 release 二进制，
  Xvfb + 软件 GL，首帧 167ms）；strip 前后体积见
  `docs/performance.md` §10.1。Windows 没有本机环境，删除与门禁由 release CI
  验证；CI 通过前按「实现但未验证」标注，不合并发布。

## 9. 阶段 4 native interop 试点（2026-11-20，widget）

Pigeon native interop 仍是 preview；本节只记录 **widget 一个域**的试点
（issue #78），不改变其他域继续走 channel 模式的结论。

- **范围**：仅 `tool/pigeon/widget.dart`（`@HostApi() WidgetApi.update` +
  `WidgetPayload`），Android `useJni`。不迁 Activity / Service / 回调域，不用
  `@TaskQueue` / `@EventChannelApi` / `@ProxyApi`，不碰 Apple / iOS / macOS。
- **保留 fallback**：旧 `top.stillmisty.molia/widget` 通道与 handler 不删；
  Dart 适配器（`lib/platform/pigeon/widget_adapter.dart`）先调 native
  interop，解析 / 调用失败后永久回退通道，非 Android no-op。契约测试与
  release 冒烟通过前不删除 transport。
- **Android 实现**：`MusicWidgetUpdater` 承载「取所有 widget id → 逐个更新」
  的唯一逻辑，旧通道与 `WidgetApiImpl` 共用；`MainActivity.configureFlutterEngine`
  注册 `WidgetApiRegistrar`，实现类 `@Keep` 且只持有 `applicationContext`。
  proguard 增加 `-keep class top.stillmisty.molia.pigeon.** { *; }`。
- **线程规则**：HostApi 在调用线程同步执行；根 isolate 即平台主线程，widget
  更新是低频单向调用，允许在 UI isolate 调用；阻塞 I/O 仍必须后台 isolate。
- **平台边界**：Windows / Linux / Apple 没有 native interop 路径，继续走原有
  channel；本试点不承诺性能收益，目标是消除 widget 域两端手写方法名 / Map
  字段漂移。
- **生成**：`tool/pigeon/generate.sh`（JDK 21）先编译 Kotlin，再运行 Pigeon，
  产物提交进仓库；`jniClassPaths` 取 AGP9 内置 Kotlin 的
  `build/app/intermediates/built_in_kotlinc/release/compileReleaseKotlin/classes`。
  重复运行无 diff，命令与生成物清单见 `tool/pigeon/README.md`。
- **已知阻塞 / 兼容补丁**（preview 期，均由生成脚本确定性处理）：
  - Gradle 9.9 + `org.gradle.parallel=true` 下 jnigen 的 Gradle stub 报
    “Resolution … without an exclusive lock”：生成期间临时关闭并行；
  - jnigen 1.1.0 期望 `package:jni` 1.2.0，但 pub 最新仍是 1.1.2：校正
    `JniVersionCheck`，并用 `lib/platform/pigeon/jni_compat.dart` 补
    `JReference.nonNullPointer`；jni 发布 1.2.0 后删除补丁；
  - 生成物在 Flutter 模板分析器下的 3 条已知诊断用 file-level ignore 压掉，
    不改生成逻辑。
- **回滚**：删除适配器里的 native 分支即可回到旧通道；Kotlin host 与生成物
  可整体删除，不影响其他域。

## 10. 阶段 4 Pigeon channel：DownloadsPublisher（2026-11-20，Android）

与 §9 的 widget native interop 试点区分：DownloadsPublisher 是文件 / MediaStore
I/O 域，使用 Pigeon 的 **stable channel 模式**（issue #80），不用 `useJni` /
`useFfi`；生成只需 Dart + Linux，不要求 JDK 21 或 Android classpath。

- **契约**：`tool/pigeon/downloads_publisher.dart` 定义
  `@HostApi() DownloadsPublisherApi`：`publicRoot()` → `String?`、
  `publish(sourcePath, displayName, mimeType, relativeDir)` → `String?`、
  `remove(uri)` → `bool`，参数顺序 / 可空性与 `DownloadsPublisher` 端口一致。
- **生成物**（提交进仓库，重复运行无 diff）：
  `lib/platform/pigeon/downloads_publisher.g.dart` +
  `android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadsPublisherApi.g.kt`。
  CI 的 `generated-drift` job 已纳入该命令（Linux 可跑）；widget 的
  `tool/pigeon/generate.sh`（JDK 21）链不受影响。
- **原生复用**：MediaStore 的 `publicRoot` / `publish` / `remove` 抽到
  `top.stillmisty.molia.downloads.DownloadsPublisherHost`（只持有
  applicationContext），旧 `top.stillmisty.molia/downloads` 通道与
  `DownloadsPublisherImpl` 共用一份实现；参数校验与旧语义一致（空
  `sourcePath` / `displayName` → null，空 uri → false）。`MainActivity
  .configureFlutterEngine` 注册 `DownloadsPublisherApi.setUp(...)`，旧通道 handler 保留。
- **Dart 适配器**：`lib/platform/pigeon/downloads_publisher_adapter.dart` 只封装
  Pigeon transport（平台守卫、空参数校验、异常静默并标记不可用）；fallback
  组合放在 `lib/data/downloads/downloads_publisher_io.dart`
  （`PigeonFirstDownloadsPublisher`）——平台层不得反向 import data 层（§1）。
  Android 优先 Pigeon，transport 未注册 / 首次调用异常时回退旧
  `MethodChannelDownloadsPublisher`；Pigeon 正常返回 null / false 视为真实结果，
  不重试，避免重复发布公共副本。非 Android 保持 `NoopDownloadsPublisher`。
- **失败语义**：best-effort，null / false 由调用方只记日志，不抛到 UI；旧通道
  保留到契约测试与 Android 冒烟通过，不删 transport。
- **验证**：适配器单测覆盖成功 / null / 异常 / 非 Android 与 fallback 选择；
  `integration_test/downloads_publisher_pigeon_test.dart` 在 Android 上验证
  Pigeon host 的 `publicRoot`、publish → remove 闭环与旧通道 fallback；
  release APK 启动（configureFlutterEngine 内注册 host）无
  `ClassNotFoundException` / `NoSuchMethodError`。
- **回滚**：删除 `downloads_publisher_io.dart` 里的 Pigeon 分支即可回到旧通道；
  Kotlin host 与生成物可整体删除，不影响其他域。

## 阶段与验收

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 平台层边界、架构测试、生成器骨架、ADR、CI 三平台任务 | analyze / test 全绿；架构测试能拦住故意违规；生成器无输入时跳过、输入缺失时报错 |
| 1 | 桌面 FFIgen：进程存活、前台激活、工作集回收 | Linux POSIX 分支测试；Windows 分支靠 CI 编译 + 冒烟 |
| 2 | Android JNIgen 试点：`supportedAbi`、`StatFs`、电池快照 | 与 Kotlin 共用实现；JNI vs 通道基准；release 启动冒烟 |
| 3 | Apple Swift + Pigeon：系统字体 / 低电量模式 | Pigeon 生成的 Swift 编译通过 + 契约测试通过；失败按默认值 / 未知降级 |
| 4 | Pigeon 按域迁移 | 每域契约测试通过后删旧通道；不承诺性能收益 |
| 5 | 收尾：桌面剔除未用 JNI 库、体积门禁 | 体积检查进 CLI；文档 / 已知坑补齐 |

每个阶段独立 PR、独立回滚；旧通道 / 手写 FFI 保留到对应测试通过，A/B 验证
后再删。CI 不落地时，Windows 与 Apple 改动标注「实现但未验证」，不得合并发布。

## 后果

- 业务层不会新增原生 import；现有 5 个手写 FFI 文件是显性技术债，迁移一条
  删一条。
- 生成物可重复生成，漂移由 CI 发现；Pigeon 只解决契约一致性，不宣称性能。
- 我们的代码没有 `package:objective_c` 直接依赖；上游
  `path_provider_foundation` / `shared_preferences_foundation` 的传递依赖保留
  并在此记录，不主动添加或升级。
- 桌面发布包不再为未使用的 JNI 运行时付体积成本（阶段 5 验收）。
- 本 ADR 不改变任何当前运行时行为；阶段 0 只新增目录、脚本、测试与 CI。
