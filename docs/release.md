# 发布与 CI/CD

> 状态：**已实施**。工作流在 `.github/workflows/`，清单生成脚本在
> `tool/ci/gen_update_manifest.py`，客户端更新实现在 `lib/data/update` +
> `lib/services/update`（决策见 ADR-0006）。

## 1. 流水线总览

| 工作流 | 触发 | 做什么 |
|---|---|---|
| `ci.yml` | PR / push main / 手动 | `flutter analyze` + `flutter test` |
| `integration.yml` | 每日 02:00（UTC+8）/ 手动 | Linux 端到端集成测试（真实引擎 + 本地 mock 服务；不含播放，见 `docs/pitfalls.md` #33；xvfb） |
| `release.yml` | 推 `v*` tag | 矩阵构建 → 汇总产物 + sha256 + `latest.json` → GitHub Release |

CI 的 Flutter 版本固定 `3.47.6`、JDK 26、Android NDK `30.0.16248370`，
与 `AGENTS.md` 的工具链表一致；改版本时两边一起改。

## 2. 版本与渠道

- **tag 即版本**：稳定版 `v1.2.3`；测试版 `v1.2.3-beta.1`（发布为 prerelease）。
- 打 tag 前必须先把 `pubspec.yaml` 的 `version` 改成同一个版本号，
  否则 `prepare` job 直接失败（防止产物版本与 tag 对不上）。
- 构建号（Android versionCode / 更新的新旧判定）取 `github.run_number`，
  单调递增，保证覆盖安装永远被系统接受。
- 客户端两个渠道分别取固定地址（无需 GitHub API，不受匿名限流）：
  - 稳定版：`https://github.com/StillMisty/molia/releases/latest/download/latest.json`
  - 测试版：`https://github.com/StillMisty/molia/releases/download/beta/latest.json`
    （`beta` 是发布流水线每次发测试版时重建的滚动标签）

## 3. 一次性准备

1. **Actions secrets**（Settings → Secrets and variables → Actions）：
   | Secret | 内容 |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 android/molia-release.jks` 的输出 |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
   | `ANDROID_KEY_ALIAS` | key alias（现有 keystore 为 `molia`） |
   | `ANDROID_KEY_PASSWORD` | key 口令 |

   注意：**签名必须与用户已安装的 APK 一致**，否则系统安装器会拒绝覆盖安装；
   keystore 必须长期保存（丢了就只能让用户卸载重装）。

2. pub 源：`pubspec.lock` 锁定 `pub.flutter-io.cn`，工作流统一设置
   `PUB_HOSTED_URL=https://pub.flutter-io.cn` 保持同源（否则 lock 会被改写）。

3. 发布 tag 的 GPG 签名：`git tag -s` 需要本机有 GPG 私钥，且公钥已上传到 GitHub
   （Settings → SSH and GPG keys），Release 页才会显示 Verified。
   `tag.gpgsign` / `commit.gpgsign` 只作用于附注标签与提交，所以发布命令始终显式写 `-s`。

## 4. 发布流程

```bash
# 1. 改 pubspec.yaml 的 version（如 1.2.3+12 的版本前缀必须是 1.2.3）
# 2. 走完 PR 校验后合并到 main
# 3. 打 tag 并推送（稳定版 / 测试版二选一；必须 -s，轻量标签不签名）
git tag -s v1.2.3 -m "Molia 1.2.3" && git push origin v1.2.3
git tag -s v1.2.3-beta.1 -m "Molia 1.2.3-beta.1" && git push origin v1.2.3-beta.1
```

发布产物（Release 资产）：

```
molia-1.2.3-android-arm64.apk / -armv7 / -x86_64
molia-1.2.3-android.aab                 # 上架用，不进更新清单
molia-1.2.3-android-symbols.zip         # obfuscate 调试符号
molia-1.2.3-windows-x64-setup.exe       # Windows 安装器（Inno Setup，安装版首选）
molia-1.2.3-windows-x64.zip             # Windows 便携版
molia-1.2.3-linux-x64.tar.gz
molia-1.2.3-ios-unsigned.zip            # 无签名，仅侧载
latest.json                             # 应用内更新清单
SHA256SUMS.txt
```

