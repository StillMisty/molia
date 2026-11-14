# ADR-0029：凭据统一存本机数据库，不依赖系统安全存储

- 状态：已采纳
- 日期：2026-11-14
- 相关：`lib/data/credentials/credentials_database.dart`、
  `lib/data/settings/settings_secret_store.dart`、
  `lib/data/settings/settings_registry.dart`、`lib/data/sync/sync_state_store.dart`、
  `lib/services/bili_account_service.dart`、`lib/providers/sync_provider.dart`、
  ADR-0003、ADR-0016、`docs/pitfalls.md` #31

## 背景

凭据此前统一走 `flutter_secure_storage`（Linux = libsecret / 系统钥匙串，
Android = Keystore）。在没有 Secret Service 的 WSLg / 容器 / 最小桌面里，
libsecret 抛的是**原生 C++ 异常**，Dart 层的 `try/catch` 兜不住，进程会被
直接 `terminate`。表现是：窗口已经显示，但没有首帧，应用永久黑屏 / 退出。

启动路径上只要有一次同步口令、B 站 Cookie 或 AI 配置的读取，就会命中这个
问题。先用「B 站 prefs 提示 + 页面懒 init」打补丁，结果是启动、字幕、AI、
听歌同步各自多一套提示 / 兜底，复杂度反而更高。用户明确选择：
**所有凭据统一进数据库，接受本机明文风险；需要时再读，不常存。**

## 决策

1. **新增独立凭据库** `molia_credentials_v1.sqlite`：
   - drift 表 `credentials(key TEXT PRIMARY KEY, value TEXT, updatedAt INTEGER)`；
   - 与资料库 `molia_database_v2.sqlite` 分开，不进资料库 schema 迁移链；
   - 首个读写才懒打开；与资料库共用 `MoliaDatabase.openAt` 的 WAL /
     busy_timeout 参数。
2. **`SettingsValueStore.secure` 的语义改为「凭据存储」**：
   - 生产实现 `DatabaseSettingsSecretStore` 读写上述凭据库；
   - 移除 `flutter_secure_storage` 依赖与各平台插件注册；
   - B 站 Cookie、AI Base URL / API Key / 模型、ListenBrainz / Last.fm Token、
     同步口令、WebDAV 密码全部落在这里。
3. **读取时机按消费面决定，禁止启动路径依赖系统钥匙串**：
   - B 站账号：启动时读取，登录用户的字幕链路不依赖「先打开账号页」；
   - AI / 听歌同步：首帧后初始化；对应页面打开时再补一次（幂等）；
   - 同步口令：用户开启传输 / 配对或读取设置时按需生成 / 读取；
   - 读取失败一律按「未设置 / 未登录 / 未连接」降级；写入 / 删除失败仍抛出。
4. **不再用 prefs 提示或页面懒 init 绕过存储层问题**。存储层已不依赖系统
   钥匙串，新增凭据键直接走 `DatabaseSettingsSecretStore`，不再新增
   `bili_cookie_present_*` 之类的 workaround。
5. **安全口径是明确的取舍**：
   - 凭据明文 SQLite；应用沙箱 / 本机文件权限是唯一边界；
   - 同步载荷仍由同步口令加密，但口令本身也只在本机凭据库中；
   - 能读本机数据目录 / 备份文件的人也能读到凭据；
   - 旧钥匙串凭据不自动迁移，升级后需要重新登录 / 填写 Key / 设置同步口令。

## 后果

- Linux / 容器 / 无 keyring 环境不再因 libsecret 原生异常终止；启动路径与
  普通听歌、收藏页、字幕链路都不依赖系统钥匙串。
- 凭据库文件（及其 WAL）属于敏感文件；完整备份 / 数据目录拷贝会把凭据一起
  带走，这是接受本机明文后的必然结果。
- 新增凭据键或迁移存储实现时，必须：
  - 复用 `SettingsSecretStore` / `SettingsRegistry.secure` 面；
  - 保证读取失败可降级、不阻断启动；
  - 补凭据库读写测试与同步 / 字幕 / AI / scrobble 的消费面测试。
- 如果未来重新引入系统安全存储，必须先有**不会原生崩溃的可用性探测 + 降级
  方案 + 旧凭据迁移路径**，且不得把启动路径重新绑回钥匙串。
- 旧行为回归记录见 `docs/pitfalls.md` #31；B 站凭据语义见 ADR-0016 修订，
  同步口令 / WebDAV 密码语义见 ADR-0003 修订。
