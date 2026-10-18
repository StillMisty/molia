---
name: Molia 发布流程
description: 发布 Molia 版本，或改动发布产物 / 更新清单 / 平台打包时使用：版本号对齐、签名 tag、稳定版与 beta 渠道、构建号、Actions secrets 与 GPG 前置、产物清单、latest.json、各平台更新限制。触发词：发布、release、tag、版本号、latest.json、GitHub Release、secrets、试发。
---

# Molia 发布流程

工作流在 `.github/workflows/`，清单生成脚本 `tool/ci/gen_update_manifest.py`，客户端更新在
`lib/data/update` + `lib/services/update`（决策见 `docs/adr/0006-in-app-update.md`）。

## 1. 流水线总览

| 工作流 | 触发 | 做什么 |
|---|---|---|
| `ci.yml` | PR / push main / 手动 | `flutter analyze` + `flutter test` |
| `integration.yml` | 每日 02:00（UTC+8）/ 手动 | Linux 端到端（真实引擎 + 本地 mock；不含播放，见 `docs/pitfalls.md` #33；xvfb） |
| `release.yml` | 推 `v*` tag | 矩阵构建 → 产物 + sha256 + `latest.json` → GitHub Release |

Flutter `3.47.7`、JDK 26、Android NDK `30.0.16248370` 与 `AGENTS.md` 的工具链表同源，
改版本时两边一起改。

## 2. 发一个版本

1. `pubspec.yaml` 的 `version` 改成与 tag 同一个版本号（tag 即版本：稳定版 `v1.2.3`，
   测试版 `v1.2.3-beta.1` 发布为 prerelease）。对不上 `prepare` job 直接失败。
2. 走完 PR 校验后合并到 `main`。
3. 打签名 tag 并推送（稳定版 / 测试版二选一）：

   ```bash
   git tag -s v1.2.3 -m "Molia 1.2.3" && git push origin v1.2.3
   git tag -s v1.2.3-beta.1 -m "Molia 1.2.3-beta.1" && git push origin v1.2.3-beta.1
   ```

   必须显式 `-s` + `-m`：签名只能挂在附注标签（tag 对象）上，裸 `git tag` 签不签取决于
   本机 `tag.gpgSign`（没配 → 未签名轻量标签；配了 → 附注签名标签并要求消息）；`-m` 免开编辑器。
4. 看 `release.yml` 跑完：版本校验 → 矩阵构建 → 汇总产物 + sha256 + `latest.json`
   → GitHub Release；测试版为 prerelease，并另滚动 `beta` 标签（流水线用 GitHub API
   创建的轻量标签）供客户端取清单。

完成判据：Release 页出现该 tag，资产含全部平台产物 + `latest.json` + `SHA256SUMS.txt`。

## 3. 渠道与构建号

- 客户端按固定地址取清单（无需 GitHub API，不受匿名限流）：
  - 稳定版 `https://github.com/StillMisty/molia/releases/latest/download/latest.json`
  - 测试版 `https://github.com/StillMisty/molia/releases/download/beta/latest.json`
- 构建号（Android versionCode 与更新新旧判定）取 `github.run_number`，单调递增，
  保证覆盖安装永远被系统接受。

## 4. 一次性准备（换机 / 重建仓库时）

1. **Actions secrets**（Settings → Secrets and variables → Actions；缺一个发布就失败）：

   | Secret | 内容 |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 android/molia-release.jks` 的输出 |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
   | `ANDROID_KEY_ALIAS` | key alias（现有 keystore 为 `molia`） |
   | `ANDROID_KEY_PASSWORD` | key 口令 |

   **签名必须与用户已安装的 APK 一致**，否则系统安装器拒绝覆盖安装；
   keystore 必须长期保存（丢了就只能让用户卸载重装）。

2. **签名 tag 的 GPG**：本机有私钥，且公钥已上传 GitHub（Settings → SSH and GPG keys），
   Release 页才显示 Verified；发布机没有私钥时 `git tag -s` 直接失败——宁可不发，
   也不发未签名标签。

3. **pub 源**：`pubspec.lock` 锁定 `pub.flutter-io.cn`，工作流统一设
   `PUB_HOSTED_URL=https://pub.flutter-io.cn` 保持同源（否则 lock 会被改写）。

## 5. 产物清单

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
Actions 运行页下载的 artifact 是「zip 套 zip」（CI 中间产物），分发给用户请用 Release 资产。

## 6. 本地验证

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

## 参考

- `references/latest-json.md` — `latest.json` 字段与客户端校验约定（改清单或更新链路时读）。
- `references/platforms.md` — 各平台产物与更新限制（改打包或平台更新行为时读）。
