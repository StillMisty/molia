# Pigeon 契约（`tool/pigeon/`）

Pigeon 只覆盖**继续走通道**的域，使用 stable 的 channel 模式；**不使用** Pigeon
native interop preview（preview、无 Windows / Linux、官方不建议生产）。选型与
迁移顺序见 `docs/adr/0038-native-interop.md`。

## 约定

- 每个域一份 schema：`tool/pigeon/<域>.dart`（如 `apple_system.dart`）；
- 生成物统一 `lib/platform/pigeon/<域>.g.dart`，提交进仓库；
- 命令：`dart run pigeon --input tool/pigeon/<域>.dart`，平台 / 包名参数在
  schema 文件头部固定，避免每条命令各写一份；
- Apple 域生成 Dart + Swift host：Swift 实现在 `ios/Runner` / `macos/Runner`，
  同一份契约分别生成到两端；不需要 `package:objective_c`，也不生成
  Objective-C / FFIgen 绑定；
- 正在迁 JNI / FFI 的通道不做 Pigeon 迁移，避免同一域两份契约；
- 旧的手写 `MethodChannel` 实现保留到契约测试通过，再删旧路径。

## 当前契约

| schema | Dart | Swift host | 原生实现 |
| --- | --- | --- | --- |
| `apple_system.dart` | `lib/platform/pigeon/apple_system.g.dart` | `ios/Runner/AppleSystemApi.g.swift`、`macos/Runner/AppleSystemApi.g.swift` | `ios/Runner/AppleSystemHostImpl.swift`、`macos/Runner/AppleSystemHostImpl.swift` |

`apple_system` 只包含 Apple 纯查询：设备字体族、电池 / 省电模式。Dart 侧经
`lib/platform/pigeon/apple_system_adapter.dart` 做平台守卫与失败降级，业务层
（`services/`）不直接碰生成代码。Android 对应能力走 JNI（ADR-0038 阶段 2）。

生成物由 CI 的 drift job 校验：改 schema 后必须重新生成并提交 Dart 与两份
Swift 产物，否则 `git status --porcelain` 会失败。
