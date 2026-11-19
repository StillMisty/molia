# 原生互操作层（`lib/platform/`）

ADR-0038 的唯一落点：所有 JNIgen / FFIgen / Pigeon 生成绑定与它们的薄适配器都放
在这里，业务层继续只依赖既有端口。

## 目录约定

```
lib/platform/
  android/   # JNIgen 生成物：<name>.g.dart（Java / Kotlin 系统调用）
  apple/     # FFIgen 生成物：<name>.g.dart（Objective-C / 系统字体、低电量模式）
  desktop/   # FFIgen 生成物：<name>.g.dart（Win32 / POSIX / allocator trim）
  <域>.dart  # 手写的薄适配器：把生成绑定投影成端口需要的最小 Dart 面
```

- 生成物统一 `<name>.g.dart`，由 `tool/jnigen.dart` / `tool/ffigen_system.dart`
  写出并提交进仓库；`*.g.dart` 不参与 `test/architecture/module_layout_test.dart`
  的单文件体积棘轮。
- 手写文件只做参数校验、平台守卫、失败静默与类型投影；不承载业务规则。
- `domain` / `providers` / `pages` / `widgets` 禁止直接 import `dart:ffi`、
  `package:jni/`、`package:jni_flutter/`、`package:win32/`、`package:posix/`、
  `package:objective_c/`，也禁止直接 import 本目录的生成物；
  边界由 `test/architecture/native_interop_test.dart` 强制。
- 现存 `lib/services/**` 的手写 FFI 作为阶段 0 临时白名单保留：阶段 1 桌面
  （进程存活 / 前台激活 / 内存回收）迁入 `desktop/` 并删除 3 条；阶段 2 ABI
  读取改由 `lib/platform/abi.dart` 承担，删除 `app_info.dart` /
  `update_installer_io.dart` 两条，白名单清空。白名单只减不增。

线程规则、R8 keep、生成流程与明确不做的项目见
`docs/adr/0038-native-interop.md`。
