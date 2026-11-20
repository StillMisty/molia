# Pigeon 契约（`tool/pigeon/`）

Pigeon 按域小步迁移，每域一份 schema。**默认**使用 stable 的 channel 模式
（当前：`downloads_publisher.dart`、`download_notifications.dart`）；widget 域是
**native interop（`useJni`）preview 试点**（issue #78），只此一域，旧通道保留为
fallback。选型与迁移边界见 `docs/adr/0038-native-interop.md` §9 / §10 / §11。

## 约定

- schema：`tool/pigeon/<域>.dart`（如 `downloads_publisher.dart`、`widget.dart`）；
- channel 模式生成物：`lib/platform/pigeon/<域>.g.dart`，提交进仓库；
- 命令：`dart run pigeon --input tool/pigeon/<域>.dart`，平台 / 包名参数在
  schema 文件头部固定；
- Apple 域生成 Dart + Swift host：Swift 实现在 `ios/Runner` / `macos/Runner`，
  共享逻辑可复用 `sharedDarwinSource` 风格；不需要 `package:objective_c`，
  也不生成 Objective-C / FFIgen 绑定；
- 正在迁 JNI / FFI 的通道不做 Pigeon 迁移，避免同一域两份契约；
- 旧的手写 `MethodChannel` 实现保留到契约测试通过，再删旧路径；
- 手写适配器不得与生成物同名（`<域>_adapter.dart`），否则 source_gen 会删除
  同名 `.g.dart`。

## DownloadsPublisher（Android，channel 模式）

issue #80；选型结论见 ADR-0038 §10。**不用** `useJni` / `useFfi`：生成只需要
Dart + Linux，不要求 JDK 21 或 Android classpath。

```bash
dart run pigeon --input tool/pigeon/downloads_publisher.dart \
  --dart_out lib/platform/pigeon/downloads_publisher.g.dart \
  --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadsPublisherApi.g.kt \
  --kotlin_package top.stillmisty.molia.pigeon
```

生成物（提交进仓库，重复运行无 diff）：

- `lib/platform/pigeon/downloads_publisher.g.dart`
- `android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadsPublisherApi.g.kt`

运行时契约：

- 原生 MediaStore 逻辑在 `DownloadsPublisherHost`，旧
  `top.stillmisty.molia/downloads` 通道与 `DownloadsPublisherImpl` 共用；
  `MainActivity.configureFlutterEngine` 注册 `DownloadsPublisherApi.setUp(...)`。
- Dart 适配器 `lib/platform/pigeon/downloads_publisher_adapter.dart` 只封装
  Pigeon transport；fallback 组合在
  `lib/data/downloads/downloads_publisher_io.dart`（平台层不得 import data）。
  transport 异常 / 未注册时回退旧通道；正常返回 null / false 不重试。
- 非 Android 保持 `NoopDownloadsPublisher` 语义。
- CI 的 `generated-drift` job 已包含上面的生成命令（`tool/pigeon/generate.sh`
  的 widget native interop 链不受影响，仍需 JDK 21）。

验证：

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter test integration_test/downloads_publisher_pigeon_test.dart -d <android-device>
# release R8 冒烟：安装 release APK 启动，确认无 ClassNotFoundException
```

## DownloadNotifications（Android，channel 模式）

issue #82；选型结论见 ADR-0038 §11。前台服务 / 通知走 stable channel，**不用**
`useJni` / `useFfi`：生成只需要 Dart + Linux。

```bash
dart run pigeon --input tool/pigeon/download_notifications.dart \
  --dart_out lib/platform/pigeon/download_notifications.g.dart \
  --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadNotificationsApi.g.kt \
  --kotlin_package top.stillmisty.molia.pigeon
