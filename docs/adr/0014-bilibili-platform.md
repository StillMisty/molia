# ADR-0014：哔哩哔哩作为第六个内置平台

- 状态：已采纳
- 日期：2026-10-25
- 相关：`lib/sources/builtin/bili_*.dart`、`lib/sources/builtin/builtin_platforms.dart`、
  `lib/sources/source_manager.dart`、`lib/sources/raw_track.dart`、
  `lib/domain/ports/music_source.dart`、`lib/playback/local_playback_service.dart`、
  `lib/playback/next_track_preloader.dart`、`lib/playback/audio_predownloader.dart`、
  `lib/playback/playing_track_cache_writer.dart`、`lib/services/download/`、
  `lib/managers/artwork_cache.dart`、`lib/widgets/track_actions.dart`、
  `test/bili_*_test.dart`、`test/source_manager_bili_test.dart`

## 背景

Molia 的内置平台此前只有五个音乐平台（wy / tx / kg / kw / mg）。LX 脚本覆盖的
「B 站音源」长期依赖用户导入脚本：脚本能搜索、取链，但播放直链需要
`Referer` / 浏览器 UA，而取链结果在早期架构里只有 URL 字符串，请求头在
`SourceManager → CatalogService → 播放器` 的任一环都可能被丢掉，表现为 403。

B 站没有「歌曲」实体：搜索结果与收藏夹都是视频，播放的是视频音轨。把 B 站
做成纯脚本源无法解决三件事：直链请求头、CC 字幕当歌词、收藏夹链接导入。
因此把它收进内置平台，并先把「流请求头」做成全链路契约（Phase 1），
再接业务（Phase 2–4）。

## 决策

1. **新增第六个内置平台 `bili`**（展示名「哔哩哔哩」，默认启用），仍由
   `BuiltinPlatforms` 唯一注册：搜索、原生取链（`resolve`）、评论、歌手（UP）、
   发现五个适配器；**不注册**专辑与按歌词搜歌。`SourceManager._isBuiltinSearchable`
   的判定改为「平台有原生取链适配器 **或** 已有可取链脚本」——B 站不需要脚本
   即可搜索 / 播放，其余五个音乐平台仍要脚本声明取链。
2. **匿名访问，不引入登录**：`bili_api.dart` 维护会话——`/x/frontend/finger/spi`
   取 `buvid3/buvid4`，`/x/web-interface/nav`（code `-101` 也带 `wbi_img`）取
   `img_url/sub_url`，按 64 位混淆表取前 32 位得 mixinKey；请求参数加 `wts`、
   排序、清洗 `!'()*`、URI 编码后 md5 得 `w_rid`。会话 1 小时缓存 + single-flight，
   风控码 `-403/-412` 刷新会话后重试一次。所有请求统一带浏览器 UA + B 站 Referer。
3. **原生取链返回 `PlayableStream`，headers 走全路径**：
   `pagelist` 取首个分 P 的 cid（缓存）→ WBI `playurl`（`fnval=16`）→ `dash.audio[]`
   按 `30280/30232/30216` 选 192k/128k/64k，老视频回退 `fnval=1` 的 `durl`。
   直链只认 UA + Referer，**不带 Cookie**（避免把会话粘进播放器缓存）；
   `expiresIn` 从 URL 的 `deadline` 参数推导，约 120 分钟。`PlayableStream.headers`
   必须原样传到 `AudioSource.uri` / `LockCachingAudioSource` / 下一首预取 /
   桌面缓存写入 / 下载，任一处丢失都会 403。
