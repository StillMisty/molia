# media_kit 原生库依赖方式：按平台拆分 vs `media_kit_libs_audio`

> **结论：保持按平台拆分**（`media_kit_libs_linux` + `media_kit_libs_windows_audio`）。
> 换成官方的 `media_kit_libs_audio` 不改变任何功能，却会让 Android 每个 ABI 的 release APK
> **+2.98 MB（本机实测）**、iOS 额外 vendor 一份 libmpv xcframework（macOS 本仓库根本没有构建目标，
> 纯死重量），并在每次 Android 构建时强制从 GitHub 下载 4 个 ABI 的 11.5 MB jar。
>
> 本文数字分三类标注：**【实测】**（本机跑出来的产物/网络数据）、**【源码】**（读 pubspec /
> Gradle / CMake / Flutter SDK 源码确认）、**【三方】**（别人的说法，带链接）。
> 无标注的推理由前两类推出。复评触发条件见 §8，复现命令见 §9。

---

## 1. 结论（一行）

本应用只在 Windows/Linux 启用 media_kit 后端，而 libmpv 的可执行代码全靠 `media_kit_libs_*` 交付，
**按平台引入是"刚好够用且不多打包"的唯一组合；umbrella 包会把 Android/iOS/macOS 一并拉进来。**

## 2. 背景：为什么现在是「桌面-only media_kit + 按平台 libs」

- **播放后端选择**：`just_audio` 只声明 android/ios/macos/web（`pubspec.yaml` 的
  `flutter.plugin.platforms`，pub.dev API 可查）；桌面走 `just_audio_media_kit` → `media_kit`（libmpv）。
  本仓库的开关在 `lib/playback/desktop_audio_init_io.dart`：仅
  `Platform.isWindows || Platform.isLinux` 时调 `JustAudioMediaKit.ensureInitialized()`。**【源码】**
- **双保险**：`just_audio_media_kit` 2.1.0 的 `ensureInitialized` 默认值就是
  `linux: true, windows: true, android: false, iOS: false, macOS: false`（包源码
  `lib/just_audio_media_kit.dart`，本机 pub cache 核对）——即使 libs 装上了，Android/iOS/macOS 也不会激活
  media_kit 后端。**【源码】**
- **`media_kit` 本身没有原生代码**：`media_kit` 1.2.6 的 pubspec 无 `flutter.plugin.platforms` 段，
  包内不存在 `android/ ios/ macos/ linux/ windows/` 目录（本机 pub cache 核对）。
  也就是说**原生库的有无 100% 由 `media_kit_libs_*` 决定**，不是"编译必需"，而是"要不要打进产物"。**【源码】**
- **现有 libs 的实际作用**（这决定了"保持拆分"到底保住了什么）：
  - Windows：`media_kit_libs_windows_audio` 1.0.9 的 `windows/CMakeLists.txt` 在 configure 阶段下载
    `mpv-dev-x86_64-20230924-git-652a1dd.7z`，并把 `libmpv-2.dll` 写进
    `media_kit_libs_windows_audio_bundled_libraries`（即真的进 bundle）。**【源码】**
  - Linux：`media_kit_libs_linux` 1.2.1 的 `linux/CMakeLists.txt` 把
    `media_kit_libs_linux_bundled_libraries` 设为**空字符串**，只从源码编译一个静态 mimalloc；
    插件 `.cc` 只做 `setlocale(LC_NUMERIC, "C")` 与打印一行注册日志。libmpv 来自系统包，
    这也是 `docs/lx_sources.md` 要求 Linux 用户安装 mpv（`sudo pacman -S --needed mpv`）的原因。**【源码】+【实测】**
    本机 `build/linux/x64/debug/bundle/lib/` 实际只有 `libmedia_kit_libs_linux_plugin.so`，没有 `libmpv.so`。
  - 顺带一提：本仓库 `linux/CMakeLists.txt` 未引用 `MIMALLOC_LIB`（grep 无匹配），
    所以那个静态 mimalloc 对本应用是空转——不影响本决策。**【源码】**

