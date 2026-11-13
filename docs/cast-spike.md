# 投屏与 Android Auto spike 结论

状态：**spike 未完成，生产入口保持缺席**。本文件记录验证边界，避免把
「接口 / 纯模型已测」误读成「真实设备可用」。Chromecast 后置，CarPlay 明确不做。

## AirPlay

- 未在 iOS / macOS 真机上手动选择 AirPlay 路由验证。
- 没有新增「在 AirPlay 播放」入口：系统音频会话是否已经承接路由尚未确认，
  不能先承诺行为。
- 不需要新增协议代码；若后续确认系统路由已生效，只加一条上下文说明入口，
  不复制系统路由选择器。

## DLNA

- 只实现了接口与纯逻辑：`CastSourcePolicy`、`CastSessionController`、
  `LocalMediaServer`、`CarBrowseTreeBuilder`。
- `LocalMediaServer` 已在 loopback 上验证令牌、Range、路径穿越拒绝与关闭；
  **没有**真实 DLNA 渲染器参与。
- SSDP 发现与 AVTransport 请求尚未实现，也没有真实局域网验证。
- 平台链接只允许无请求头、剩余有效期 ≥ 10 分钟的地址；B 站等带
  `Referer` / UA 的链接按策略拒绝。

## Android Auto

- `CarBrowseTreeBuilder` 的树形、稳定 id 与队列下标映射已在 Dart 侧测试。
- 单会话约束未解决：当前媒体会话由 media-session 插件持有，尚未证明能把
  浏览树挂到同一个会话；**没有**新增第二个 Media3 会话，也没有原生
  `MediaLibraryService`。
- 在单会话方案验证前不进入车机 UI，Android Auto 继续延后。

## Chromecast / CarPlay

- Chromecast：需要 Google Cast SDK 与 sender identity，后置。
- CarPlay：需要 Apple entitlement，当前分发方式无法获得，明确不在范围。
