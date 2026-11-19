# 原生互操作层（`lib/platform/`）

ADR-0038 的唯一落点：所有 JNIgen / FFIgen / Pigeon 生成绑定与它们的薄适配器都放
在这里，业务层继续只依赖既有端口。

## 目录约定

```
lib/platform/
  android/   # JNIgen 生成物：<name>.g.dart（Java / Kotlin 系统调用）
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
- 现存 `lib/services/**` 的手写 FFI 作为阶段 0 临时白名单保留：阶段 1 桌面
  （进程存活 / 前台激活 / 内存回收）迁入 `desktop/` 并删除 3 条；阶段 2 ABI
  读取改由 `lib/platform/abi.dart` 承担，删除 `app_info.dart` /
  `update_installer_io.dart` 两条，白名单清空。白名单只减不增。

线程规则、R8 keep、生成流程与明确不做的项目见
`docs/adr/0038-native-interop.md`。