## 3. 官方推荐 vs 本仓库做法

| | 官方 README（`media-kit/media-kit` main 分支，2026-10-13 取） | 本仓库 `pubspec.yaml` |
|---|---|---|
| 依赖写法 | `media_kit: ^1.2.6` + `media_kit_libs_audio: ^1.0.7` | `just_audio_media_kit` + `media_kit_libs_linux` + `media_kit_libs_windows_audio` |
| 覆盖平台 | android/ios/macos/windows/linux 一次到位 | 只覆盖实际使用 media_kit 的两个桌面平台 |
| 官方附加要求 | "Enable `--split-per-abi` or use app bundle (instead of APK) on Android."（因为 Android 侧 libmpv 很大） | 发布命令本来就带 `--split-per-abi`（见 `AGENTS.md`） |
| 互斥说明 | "The `media_kit_libs_video` & `media_kit_libs_audio` packages should not be mixed." | 未使用 video 版，无冲突 |

来源：<https://github.com/media-kit/media-kit>（README `## Installation` 一节）。

关键事实：**umbrella 包 `media_kit_libs_audio` 本身不是插件**——pubspec 没有 `flutter:` 段，
`lib/media_kit_libs_audio.dart` 只有一个空 `library` 声明，它只是 5 个平台包的转发依赖：
`media_kit_libs_android_audio ^1.3.8`、`media_kit_libs_ios_audio ^1.1.4`、
`media_kit_libs_macos_audio ^1.1.4`、`media_kit_libs_windows_audio ^1.0.9`、`media_kit_libs_linux ^1.2.1`
（pub 归档 `media_kit_libs_audio-1.0.7` 解包核对）。**【源码】**
后两个版本与仓库现状**完全一致**——换 umbrella 不会顺带升任何东西，只会新增 android/ios/macos 三项。

`just_audio_media_kit` 官方 README（pub.dev 页面，2.1.0）也给出了同样的按平台写法，并明确：

> "**Note**: you can also use `just_audio_media_kit` for Android, iOS and macOS by including the required
> libs (see below) and enable them in `ensureInitialized()`. However, this is not required as they're
> natively supported by `just_audio`."

来源：<https://pub.dev/packages/just_audio_media_kit>。**【三方/官方文档】**

## 4. 逐平台注册与打包路径（证据链）

Flutter 的规则是"**只注册在 pubspec 里声明了该平台的插件**"，链路如下（均可复核）：

1. 插件在 `pubspec.yaml` 用 `flutter.plugin.platforms.{android,ios,…}` 声明支持平台
   （官方文档：<https://docs.flutter.dev/packages-and-plugins/developing-packages#plugin-platforms>）。**【源码/官方文档】**
2. Flutter tool 据此写 `.flutter-plugins-dependencies`：每个平台一个数组，只有声明了该平台才会出现
   （`$FLUTTER_ROOT/packages/flutter_tools/lib/src/flutter_plugins.dart` 的 `_writeFlutterPluginsList` /
   `_createPluginMapOfPlatform`，后者对 `plugin.platforms[platformKey] == null` 直接 `assert`）。**【源码】**
3. Android 侧 Gradle 只把 `plugins.android` 里的条目 `include` 成子工程：
   `FlutterAppPluginLoaderPlugin` + `$FLUTTER_ROOT/packages/flutter_tools/gradle/src/main/scripts/native_plugin_loader.gradle.kts`
   （`getPlugins()` 只读 `pluginsMap["android"]`，并跳过 `native_build == false` 的 Dart-only 实现）。**【源码】**
4. 被 include 的插件工程执行自己的 `android/build.gradle`。`media_kit_libs_android_audio` 1.3.8 的做法是
   `assemble.dependsOn(downloadDependencies)`：用 `URL.openStream()` 下载 4 个 ABI 的 jar、
   逐文件校验 MD5，再 `implementation fileTree("$buildDir/output", include: "*.jar")`。**【源码】**