桌面压缩包顶层是 `molia-<版本>-<平台>/` 单目录，应用内更新会自动下钻一层。

> Actions 运行页面里下载的 artifact 是「zip 套 zip」（CI 中间产物，供 publish job
> 汇总）；分发给用户请用 Release 资产。

## 5. latest.json 格式

```json
{
  "schema": 1,
  "channel": "stable",
  "version": "1.2.3",
  "build": 42,
  "releasedAt": "2026-10-14T00:00:00Z",
  "notes": "…发布说明 markdown…",
  "notesUrl": "https://github.com/StillMisty/molia/releases/tag/v1.2.3",
  "assets": [
    {
      "platform": "android",
      "arch": "arm64",
      "kind": "apk",
      "file": "molia-1.2.3-android-arm64.apk",
      "url": "https://github.com/.../releases/download/v1.2.3/molia-1.2.3-android-arm64.apk",
      "size": 58123456,
      "sha256": "…"
    }
  ]
}
```

客户端约定：`channel` 必须与请求渠道一致（防止镜像串渠道）；`sha256` 存在
就强制校验，不匹配删除文件并报错；`platform`/`arch` 精确匹配优先、同平台
任意架构兜底（见 `AppRelease.assetFor`）。

## 6. 各平台限制

- **Android**：应用内更新走系统安装器（`REQUEST_INSTALL_PACKAGES` +
  FileProvider，`cacheDir/updates`）；首次需用户在系统里允许「安装未知应用」。
- **Linux**：发布包**不含 libmpv**，运行需系统安装（发行版包名如 `mpv` /
  `libmpv2`）；托盘图标依赖系统 libX11 / libXi（桌面发行版默认都有）与
  StatusNotifier 宿主（GNOME 需 AppIndicator 扩展，缺失时自动降级为无托盘）；
  应用内更新只支持可写的便携目录，系统包管理器安装会降级为手动下载。
  桌面集成（应用菜单条目 + dock 图标）是可选一步：解压后 `./install.sh` 装到
  `~/.local/share`（`uninstall.sh` 移除）；Wayland 下不装就是通用图标（没有
  窗口图标协议），X11 下窗口图标由应用自身设置（`WindowChrome` 的 setIcon）。
- **Windows 安装版**：`setup.exe`（Inno Setup，脚本 `windows/installer/molia.iss`，
  按用户装到 `%LOCALAPPDATA%\Programs\Molia`，无需管理员）；应用内更新会静默运行
  新版本安装器（`/SILENT /NORESTART /CLOSEAPPLICATIONS`），安装器的 `[Run]` 段
  在完成后自动拉起应用。
- **Windows 便携版**：解压 zip 到任意可写目录运行；应用内更新是「解压覆盖 +
  重启」，目录不可写时降级为手动下载。
- **iOS**：无应用内更新（App Store 规则），产物仅供侧载验证。

## 7. 本地验证

```bash
python3 tool/ci/gen_update_manifest.py --help      # 清单脚本自测
flutter test --no-pub test/update                  # 更新链路单测/组件测试
# 试发：先推一个测试 tag（会真的创建 Release，确认后再发正式版）
git tag -s v0.0.1-beta.1 -m "Molia 0.0.1-beta.1" && git push origin v0.0.1-beta.1
```

Windows 安装器可在 Windows 本机单独编译验证：

```powershell
flutter build windows --release
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
  /DAppVersion=0.0.0-test /DVersionNum=0.0.0.0 `
  /DSourceDir="$PWD\build\windows\x64\runner\Release" `
  /DOutputDir="$PWD\dist" windows\installer\molia.iss
```
