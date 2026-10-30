# ADR-0016：B 站账号扫码登录（仅用于字幕歌词）

- 状态：已采纳（2026-10）
- 相关：ADR-0014（B 站音源）、ADR-0003（跨设备同步）、`lib/sources/builtin/bili_*.dart`、`lib/services/bili_account_service.dart`

## 背景

ADR-0014 把 B 站收进内置平台时，把 CC 字幕作为「同源歌词」：

> `/x/player/v2` 的 CC 字幕轨……无字幕返回 null，继续走其它歌词源。

实现后实测（2026-10，多个视频、带 buvid、不带登录态）：

- `/x/player/v2` 返回 `code: 0`，但 `data.subtitle.subtitles` **恒为空数组**；
- 公开资料与 B 站前端行为一致：CC / AI 字幕列表需要登录 Cookie（`SESSDATA`）；
- 因此 B 站曲目的原生取词总是失败，随后掉到跨平台名字搜索，网易云通常最快返回。
  用户看到「B 站歌曲 → 网易云歌词」，且 UP 主被当作歌手，匹配质量不稳定。

手动让用户从浏览器复制 `SESSDATA` 对普通用户不可接受。B 站没有面向第三方
的 OAuth 客户端接入，官方网页登录流程是扫码登录。

## 决策

1. **新增可选的 B 站扫码登录**（不是 Molia 账号系统）：
   - `passport.bilibili.com/x/passport-login/web/qrcode/generate` 生成二维码；
   - `.../qrcode/poll` 每 2s 轮询：86101 未扫码 / 86090 已扫码 / 86038 过期 /
     `data.code == 0` 成功；
   - 兼容两代成功格式：旧版 `data.url` query 里的 Cookie，以及 2026-08 后的
     crossDomain ticket + `Set-Cookie`（必要时手动跟跳逐跳采集）。
2. **凭据是凭证类别的设置键** `kBiliAccountCookie`：
   - `SyncCategory.credentials` + `SettingsValueStore.secure`；
   - 凭证类别默认开启 → **开启跨设备同步后默认同步**（快照 AES-256-GCM 加密）；
   - 完整备份默认导出全部类别与凭证（B 站登录、AI Key、any-listen token），
     换机恢复后与备份时一致；`includeCredentials: false` 只作为显式排除凭证的逃生口；
   - 退出登录写回默认值，清空会随同步传播到其它设备。
3. **登录态只服务字幕 / 账号资料**：
   - 字幕：`/x/player/wbi/v2`（buvid + WBI + 账号 Cookie），失败退回
     `/x/player/v2`（账号 Cookie）；
   - 账号资料：`/x/web-interface/nav`（账号 Cookie）；
   - 播放直链、搜索、评论、收藏夹、字幕 CDN **继续匿名**，绝不带账号 Cookie。
4. **未登录不伪造「B 站歌词」**：`BiliLyric` 在无账号 Cookie 时直接返回 null，
   省掉必然为空的请求；跨平台回退保持原样（网易云等）。
5. **登录后的同源刷新**：
   - 清 `BuiltinLyricDispatch` 的 `bili:` 取词缓存（含缓存过的 null）；
   - 当前 B 站曲目强制绕过歌词缓存重取；
   - 后续 B 站曲目若缓存来源不是 `bili` 且已登录，先试原生；
   - 用户手动选择的歌词（`LyricCacheData.manual`）不被覆盖。
6. **入口放音源管理页**（「平台账号 → 哔哩哔哩账号」），不占用设置首屏。
7. **字幕同时作为手动歌词来源**：换源页「歌词」tab 的 `LyricsSourceRegistry`
   把 B 站字幕列为可选来源（通用 `BuiltinLyricProvider`）；未登录时只显示登录
   提示、不发搜索请求。只进手动换源，不参与 `LyricsService` 的跨平台自动竞速
   ——视频结果不是歌曲实体，自动回退容易拿错。手动选择写 `manual=true`，
   登录后的原生刷新不覆盖。

## 后果

- 用户扫码后，带 CC / AI 字幕的 B 站视频可以使用 B 站字幕作为歌词；无字幕的
  视频仍回退其它平台（明确不做「B 站永不匹配网易云」）。
- 换源页「歌词」tab 可以从任意 B 站视频的字幕里手动选歌词（未登录只提示登录）；
  同源换源（B 站 → 其它 B 站投稿）与音频换源共用 `SourceSwapStrategies`。
- 登录信息随凭证类别同步 / 备份：同步组内其它设备可直接使用该 B 站账号；
  B 站可能因多设备 / 多 IP 触发风控。用户可在同步内容页关闭凭证类别，或退出登录。
- **完整备份文件本身是明文 JSON**：默认包含 B 站登录、AI Key、any-listen token
  等全部凭证，请按敏感文件保管；同步快照仍由同步口令加密。备份覆盖同步类别
  （歌单 / 历史 / 设置 / 音源 / 统计 / 会话 / 封面）与全部凭证；窗口位置、
  缓存策略、字体等设备相关设置与本地缓存文件不在 JSON 备份内。
- 登录态失效（nav `-101`）时清掉同步凭据，其它设备随后同步退出。
- 二维码 URL / qrcode_key / Cookie 不写日志；安全存储读取失败按未登录处理。
- 依赖新增 `qr_flutter`（纯 Dart，二维码渲染；无原生代码）。

## 替代方案

- **手动填 Cookie**：拒绝，普通用户操作成本过高。
- **匿名取字幕**：实测不可行（`subtitles` 恒为空）。
- **不做 B 站同源歌词**：会让 B 站曲目永远显示网易云等跨平台匹配，违背需求。
- **Molia 账号 / 第三方 OAuth**：B 站没有可用 OAuth，且本项目不引入自有账号系统。

## 修订

- 2026-10-30：二维码渲染从 `qr_flutter` 换成直接依赖 `qr`（`QrCodeView`
  自绘方形码点），去掉只在这一处使用的包装层。