5. 这些 jar 内部就是 `lib/<abi>/*.so`（下一节实测列出）。产物实测证明 AGP 会把它们打进 APK 的
   `lib/<abi>/`；AGP 官方文档没有专门描述"jar 内 `.so`"，故此处以实测为准，不做机制推断。**【实测】**

### 本次实验观测到的注册结果（在仓库副本里加 umbrella 后的 `.flutter-plugins-dependencies`）**【实测】**

| 平台 | media_kit 相关插件 |
|---|---|
| android | `media_kit_libs_android_audio` |
| ios | `media_kit_libs_ios_audio` |
| macos | `media_kit_libs_macos_audio` |
| linux | `media_kit_libs_linux` |
| windows | `media_kit_libs_windows_audio` |
| web | （无） |

对照现状：linux 只有 `media_kit_libs_linux`、windows 只有 `media_kit_libs_windows_audio`，
android/ios/macos 列表里**没有任何 media_kit 插件**（本仓库 `.flutter-plugins-dependencies` 实测）。

### 各平台原生库形态与体积

| 平台 | 原生库来源（构建期下载） | 体积 |
|---|---|---|
| Android | `libmpv-android-audio-build` release `v1.1.8` 的 4 个 jar（`media_kit_libs_android_audio` 1.3.8 固定此版本） | jar 合计 **12,004,734 B（≈11.5 MiB）**，每次 Android 构建都会下载全部 4 个 ABI；jar 内 `libmpv.so` 见下表 **【实测】** |
| iOS | podspec 里 `system("make")` → 下载 `libmpv-xcframeworks_v0.6.0_ios-universal-audio-default.tar.gz` 并 `s.vendored_frameworks = 'Frameworks/*.xcframework'` | 上游资产 **7.66 MB**（压缩包，v0.6.0，2023-09-24 发布）；`.app` 实际增量**未实测**（本机无 macOS 工具链） **【三方-GitHub API】+【源码】** |
| macOS | 同上，`libmpv-xcframeworks_v0.6.0_macos-universal-audio-default.tar.gz` | 上游资产 **8.08 MB**；本仓库**没有 `macos/` 目录**，纯死重量 **【三方-GitHub API】+【仓库核对】** |
| Windows | CMake 下载 `mpv-dev-x86_64-20230924-git-652a1dd.7z`，bundle `libmpv-2.dll` | 与 umbrella 相同（同一包 `media_kit_libs_windows_audio` 1.0.9） **【源码】** |
| Linux | 不下载 libmpv，用系统 libmpv（只编译静态 mimalloc） | 与 umbrella 相同 **【源码】** |

`lib/<abi>/` 尺寸（**jar 内实测**，未压缩 / deflate 后）：**【实测】**

| ABI | `libmpv.so` | `libmediakitandroidhelper.so` | 该 ABI 的 jar 文件 |
|---|---|---|---|
| arm64-v8a | **6,215,848** / 2,860,121 | 386,696 / 123,829 | 2,983,585 B |
| armeabi-v7a | 5,648,496 / 2,758,328 | 286,812 / 106,875 | 2,865,617 B |
| x86_64 | 6,983,648 / 2,991,381 | 367,528 / 123,160 | 3,114,935 B |
| x86 | 6,334,772 / 2,911,845 | 350,252 / 128,370 | 3,040,597 B |

（对照：官方 media_kit 测试 APK `media_kit-v1.1.10` 的 `lib/arm64-v8a/libmpv.so` = 11,930,712 / 5,378,522 —
video 版 libmpv 约为 audio 版的 2 倍，说明"用 video libs 会更大"这件事本身是官方产物就能验证的。**【实测】**）

## 5. 体积：A/B 实测

方法：把工作树复制到独立目录，用**仓库自己的发布参数**
（`flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate --extra-gen-snapshot-options=--strip`）
各构建一次 arm64，只改动 pubspec 里有没有 `media_kit_libs_audio: ^1.0.7`。
两次都成功（`BUILD_EXIT=0`），`libapp.so` 字节完全一致——差异只来自插件。**【实测】**

