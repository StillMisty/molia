# 原生互操作层（`lib/platform/`）

ADR-0038 的唯一落点：所有 JNIgen / FFIgen / Pigeon 生成绑定与它们的薄适配器都放
在这里，业务层继续只依赖既有端口。

## 目录约定

```
lib/platform/
  abi.dart   # 纯 Dart ABI / 架构命名（供诊断与更新清单；不做 FFI 调用）
  android/   # JNIgen 生成物：<name>.g.dart（Java / Kotlin 系统调用）
             # + system_interop_adapter.dart 薄适配器（电池 / StatFs）
  desktop/   # POSIX / allocator 的 FFIgen C 生成物（<name>.g.dart）；Win32 复用
             # package:win32，不在这里生成；桌面薄适配器也在这里
  pigeon/    # Pigeon 生成 Dart：<name>.g.dart；Apple Swift host 在 ios/Runner / macos/Runner
  <域>.dart  # 手写的薄适配器：把生成绑定投影成端口需要的最小 Dart 面
```

- 生成物统一 `<name>.g.dart`，由 `tool/jnigen.dart` / `tool/ffigen_system.dart` /
  `dart run pigeon` 写出并提交进仓库；`*.g.dart` 不参与
  `test/architecture/module_layout_test.dart` 的单文件体积棘轮。
- 手写文件只做参数校验、平台守卫、失败静默与类型投影；不承载业务规则。
- 桌面 C 绑定优先复用上游生成绑定（`package:win32` / `package:posix`）；上游
  缺失或语义不适配的符号（allocator trim、需要精确 errno 分支的 `kill`）用
  `third_party/system_shim/system_shim.h` + `tool/ffigen_system.dart` 生成
  `desktop/system_ffi.g.dart`。阶段 1 实际使用 `package:win32` + FFIgen shim，
  不使用 `package:posix.kill`（它把 errno 包装成抛异常，无法保留 ESRCH / EPERM
  分支）。
- Apple 原生实现统一 Swift + Pigeon（Swift host 在 `ios/Runner` /
  `macos/Runner`，共享逻辑可复用 `sharedDarwinSource` 风格）；不使用 FFIgen
  Objective-C，也不在 Dart 生成物里碰 Objective-C。
- `domain` / `providers` / `pages` / `widgets` / `app` 禁止直接 import
  `dart:ffi`、`package:jni/`、`package:jni_flutter/`、`package:win32/`、
  `package:posix/`、`package:objective_c/`，也禁止直接 import 本目录的生成物；
  `objective_c` 只作为上游插件（`path_provider_foundation` /
  `shared_preferences_foundation`）的传递依赖存在，我们的代码不得直接
  import 或使用；
- 本目录也不得反向依赖 `domain` / `data` / `sources` / `playback` / `services` /
  `providers` / `pages` / `widgets` / `app` / `main.dart`：薄适配器只做投影；
- 边界由 `test/architecture/native_interop_test.dart` 强制。
- 阶段 0 的现存手写 FFI 白名单已清空：阶段 1 桌面（进程存活 / 前台激活 /
  内存回收）迁入 `desktop/`；阶段 2 ABI 读取改由 `abi.dart` 承担。白名单只减
  不增，新增违规直接失败。
- Android（阶段 2）：`tool/jnigen.dart` 生成 `android/system_interop.g.dart`。
  Kotlin 源先由 Gradle 编译（`:app:compileReleaseKotlin`）再交给 JNIgen 的
  `asm` 后端，因此生成需要仓库 Android SDK / Gradle；生成 JDK 固定 21，
  构建 JDK 仍按 `AGENTS.md`。JNIgen 暂不进 CI drift，原因与移除条件见
  ADR-0038 §7。`system_interop_adapter.dart` 只做 Android 守卫、类型投影与
  `JLongArray.release()`，失败返回 null；`BatteryProbe` / `IoCacheStorage`
  再按各自端口语义回退通道。
- Android widget（阶段 4 试点，issue #78）：`tool/pigeon/generate.sh` 生成
  `pigeon/widget*.dart` + Kotlin `WidgetApi.g.kt`；`widget_adapter.dart` 优先
  native interop，失败回退旧 `top.stillmisty.molia/widget` 通道，非 Android
  no-op。`jni_compat.dart` 是 jnigen 1.1.0 与 jni 1.1.2 的临时兼容垫片，
  jni 1.2.0 发布后删除（ADR-0038 §9）。

线程规则、R8 keep、生成流程与明确不做的项目见
`docs/adr/0038-native-interop.md`。