4. **能力范围**：
   - 搜索：全站视频（`search_type=video`，固定 20/页、最多 50 页）+ UP 搜索
     （`search_type=bili_user`，搜索页「歌手」分段）；
   - 播放：原生音轨（无登录只有三档音频，不含大会员高音质）；
   - 歌词：`/x/player/v2` 的 CC 字幕轨，中文优先、`subtitle_url` 补协议、
     `from` 秒转 `[mm:ss.mmm]` LRC；无字幕返回 null，继续走其它歌词源；
   - 评论：`/x/v2/reply/main`（`type=1&oid=aid`，热门 `mode=3` / 最新 `mode=2`），
     `pagination_str` 游标按「视频 + tab + 页码」存 `CommentCursorStore`；
     该接口**不带 buvid Cookie**（带 Cookie 会退化成 3 条热评 + `is_end=true`）；
   - UP 主页：`card` 资料（失败回退 `space/wbi/acc/info`）+ `space/wbi/arc/search`
     投稿（带 `dm_*` 指纹参数）；`-352` / `v_voucher` 刷新一次仍失败时回退
     `search_type=video&keyword=<UP名>&order=totalrank` 并按 mid 过滤；空间接口
     code 0 但 `vlist` 空、`page.count>0` 同样视为风控走搜索兜底；
   - 发现：单张「B 站音乐榜（三日）」（`ranking?rid=3&day=3`，board id
     `bili__music_3d`，bangid `3:3`）+ 热搜（`search/square?limit=10`）；
   - 收藏夹导入：`/x/v3/fav/resource/list` 按 `media_count` 拉全（上限 50 页 /
     1000 条），只收 `type==2`、`attr==0`、有 `bvid` 的视频；rawId 支持数字、
     `fid=` / `media_id=`、`medialist/detail/ml<id>`、`space.bilibili.com/.../favlist`
     与 `b23.tv` 短链（跟随跳转后解析）。
5. **边界（明确不做）**：专辑、按歌词搜歌、登录 / 大会员高音质、歌单浏览 /
   搜索（`BiliDiscoverSource.supportsPlaylists=false`，UI 隐藏「歌单」tab）、
   私密收藏夹导入（`info` 缺失 → `notFound`）。
6. **周边适配**：raw 原样保留 `bvid/aid/cid/source` 并补 `_types['192k','128k','64k']`
   与 `_artists`；通用 id 优先级把 `bvid` 放最前，`.lxmc` 平台优先键为
   `['bvid','aid','id']`，不登记规范字段（不需脚本取链）；下载扩展名 `.m4s` 归一为
   `.m4a`；`hdslb.com` / `biliimg.com` 封面带 B 站 Referer；歌曲信息页/分享页
   支持 `bvid` / `av<aid>` 页面地址。
7. **l10n 文案**：歌单导入相关文案改为「歌单 / 收藏夹」双语表述（导入入口共用
   `showLinkImportDialog`，平台列表来自 discover 渠道）。

## 后果

- 不需要 LX 脚本即可搜索、播放 B 站视频音轨；脚本源与其它内置平台不受影响
  （`PlayableStream.headers` 默认为空，旧路径行为不变）。
- 直链有效期有限：缓存 / 下载优先存文件，播放失败会重新取链；不能假设 URL 长期有效。
- 评论游标是进程内状态：跳页 / 状态丢失时退回首页（不带游标），重复项由上层按 id 去重。
- 收藏夹导入只支持公开收藏夹；失效 / 私密条目按 `notFound` 失败，不做静默空结果。
- B 站接口以浏览器指纹与 WBI 签名做风控，端点 / 参数可能变化；实现集中在
  `bili_api.dart` 与各业务文件，风险不扩散到其它平台。

## 风险与验证

- **风控**：`-352` / `-412` / `-403` / `v_voucher` 是常态而不是异常；已实现刷新
  会话重试、UP 空间接口搜索兜底、收藏夹 `info` 容忍后续页缺失；仍可能因平台
  策略变化整体不可用。
- **WBI / buvid**：密钥轮换与 Cookie 失效靠 1 小时缓存 + 刷新兜底；算法由固定
  测试向量钉住（`test/bili_wbi_test.dart`）。
- **请求头**：B 站直链 / 封面 / 短链都校验 UA + Referer；headers 透传由
  `test/source_manager_bili_test.dart` 与播放链路测试覆盖，真机播放另做手工验证
  （见「待人工」）。
- **测试**：fixture + `MockDioAdapter`，不依赖真实网络；`flutter analyze --no-pub`、
  `flutter test --no-pub`、`tool/agent/test.sh linux` 全绿。
- **待人工**：真机 / 模拟器上验证搜索播放、CC 字幕、评论翻页、UP 页、音乐榜、
  公开收藏夹导入；B 站风控可能让 live smoke 偶发失败，不作为 CI 门槛。