| 产物 | 大小 | 差 |
|---|---|---|
| A：现状（无 `media_kit_libs_audio`） | **13,128,606 B** | — |
| B：+ `media_kit_libs_audio ^1.0.7` | **16,109,338 B** | **+2,980,732 B（+2.84 MiB，+22.7%）** |

其中 `lib/` 压缩后合计 10,835,368 → 13,815,202（+2,979,834），余下 898 B 是插件类带来的 dex/清单。
B 相对 A 新增且仅有这两个文件（APK 内实测）：

```
   6215848 / 2856005   lib/arm64-v8a/libmpv.so
    386696 /  123829   lib/arm64-v8a/libmediakitandroidhelper.so
```

其它 ABI 的 APK 增量**未实测**，按 jar 内 deflate 尺寸估算：armeabi-v7a ≈ +2.75 MB、x86_64 ≈ +3.0 MB、
x86 ≈ +2.95 MB；若构建**不拆分 ABI 的 fat APK**，4 个 ABI 全带上约 **+11.9 MB（估算）**。
本仓库发布走 `--split-per-abi`，所以关注 delta 应取单 ABI 值。

> 注意：仓库里现存的 `app-arm64-v8a-release.apk` 为 13,125,870 B，与本次 A 组（13,128,606 B）
> 相差 2.7 KB，说明基线与实测可复现。**【实测】**

**R8 / `shrinkResources` 不会裁剪未使用的插件 native 库**：本仓库 release buildType 已开
`minifyEnabled true` + `shrinkResources true`（`android/app/build.gradle`），B 组产物里 `libmpv.so`
照样在。也就是说"反正用不到，混淆器会去掉"不成立；想不打包**只能不加依赖**（或手工
`packaging.jniLibs.excludes` / `abiFilters`，属于额外维护面）。**【实测 + 源码】**

## 6. 社区反馈与已知问题

| 内容 | 链接 / 日期 | 与本决策的关系 |
|---|---|---|
| issue #1103「No media_kit_libs_audio package」，同日被关；评论：「Unfindable in pub.dev, but exists nevertheless.」 | <https://github.com/media-kit/media-kit/issues/1103>（2025-02-12） | umbrella 包在 pub.dev 上的可发现性/版本曾让人困惑；按平台包反而更直观 **[三方]** |
| issue #1056「media_kit: armeabi-v7a JAR verification failed.」**至今 open**；社区回复「it an internet problem, try to build again」 | <https://github.com/media-kit/media-kit/issues/1056>（2024-12-08 起） | Android 构建新增"必须能访问 github.com 下载 jar + MD5 校验"的硬依赖；失败会直接中断构建 **[三方]** |
| issue #1189「Add support for 16kb memory page size」（2025-10-05 随 1.3.8 关闭）；正文贴出 Play Console 警告，列出 `base/lib/arm64-v8a/libmpv.so`、`libmediakitandroidhelper.so` 等 | <https://github.com/media-kit/media-kit/issues/1189>（2025-05-14 → 2025-10-05） | 若将来真的把 Android libs 装进来，就继承 Google Play 的 16KB 页对齐要求（1.3.8 changelog 已写 "build: 16KB page size support"，固定的 v1.1.8 jar 即对应版本） **[三方 + 源码]** |
| issue #1231：某应用对含 media_kit 的 `.aab` 做安全扫描，报 zlib CVE-2022-37434 | <https://github.com/media-kit/media-kit/issues/1231>（2025-07-29，open） | Android 侧会多出可被扫描器盯上的二进制；**保持现状则 Android 完全无此暴露面** **[三方]** |
| issue #846「Exclude support for unused codecs」：Windows 应用抱怨「including media_kit bundles a large number of DLLs」 | <https://github.com/media-kit/media-kit/issues/846>（2024-05-30，closed） | 佐证 native 库体积是官方长期已知问题，且**没有**按需裁剪机制 **[三方]** |
| issue #732「How to reduce libmpv building size? How to remove unnecessary codecs…」 | <https://github.com/media-kit/media-kit/issues/732>（2024-03-19，closed） | 同上 **[三方]** |

