# 移动端后台功耗：策略、改动与验证

> 本文记录移动端（Android / iOS）息屏 / 后台听歌时的功耗控制。启动阶段见
> `docs/performance.md`，桌面托盘内存见 `docs/memory.md`；本文只覆盖
> 「屏幕不在应用上时，哪些工作应该继续、哪些应该停」。

## 1. 结论（一行）

后台听歌只保留**播放必需**与**用户仍在看的输出**：位置采样 / 会话落盘降频
（#44），封面预取、无消费面的取色、无输出的取词、下一首音频字节预取全部停掉；
下一首直链仍预热，定时关闭的 partial wake lock 只在后台 / 息屏时持有。

## 2. 信号源

`PlaybackPowerPolicy`（`lib/playback/playback_power_policy.dart`）由组合根创建
唯一实例，同时注入播放栈、播放观察者、歌词显示栈与下一首预载。

| 信号 | 来源 | 用途 |
| --- | --- | --- |
| 前后台 | Android / iOS `AppLifecycleListener`（`onResume` / `onPause` / `onHide`） | 位置采样档位、会话落盘节流、后台工作门控、定时关闭 wake lock |
| 桌面歌词可展示 | `LyricsChannel.isSupportedPlatform && desktopEnabled` | 后台位置采样保持高频；允许后台取色（悬浮窗可跟随封面配色） |
| 任一歌词输出 | 桌面 / 通知锁屏 / 蓝牙开关 | 决定后台是否值得取词 |
| 桌面窗口可见性 | `AppPresence`（**仅桌面**） | 托盘 / 最小化停产封面预取与取色 |

移动端退后台**不**写 `AppPresence`：托盘是桌面窗口语义，混入生命周期会让
「关闭到托盘」和「切到后台」互相污染（见已知坑 #71）。

## 3. 改了什么

| 位置 | 前台 | 后台（息屏 / 切走） |
| --- | --- | --- |
| 位置采样 `LocalPlaybackService` | `positionStream`（约 5Hz） | 1s 轮询；后台暂停不采样 |
| 会话落盘 `PlaybackSessionCoordinator` | 1s 节流 | 15s 节流（进入后台先强制提交一次，store 按队列是否变化决定整份 / 游标） |
| 封面预取 `PlaybackObserver` | 当前 + 下一首 + 队列 5 张 | 不预取；回前台补一次 |
| 封面取色 `ArtworkThemeSync` | 正常取色 | 仅桌面歌词可能展示时取色；否则只记 URL，回前台补 |
| 当前 / 下一首歌词 `wireLyricsSession` / `wireNextTrackLyricsPreload` | 正常取词 / 预载 | 有任一词输出才取词；否则等回前台或打开输出 |
| 下一首预载 `NextTrackPreloader` | 预热直链 + 预取音频字节 | **只**预热直链；不下载整首下一曲 |
| 定时关闭 wake lock `SleepTimerChannelHandler` | 不持锁（屏幕亮着 Handler 正常调度） | 持 partial wake lock，保证 Doze 下到点回调 |

## 4. 为什么

- **封面预取**：结果只服务应用内页面。后台解码 5–8 张封面既占图片缓存，
  又持续触发网络 / 磁盘；悬浮窗不显示封面，通知封面由媒体会话单独按需本地化。
- **取色**：要解码封面并跑量化，只有应用主题与桌面歌词「跟随封面」消费。
  通知 / 锁屏歌词只用文本与播放态，不需要主题色。
- **取词**：后台没有歌词输出时，取到的歌词没有任何展示面；回前台再取只会
  多一次请求，用户看不到差异（歌词页打开前本来就要等取词）。
- **下一首字节预取**：边播当前曲目 + 整首预下载下一曲会让网络长期停在
  高吞吐状态。直链仍预热，切歌不会多等一次取链；缺少的只是「下一首本地
  已就绪」的提前量，真正播放时会边播边缓存。
- **定时关闭 wake lock**：前台屏幕亮着时主线程 Handler 不会被 Doze 冻结，
  为一个 30–60 分钟的定时常驻 partial wake lock 只会阻止 CPU 深睡。

## 5. 验证

自动化（本机）：

```bash
flutter analyze --no-pub
flutter test --no-pub
```

覆盖点：
- `test/playback/playback_power_policy_cases.dart`：后台门控组合与幂等通知；
- `test/services/playback_observer_test.dart`：移动端后台不预取封面、回前台补；
- `test/services/artwork_palette_service_test.dart`：后台无悬浮窗不取色、开悬浮窗允许；
- `test/app/lyrics_session_wiring_cases.dart`：后台无输出不取词、回前台补、有输出照常；
- `test/playback/next_track_preloader_test.dart`：直链仍预热、字节预取可门控；
- `test/playback/sleep_timer_test.dart`：前台 arm 不持锁、退后台重排持锁。

真机 / 模拟器（待补基线）：

```bash
# 息屏播放 30 分钟，前后各取一次；重点看 wakeup / 网络字节 / 电量
adb shell dumpsys batterystats --reset
adb shell dumpsys batterystats | rg -i "molia|wakelock|wakeup"
adb shell dumpsys netstats detail | rg -i -A6 "molia"
adb shell dumpsys power | rg -A4 "Molia:SleepTimer"
```

验收口径：
- 息屏且没有歌词输出时，切歌不再产生封面图 / 歌词 / 下一首音频的连续网络
  请求（可用 `netstats` 对比「前台切 10 首」与「息屏切 10 首」）；
- 开启通知歌词或桌面歌词后，后台仍能换行 / 更新颜色；
- 定时关闭设置 30 分钟：前台期间 `dumpsys power` 不出现 `Molia:SleepTimer`，
  熄屏后出现，到点正常暂停；
- 回前台后当前曲目封面、主题色、歌词在列表滚动前补齐。

> 当前开发环境没有 Android 设备，以上真机数据未采集；逻辑行为由单测覆盖。