```

生成物（提交进仓库，重复运行无 diff）：

- `lib/platform/pigeon/download_notifications.g.dart`
- `android/app/src/main/kotlin/top/stillmisty/molia/pigeon/DownloadNotificationsApi.g.kt`

运行时契约：

- 契约是 `start(StartRequest)` / `update(UpdateRequest)` / `stop(id)`；结构化字段
  与端口一致，渠道用 wire 字符串（`downloads` / `update`），`update` 的 null 表示
  「不改」、`max = 0` 表示「总大小未知」。错误类名
  `DownloadNotificationsPigeonError` 与同包其它生成物隔离。
- 原生逻辑仍在 `DownloadNotificationService.kt` 的 `DownloadNotifications`；
  旧 `top.stillmisty.molia/download_notifications` 通道与
  `DownloadNotificationsImpl` 共用。`MainActivity.configureFlutterEngine`
  注册 `DownloadNotificationsApi.setUp(...)`。
- Pigeon 的 Dart `int` 在 Kotlin 侧是 `Long`，host 实现统一 `toInt()`。
- Dart 适配器 `lib/platform/pigeon/download_notifications_adapter.dart` 只封装
  Pigeon transport；fallback 组合在
  `lib/data/downloads/download_notifications_io.dart`
  （`PigeonFirstDownloadNotifications`）。transport 异常 / 未注册时回退旧通道；
  正常完成（含原生权限降级 no-op）不重试；非 Android 保持
  `NoopDownloadNotifications`。
- CI 的 `generated-drift` job 已包含上面的生成命令。

验证：

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter test integration_test/download_notifications_pigeon_test.dart -d <android-device>
# release R8 冒烟：安装 release APK 启动，确认无 ClassNotFoundException
```

## widget native interop 试点（Android JNI）

生成链固定 **JDK 21**（JNIgen 官方支持 17–21）；构建仍用 `AGENTS.md` 的
JDK 27。Kotlin 必须先由 Gradle 编译成 class，JNIgen 的 `asm` 后端才能摘要。

```bash
tool/pigeon/generate.sh
```

脚本做的事（等价于手工命令）：

```bash
# 1. schema 变更时先 bootstrap 生成 Kotlin bridge（JNIgen 此时预计失败）
dart run pigeon --input tool/pigeon/widget.dart \
  --dart_out lib/platform/pigeon/widget.g.dart \
  --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/WidgetApi.g.kt \
  --kotlin_package top.stillmisty.molia.pigeon

# 2. 编译 Kotlin（AGP9 内置 Kotlin 的产物路径）
flutter build apk --config-only --no-pub
(cd android && ./gradlew :app:compileReleaseKotlin)

# 3. 正式生成：Pigeon 自动调用 JNIgen
JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
ANDROID_SDK_ROOT=/home/still/Android/Sdk \
dart run pigeon --input tool/pigeon/widget.dart \
  --dart_out lib/platform/pigeon/widget.g.dart \
  --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/WidgetApi.g.kt \
  --kotlin_package top.stillmisty.molia.pigeon
```

生成物（提交进仓库，重复运行无 diff）：

- `lib/platform/pigeon/widget.g.dart`
- `lib/platform/pigeon/widget.native_interop.g.dart`
- `lib/platform/pigeon/widget.g.jni.dart`
- `tool/pigeon/widget_jnigen_config.dart`
- `android/app/src/main/kotlin/top/stillmisty/molia/pigeon/WidgetApi.g.kt`

生成脚本的兼容补丁（全部确定性，重复运行不叠加）：

- **Gradle 并行**：jnigen 用临时 Gradle stub 解析依赖，Gradle 9.9 +
  `org.gradle.parallel=true` 会报 “Resolution … without an exclusive lock”；
  脚本在生成期间临时关闭并行，退出时恢复 `android/gradle.properties`。
- **jni 版本**：jnigen 1.1.0 生成的绑定要求 `package:jni` ≥ 1.2；本仓已升到
  1.2.1，`JniVersionCheck` 与 `JReference.nonNullPointer` 都由 `package:jni`
  提供，不再需要版本校正与兼容垫片。
- **生成物诊断**：补 `invalid_internal_annotation` / `unused_element` /
  `override_on_non_overriding_member` 的 file-level ignore；不改生成逻辑。

运行时契约：

- Android `MainActivity.configureFlutterEngine` 注册 `WidgetApiRegistrar`
  （实现类 `@Keep`，只持有 `applicationContext`）；更新逻辑与旧通道共用
  `MusicWidgetUpdater`；
- Dart 默认优先 `WidgetApi.createWithNativeInteropApi()`；解析 / 调用失败后
  永久回退旧 `top.stillmisty.molia/widget` 通道，非 Android no-op；
- HostApi 在调用线程同步执行；根 isolate 即平台主线程，widget 更新是低频
  单向调用，不放后台 isolate；不迁移 Activity / Service / 回调域。

验证：

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter test integration_test/widget_pigeon_test.dart -d <android-device>
# release R8 冒烟：安装后切歌 / 启动，确认无 ClassNotFoundException
```