**没有找到可引用的量化社区报告**：Stack Overflow 检索（`media_kit apk size`、`media_kit_libs_audio`
等）无结果；Reddit 有相关帖子（如 r/FlutterDev "what do you prefer: video_player or media_kit?"）
但正文抓取被拒（403/空壳），检索摘要里提到体积权衡却无法核实原句，**因此本文不引用任何 Reddit 文字**。
本节的体积结论完全来自 §5 的本机实测。

## 7. 代价对比

### 7.1 改用 `media_kit_libs_audio` 的代价

1. **Android 每个 ABI +2.98 MB（arm64 实测）**，与 `docs/pitfalls.md` #13「发布体积」的取向相反；
   fat APK 约 +11.9 MB。
2. **Android 构建新增 GitHub release 硬依赖**：每次 `assembleRelease` 下载 4 个 ABI 共 11.5 MB jar，
   MD5 不符/网络不通即构建失败（#1056）。注意两点免得夸大：
   （a）这不是全新风险——Linux 桌面构建本来就会从 github.com 拉 mimalloc 源码
   （`media_kit_libs_linux` CMake 核对；本机 `build/linux/x64/debug/mimalloc/` 实测存在）；
   （b）本次实测中 GitHub 下载是成功的（构建日志逐行打印了 4 个 jar 的 URL，`BUILD_EXIT=0`），
   所以"能拉到"在本机成立。区别在于**新增的是一条 Android 构建期外网链路**，而现状下
   Android 的原生库来自 pub 包（源码编译或预编译）与 Maven 依赖，不需要访问 GitHub release；
   仓库 `docs/pitfalls.md` #5 记录过 maven.google.com 不可达、改用 `dl.google.com` 镜像的经历，
   说明构建环境的境外连通性不能假定为稳定。
3. **iOS 多 vendor 一份 libmpv xcframework**（上游同类资产 7.66 MB 压缩包，安装包增量未实测），
   而 iOS 走的是 `just_audio` 原生实现，media_kit 后端默认关闭。
4. **macOS 纯死重量**：本仓库连 `macos/` 目录都没有（`ls` 核对），却被 umbrella 拉进依赖图。
5. **收益为零**：umbrella 里的 linux/windows 两个包与现状同版本；android/ios/macos 三个包对本应用
   不提供任何功能（`ensureInitialized` 默认不激活这三端）。

### 7.2 保持现状的代价

1. **手工记忆成本**：新增平台或改用 media_kit 后端时，要记得补对应的 libs 包，否则运行期报
   `Cannot find libmpv…`（`media_kit` 的 `lib/src/player/native/core/native_library.dart` 错误文案里
   明确写了 `Please ensure it's presence in the APK.`）。**【源码】**
   缓解：这一约定已写进 `AGENTS.md` 与本节，且平台判断集中在
   `lib/playback/desktop_audio_init_io.dart` 一处。
2. **与官方 README 写法不一致**：新同事照 README 抄会写出 umbrella。本文即为此存在。
3. **依赖陈旧感**：`media_kit_libs_windows_audio` 最新版仍是 **1.0.9（2023-09-27）**，
   `media_kit_libs_ios_audio` / `_macos_audio` 停在 **1.1.4（2023-09-27）**（pub.dev API 版本列表核对）。
   但这是上游没发新版，不是拆分的锅：**换成 umbrella 拿到的还是同一批版本**；且
   `libmpv-win32-audio-build` 目前最新 release 就是 2023-09-24，pin 无可 pin。**【源码/三方】**
4. **没有"少打包"的保险**：现状下 Linux 依赖系统 libmpv，用户没装 mpv 就播不了（已有优雅降级：
   `desktop_audio_init_io.dart` 捕获异常并记 `desktopAudioInitError`）。这与 umbrella 无关，
   umbrella 在 Linux 上同样不打包 libmpv。

## 8. 复评触发条件

满足任意一条时，回到本文重跑 §9：

1. **media_kit 后端扩展到 Android/iOS**（例如为了统一编解码/无缝播放而放弃 just_audio 的移动端实现）。
   → 改为引用对应平台的 libs（或 umbrella），并按 §5 的方式实测新 ABI 体积。
2. **`just_audio_media_kit` 把 `android/iOS/macOS` 默认值改成 `true`**（升级时会从源码 diff 看出）。
   → 需要同步补齐对应 libs，否则移动端起播失败。
3. **新增 macOS 构建目标并希望在那里用 media_kit**。→ 此时 umbrella 才开始"划算"。
4. **上游废弃按平台包、只剩 umbrella**（pub.dev 版本列表出现 deprecate 公告，或
   `media_kit_libs_linux`/`_windows_audio` 长期停更而 umbrella 仍在发版）。→ 改 umbrella
   并接受 §5 的体积，或用 `dependency_overrides` 只保留桌面两个包。
5. **Play Store 或安全扫描开始针对桌面侧 libmpv 提出要求**（16KB 页、CVE 扫描等，见 §6）。
   → 注意这是"要不要继续用 media_kit"的问题，与拆分/umbrella 无关。

## 9. 复现方法（供下次复评）

```bash
# 1) 复制工作树到独立目录（勿在原地改 pubspec，仓库常有多会话并行改动）
mkdir -p /tmp/mk-ab && tar -C <repo> --exclude=./.dart_tool --exclude=./build --exclude=./.git -cf - . \
  | tar -C /tmp/mk-ab -xf -

# 2) A 组：现状；B 组：pubspec 里加 media_kit_libs_audio: ^1.0.7
#    两组都必须用仓库自己的发布参数，否则 libapp.so 不可比
flutter build apk --release --split-per-abi --split-debug-info=build/symbols \
  --obfuscate --extra-gen-snapshot-options=--strip --target-platform android-arm64

# 3) 只看 lib/ 目录（python3 无需 unzip）
python3 - <<'PY'
import zipfile
z = zipfile.ZipFile('build/app/outputs/flutter-apk/app-arm64-v8a-release.apk')
for i in z.infolist():
    if i.filename.startswith('lib/'):
        print(f'{i.file_size:>12} {i.compress_size:>10}  {i.filename}')
PY
```

另可核验两处"零成本事实"：

```bash
# 平台注册表：确认 android 列表里没有 media_kit*
python3 -c "import json;d=json.load(open('.flutter-plugins-dependencies'));print({k:[p['name'] for p in v if 'media_kit' in p['name']] for k,v in d['plugins'].items()})"

# Android 构建日志：出现下面这行就说明 libs 被打进来了
grep -F 'libmpv-android-audio-build' <build log>
```

## 10. 测量环境（结论的可迁移性）

- Flutter 3.47.7 stable（framework revision `abaf9c5237`）；`android/app/build.gradle`：AGP 9.4.1 /
  compileSdk 37 / NDK 30.0.16248370 / `minifyEnabled true` / `shrinkResources true` /
  `packaging.jniLibs.useLegacyPackaging = true`（.so 以压缩形式入包，这正是上表"压缩后"数字成立的原因）。
- 依赖版本：`just_audio_media_kit` 2.1.0、`media_kit` 1.2.6、`media_kit_libs_linux` 1.2.1、
  `media_kit_libs_windows_audio` 1.0.9；实验组新增 `media_kit_libs_audio` 1.0.7
  （→ `media_kit_libs_android_audio` 1.3.8）。
- 未被实测、只能标注为估算/未知的量：非 arm64 ABI 的 APK 增量、fat APK 增量、iOS/macOS `.app` 增量、
  Windows bundle 增量。
