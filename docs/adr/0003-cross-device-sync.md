# ADR-0003：跨设备数据同步（口令信任根 + 全量合并 + 双传输）

- 状态：已采纳
- 日期：2026-10-11
- 相关：`lib/domain/models/device_sync.dart`、`lib/domain/ports/sync_transport.dart`、
  `lib/data/sync/**`、`lib/providers/sync_provider.dart`、`lib/pages/sync_settings_page.dart`

> **2026-10-21 起**：状态键 / 局域网发现与 HTTP 路径 / WebDAV 命名已硬断代，
> 配对码在 v4（2026-10-23）整体删除；现行口径见文末「v3 修订」与「v4 修订」。
> 前文中的 `*_v1`、`molia-pair:*` 与 `/molia-sync/v1/*` 只作历史记录，
> 不代表当前实现。

## 背景

用户要求把「各个平台」的数据在多设备间同步：**歌单与收藏、音源（LX 脚本与配置）、
应用设置，以及听歌统计、AI DJ 配置与 API Key**。应用是纯本地单机架构，无账号与
官方服务端；此前只有 F 面向最近播放上下文的全量导出/导入。

两个必须显式记录的产品决策：

1. **API Key / any-listen token 也要同步**，因此快照离开设备前必须加密；
2. **「允许同步了就代表设备完全被信任」**——不做逐设备审批、不做脚本接收确认、
   不做凭证类别警告；加入同步组即完全互信。

## 决策

1. **信任模型：同步口令即信任根**。首台设备生成 32 字符口令（约 160 bit 熵），
   其它设备输入同一口令即加入；能解密快照的设备即已授权。撤销 = 重置口令
   （所有设备重新加入），重置同时清空本机对旧组的观测（名册 / 已验证端点 /
   首连提示 / 传输成功时间），地址簿（host / 端口）作为用户配置保留。设置页
   不提供逐设备审批或黑名单。
2. **全量合并模型**：每台设备持有自己已知的完整视图（记录 = `key + updatedAt +
   updatedBy + data`，删除为墓碑记录），交换快照后逐键 LWW
   （`(updatedAt, updatedBy)` 字典序大者胜，deviceId 决平局保证确定性）。
   天然幂等、无版本向量；推送前裁剪 90 天前的墓碑防止无限膨胀。
3. **加密**：列式二进制载荷 → 可选 raw deflate → AES-256-GCM；帧 =
   `magic('MSY', 3) | version(1) = 3 | nonce(12) | 密文+GCM tag`，头部作 AAD。
   密钥派生两级：根密钥 = `PBKDF2(口令, 应用级固定盐, 120k 迭代)` 按口令在会话内
   缓存一次，帧密钥 = `HKDF(根密钥, 帧 nonce)`。服务端 / 局域网抓包只见密文；
   API Key 随凭证类别一并进入密文。

   > **2026-10-18 修订（取代本条的旧帧布局与 v1 兼容描述）**：帧不再携带盐与
   > 迭代数（帧 nonce 已保证 (key, nonce) 唯一），v1 帧派生路径与兼容测试一并
   > 删除；线上载荷只有列式二进制（JSON 只服务完整备份与编码对照测试）。
   > 完整口径见 §1「协议自始为 v3」。
4. **传输与引擎解耦**：`SyncTransport` 端口（`pull` / `push` / `incoming`），
   首期两个实现同时可用、可分别开关：
   - **局域网直连**：UDP 广播探测（`molia-sync.probe`）+ 每设备内置 HTTP 快照端点
     （`GET/POST /molia-sync/v1/snapshot`，密文传输）；
   - **用户自备 WebDAV**：每设备上传 `<remoteDir>/<deviceId>.msync` 密文文件，
     PROPFIND 列表 + GET/PUT 读取其余设备快照；跨网络、异步。
5. **同步内容与粒度**（类别可开关，关闭后本机既不推送也不应用该类）：
   - `playlists` / `playlistTracks`：列表引入稳定 `syncId`（收藏固定常量），
     逐行 LWW + `sync_tombstones`；
   - `sources`：LX 脚本按 `importedAt` 取新（删除用登记墓碑），渠道顺序 / 停用 /
     音质 / any-listen 连接配置；
   - `settings`：**跟人走**的键（主题、语言、导航、歌词显示、默认播放模式等）；
     省流、缓存策略、字体、桌面歌词悬浮窗开关等**设备相关项不同步**；
   - `credentials`：AI DJ 配置 + AI Key + any-listen token；
   - `statistics`：`play_events` 按 `syncKey` 去重合并（事件行**不再自带**曲目
     内容——导出侧 join `play_tracks` 补齐后记录仍自包含，线上格式与 v5 之前
     逐字一致；存量行导出时按内容哈希回填 syncKey）；
   - `history`：`play_history` 按 `(sourceKey, songId)` 合并、时间戳 = `playedAt`；
     用户删除（单条 / 批量 / 清空）写墓碑，上限淘汰不写墓碑；
   - `session`：上次播放会话（队列 / 下标 / 进度 / 模式）单例记录，时间戳 = 会话
     写入时间（`savedAt`），用于换设备接着听；**本地清空不回传删除**（停止播放
     只影响本机，远端更新的会话仍按 LWW 重新填充）；
   - `covers`：自定义封面（每曲 + 全局默认封面图片），**默认关闭**。图片以
     base64 随快照 / 日志进入既有密文载荷；关闭期间本机仍登记本地变化，重新
     开启后由全量快照与后续变更补传，不额外保存第二份状态。封面属于大类别，
     **不进入蜂窝小类别**（`SyncCellularPolicy.auto` 下等 Wi-Fi）；单张超过
     500KB 只跳过同步（本地封面继续可用）。旧版本无法解析含 `covers` 的
     快照（未知类别拒绝整份载荷），开启该类别即与旧版本硬断代，需同组设备
     一起升级。
6. **设置同步的变化检测用「登记哈希」**：同步层登记每个键的值哈希与时间戳，
   每轮对比当前值判定本地修改，应用远端后同步登记——不改造散落在 19 个文件里的
   SharedPreferences 写入方。

   > **2026-10-12 修订**：登记键（跟人走 / 音源 / 凭证）的读写已收进
   > `lib/data/settings/settings_registry.dart`，键声明唯一在
   > `lib/data/settings/settings_keys.dart`；组合根注入唯一实例，模块在构造时
   > 把 reload 钩子绑到自己的键。本条「不改造写入方」的适用范围收窄为
   > **未登记的设备本地键**；变化检测仍是登记哈希（同步适配器不再自带键表与
   > 类型转换）。登记表此前已漏掉真实键（如 `ai_dj_enabled` /
   > `source_swap_auto_enabled`），现按「跟人走」登记；
   > 漏登记从此等于显式选择不同步，由
   > `test/architecture/settings_keys_test.dart` 守住「一个键一个家」。
7. **落位与接线**：领域模型 / 端口在 `lib/domain`；引擎、适配器、传输、状态存储在
   `lib/data/sync`；`SyncProvider` 提供 UI 状态；组合根在 `main.dart` 创建并在
   启动 / 数据变更去抖 / 每 10 分钟 / 回前台时触发同步。Web 隐藏入口（传输依赖
   dart:io，且无接收端）。同步应用后的定向重载（主题 / 导航 / 语言 / 音源等）
   经 `PrefsSyncAdapter.onApplied` 在组合根接线。

   > **2026-10-22 实现说明（不改变上述决策）**：轮次执行从引擎收进独立编排器
   > `lib/data/sync/sync_round.dart`（`SyncRoundRunner`：collect / pull /
   > consume + apply / publish + compact / report；测试经 `runRound` 驱动整轮），
   > `SyncEngine` 只保留公共门面；拉取动作（skip / delta / full）由
   > `sync_pull_plan.dart::decideSyncPull` 统一判定，传输只提供证据（局域网
   > `snapshotId + snapshotFresh`，WebDAV `etag` / `lastmodified` + 回执头部）；
   > 传输的 ensure / start / stop / resume / hidden / announce 收进
   > `sync_transport_runtime.dart`，引擎与控制面共享同一实例。模块仍在
   > `lib/data/sync`，协议、信任模型与合并语义不变。

8. **完整备份（导出/导入）复用同一 envelope**：`SyncEngine.exportBackupJson` /
   `importBackupJson` 经适配器收集与合并，不要求启用同步或口令；
   **凭证类默认排除**（避免 API Key 落进明文备份文件），调用方可显式包含。
   数据与存储页的导出/导入在同步可用时走完整备份，否则退回旧的最近播放导出。

   > **2026-10-19 修订（仅代码位置）**：备份实现从 `SyncEngine` 移到独立模块
   > `lib/data/sync/sync_backup.dart`（`SyncBackup.exportBackupJson` /
   > `importBackupJson`）。本地记录的收集入口由引擎注入
   > （`SyncEngine.collectRecords`），适配器 / 状态存储 / 版本戳发号器与时钟
   > 注入不变，**导出内容、凭证排除、LWW 合并、结构校验与错误语义全部不变**；
   > 这样备份测试不必构造传输与轮次，引擎的 interface 也不再为备份留方法。
   > 同轮把 UI 面的身份 / 传输开关 / 运行状态 / 口令生命周期收进
   > `sync_control_plane.dart`（与引擎共享同一状态存储），§7 的「`SyncProvider`
   > 提供 UI 状态」口径不变——provider 仍是 UI 的唯一门面。

## 后果

- 加入同步的设备可读全部同步数据（含可执行脚本与 API Key）：口令泄露 = 全部失守，
  UI 明示「重置口令即撤销」；这是完全信任模型的应有代价，不再加防呆；
- 时钟不可信时以 `deviceId` 决平局：时钟大幅漂移的设备可能持续输给对端，
  属可接受的个人设备场景；LWW 保证多设备收敛；
- 并发编辑同一歌单的顺序可能有轻微错序（行级 LWW 的已知限制）；删除语义依赖墓碑
  保留期（90 天），超期离线设备的旧数据理论上可复活；
- 局域网同步要求两端应用同时在线（移动端后台限制）；WebDAV 可异步收敛；
- WebDAV 各家实现有差异（坚果云应用密码、Nextcloud 等），协议实现只依赖
  MKCOL / PROPFIND / GET / PUT 四个方法；
- `play_events` 带同步列与 `syncKey` 唯一索引（列名 camelCase）；
- 播放历史删除（含「清空」）在设备间传播（一致性优先）；刷新上限淘汰不写墓碑；
- 会话同步是「轻量接着听」：非实时、不控制对端；正在播放的设备持续刷新时间戳
  从而抢占，闲置设备的旧会话只会在对端有新活动时被更新；
- 完整备份默认不含凭证（API Key 不落明文文件）；需要携带凭证时使用同步本体
  （快照整体加密）。

---

## v2 修订（2026-10-16）

首版上线后实测暴露两类问题：**性能**（每轮全库 collect + 全量加密传输 + 全库
重放 apply，单轮成本 ∝ 库大小）与**可观察性**（只有 4 个计数器，「没发现对端」
与「没有变化」都显示成「同步成功」；界面日志的「跳过 N 项」其实是全库记录数，
随 `play_events` 无界增长）。另有 N 台设备下的**一致性放大**：墙上时钟的超前
设备会长期压过其它设备、时钟回拨会让本机编辑被静默无视。

本轮修订冻结以下决策，实现拆分为 #26（观测面，已完成）/ #27（平台准入）/
#28（戳模型 v2，已完成）/ #29（成本 ∝ 变更量）/ #30（增量协议与多设备）。
**§1 / §2 覆盖上面「决策」里的戳语义与合并规则**（首版文本保留作历史记录）。

### 1. 协议自始为 v3（2026-10-18 修订）

- **线上只有 v3**：帧 `magic('MSY') + version(1)=3 + nonce(12) | AES-256-GCM`，
  密钥 = `HKDF(PBKDF2(口令), nonce)`；v3 不随帧携带盐与迭代数（帧 nonce 已保证
  (key, nonce) 唯一），小载荷（< 256B）跳过压缩；
- **载荷只有列式二进制**（`SyncPayloadBinary`）：自描述（键名表 + 每列按体积
  择优：varint / 差分 / 字典 / 公共前缀 / 十六进制打包 / JSON 兜底）；
  JSON 载荷只保留给完整备份与测试对照，不是线上格式；
- **只写 v3、只读 v3**：不读旧帧、不做版本闸门 / 协商 / 降级（项目处于快速
  演进期，"没有老设备存在"是显式前提）；版本字节不匹配、载荷结构非法一律
  明确失败（`SyncCryptoException`），不静默跳过；
- **派生状态可随版本重建**：`sync_journal` / `sync_known` 与各对端游标是
  可再生状态，允许在版本升级时清空重建；但重建必须配**管线重置语义**——
  对端游标超前本机日志头部时 `serveJournal` 回全量快照、接收侧全量快照把
  游标落在快照覆盖位置（取最大会让游标悬空，之后 seq 更小的变更被永久跳过）；
- 表结构直接改（fresh 基线；结构变更 = 写增量迁移，见 ADR-0005）；
- **完整备份只做结构性校验**：`importBackupJson` 拒绝「不是 Molia 备份 / 内层
  envelope 结构无效」的文件（`FormatException`），不按协议版本判定；
- 后果：跨设备以当前版本为唯一口径——**所有设备需一次性升级到含 v3 的构建**，
  不支持混合版本共存（如需，须先补能力协商与降级规则）。

  > **2026-10-18 成本评估（不做项）**：v3 落地后复核了两项曾被列入候选的优化，
  > 结论都是「收益不抵迁移成本」，记录在此避免重复评估：
  > - **journal 改存二进制 blob**（`sync_journal.data` TEXT → BLOB + schema v5）：
  >   单条记录按行二进制化只比 JSON 文本小 ~12%（键名与转义占的比重远小于
  >   先前估计，字典 / 列式收益只存在于跨行的快照载荷），`_buildDelta` 的
  >   `jsonDecode` 也随增量窗口缩小到可忽略；不值得为它做一次 schema 迁移。
  > - **本地 payload 去重**（`play_events` 逐条复制元数据 + 载荷）：**已实现**，
  >   最终形态是 v5 的**内容表 `play_tracks`**（每曲一行：元数据 + gzip 载荷）
  >   ＋ 载荷字节预算——事件表只留事件字段 + `trackId`，读取 join 补齐，同步记录
  >   仍逐条自包含（导出侧解码），**线上格式不变、不需要设备同时升级**。
  >   实测 20k 事件（保留上限，1781 首不同曲目）走真实仓库写入 + VACUUM：
  >   18.17 → **4.13 MB**（内置平台载荷 ~700 B/条，−77%）、97.41 → **6.44 MB**
  >   （LX 原样透传平台对象 ~3.6 KB/条，−93%；其中 gzip 载荷列 2.40 MB）。
  >   附带收益：统计同步导出缓存（`_exportRows`）不再逐行持有载荷。
  >   语义变化（有意）：曲目元数据是「**最近一次播放时的快照**」，不再逐事件
  >   快照（同一首被改名后，旧明细跟着显示新名字）；载荷按「最近播放」保留
  >   一份预算，超出清 `raw`（点播回退重新解析），历史 / 计数 / 明细不受影响。
  >   未做：逐行 gzip（相对内容表的收益只剩载荷列本身的 ~56%/39%，且要再多一次
  >   迁移 → 已由内容表方案覆盖）。

### 2. 戳模型：HLC-lite + 内容时间分离

- 记录版本键 = `(versionPhysical, versionCounter, deviceId)`：
  `versionPhysical = max(本地物理时间, 已观测最大值)`（吸收远端超前戳），
  同毫秒 / 时钟回拨用 `versionCounter` 递增，相等再按 `deviceId` 字典序决平局；
- 唯一发号器 `SyncStampIssuer`（新增 `lib/data/sync/sync_stamp.dart`）：
  `next()` / `observe()` / `seed()`；基线持久化在 `sync_state_v1` 的 `stampSeq`
  （每次取号 / 吸收同步更新内存，状态存储的常规保存点落盘）；
- **初始化 = `max(持久化基线, 当前时钟, 全库最大戳)`**：状态存储的 `init()`
  先按持久化基线 + 时钟恢复，组合根在仓库就绪后用
  `LibraryRepository.maxVersion()`（`MoliaDatabase.maxSyncVersion()` 扫五张表）
  `seed()` 补入库内最大值——进程被杀 / 时钟回拨后重启，新写入也不会输给
  库内已有记录；
- **吸收发生在合并之外**：一轮里拉到的全部远端记录（含未获胜者）与导入备份的
  记录都 `observe()`；超前戳记 `Logger('molia.sync')` warning，名册显示对端
  时钟偏移（`clockSkewMs`）供自查；
- **内容时间与版本戳分离**：`history.playedAt` / `statistics.endedAt` /
  `session.savedAt` / `scripts.importedAt` 是内容语义，**不参与跨设备胜负判定**
  （进 `data`）；历史「删除 vs 播放」用 `data` 内的真实删除时间比较
  （墓碑存 `deletedAt`），墓碑保留期也按真实删除时间算（版本分量可能被超前戳
  抬到未来，用它算保留期会让墓碑永不淘汰）；
- **本地存储**（drift，fresh 基线）：列表 / 曲目 / 历史 /
  统计事件的行都带版本三列（`versionPhysical` + `versionCounter` + `deviceId`，
  统计事件复用 `originDeviceId` 作设备列）；`sync_tombstones` = 版本三列 +
  真实删除时间 `deletedAt`。适配器各自负责「什么时候取新号」：设置键用登记
  哈希、脚本用内容哈希、会话用 `savedAt` 哈希、历史/列表行在本地写入时取号；
  应用远端记录时沿用远端的版本（幂等，不制造新的本地变更）；
- 效果：抗时钟回拨（不会自伤）、抗超前（超前戳被全组吸收，下一次任何设备的
  写入必胜）、同毫秒不撞车；名册显示对端时钟偏移供自查；
- 明确不做版本向量 / 因果冲突检测：LWW 不需要，2~4 台个人设备收益不足。

  > **2026-10-17 实现登记**：`SyncRecord.updatedAt/updatedBy` 已改为版本三元组
  > `version`（`SyncVersion`）；设置/脚本/会话的登记项（`SyncStamp`）同样只存
  > 版本。墓碑历史删除 vs 播放的判定落在 `LibraryRepository.syncApplyHistory`：
  > `playedAt <= deletedAt` → 删除生效；`playedAt > deletedAt` → 复活并撤墓碑。
  > 已知残余：晚于删除的播放若其版本仍小于墓碑版本（未同步过就播放的设备），
  > 只在本地复活、不会把删除顶回全组（与首版同级，见「后果」）。
  >
  > 两处「必要扩大」的说明：①版本列落到了 **4 张行表**（`playlists` /
  > `playlist_tracks` / `play_history` / `play_events`，issue 只点名
  > `sync_tombstones`）——内容时间要退出胜负判定，行级版本就必须落库且跨轮
  > 稳定，只在墓碑表加列做不到；②统计的 `closeStaleEvents` 对整批遗留事件取
  > **一个**版本戳（各行 `syncKey` 不同，LWW 只在同键间比较，同批同戳无害）。

### 3. 移动端平台准入与发现

- **Android 17 / API 37（本项目 targetSdk 37）**：局域网访问默认阻断，必须声明
  并在建立 socket 前运行时申请 `ACCESS_LOCAL_NETWORK`（Android 自有 MethodChannel，
  见 `LocalNetworkPermission`），否则 Dart socket 直接抛 `SocketException`。
  **申请时机只跟用户动作走**：打开局域网开关或点「去授权」时
  `ensure(retry: true)` 先复查再申请；被拒则开关回到关闭，底栏 + 开关下常驻
  警告行（与桌面歌词未授权提示同款）引导再次授权 / 去系统设置。启动与每轮
  同步只 `refresh()` 查询状态，不自动弹窗；授权后启动传输并重扫附近设备；
- **关键区分**：权限被拒时「手动填对端地址」也无效（官方明确对外 TCP / 收发
  UDP 单播·组播·广播均需该权限）——权限被拒只引导授权或转 WebDAV；
  **发现失败**（AP 隔离 / 多网段 / 防火墙 / VPN）才用手动对端地址簿；
- **iOS 保留广播发现** → 申请 `com.apple.developer.networking.multicast`
  （模拟器无需该 entitlement，**真机才需要**，模拟器不作为验收证据）；
  未获批时降级到手动地址 / WebDAV；
- 手动对端地址簿：`{host, probePort(默认 47825), httpPort(首次接触学到),
  deviceId(首次接触认领), name}`；本机 HTTP 端口**持久化**（否则对端记不住本机）；
  手动条目与广播发现合并进同一名册；
- 传输启动失败与未配置必须显式可见（`unavailableReason`），
  不许「开关显示已打开而实际没有监听」。
- **探测端口优先固定、失败降级**：UDP 绑定先试标准端口（`47825`），失败
  （Windows 宿主保留端口块 errno 10013 / 端口被占用）改绑系统分配端口，并把
  实际端口随探测包自报（`udpPort`）——端口降级后广播 / 组播到不了它，对端
  只能按自报端口单播。**HTTP 端点起不来才算 `start_failed`**；UDP 不可用只让
  发现降级（`probe_port_unavailable`），手动地址的 HTTP 直连与 WebDAV 照常。
- **双栈探测**：IPv4 `255.255.255.255` 广播 + IPv6 组播 `ff02::4d4f:4c49`
  （同一端口上 v4 / v6 两个 socket，任一族绑定或加入组播失败只降级该族）；
  IPv6 组播的源地址必然是 link-local、不能用于 HTTP，因此探测与应答都携带
  `addrs`（本机可路由候选地址：IPv4 + 全局 / ULA IPv6，排除回环与 link-local，
  上限 8 条），对端连接按**候选地址优先、观测源地址兜底**的顺序尝试；收到
  非回复探测也把发送方登记为对端（主动探测方也在线，不必等它应答）。
  > **2026-10-23 v4 修订（历史标注）**：本段描述的首屏配对卡片 / 配对码 /
  > 二维码 / 扫码入口已整体删除，仅作历史记录；现行口径见文末「v4 修订」。

- **设置页口径修订（配对闭环一页）**：首版「首屏信息预算 ≤ 9 行、明细下沉
  子页」在实测配对流程里制造了来回跳页——用户在本机看不到自己的地址 / 端口，
  在「设备」子页看不到自己的口令，配对只能靠手抄设备 id 与端点端口。现在
  同步设置页一页闭环：开关与五态结论 / 本机（设备名、设备 id、口令、可路由
  地址列表、探测端口与直连端点端口、分享配对信息）/ 设备（名册内联 + 未认领
  候选折叠 + 添加设备）/ 传输 / 同步内容与日志入口；子页只留「同步内容」与
  「同步日志」两个明细面。**配对码**
  `molia-pair:1:<base64url(json)>`（设备名 / 设备 id / 口令 / 地址候选 +
  探测端口 / HTTP 端点端口，探测端口按候选地址的族取）可复制、可出二维码、
  移动端可扫；未认领的候选地址在名册里折叠为一行「候选地址 N 个」（N>1 才
  折叠，单个直列更可读）；口令随码传递是
  信任模型（口令即信任根）的自然延伸，UI 明示「等同授权」而不另设确认门槛。

  > **2026-10-18 修订（取代上段的「开关与五态结论」口径）**：取消同步总开关，
  > **传输开关就是总闸**——`enabled` 改为 `enabledTransports` 非空的派生值
  > （不再独立持久化），任一传输开启即启用同步，两路都关 = 引擎轮次 / 入站
  > 接收 / 调度器一并停摆。传输方式（局域网 / WebDAV，含权限动作与 WebDAV
  > 配置入口）回到首屏并置顶，最近一轮五态结论作为卡片脚注；高级子页只留
  > 设备名 / 设备 id / 口令 / 地址与端口 / 地址簿。口令改为**初始化即生成**
  > （设备身份不依赖开关，配对码任何时刻都可分享），首次开启同步仍不弹窗。
  > 两路传输默认关：装机不启动监听、不广播、不弹局域网权限（`ensure` 首次
  > 会弹系统对话框，只能由用户开开关触发）。旧状态里 `enabled=false`（从未
  > 开启过同步）迁移为 transports 清空，老用户升级后同步保持关闭。

  > **2026-10-18 修订（加入设备收敛为「粘贴 / 扫码」）**：添加设备不再有输入
  > 弹层——首屏配对卡片给两条动作（**粘贴配对码**读剪贴板即导入、**扫码**按
  > Android/iOS × GMS 可用性出现），共用 `importSyncPairingText`：口令随码
  > 传递（冲突才弹一次「替换 / 仅导入地址」）、地址按码收敛、结果用底栏提示
  > 分级反馈（`NotificationService` → M3ESnackbar）；**手填地址下沉到高级设置
  > 子页的「手动连接」**，「输入已有口令加入」入口删除（口令只随配对码传递）。
  > **地址以 deviceId 关联、以码为权威集合**：导入时同一设备的码外旧地址退役
  > （命名迁移、双栈 / 多网卡候选全保留）——内网 IP 变动后重新粘贴配对码即完成
  > 换地址；设备详情里可逐条更新（保留身份与已学端口）或删除。**首次连通双方
  > 各弹一次底栏提示**（首次真正交换数据；`notifiedPeers` 持久化，重启不重发）。

  > **2026-10-19 修订（设备身份与移除语义）**：`deviceId` 独立持久化在
  > `sync_device_id_v1`（prefs 小键 + 安全存储备份），`sync_state_v1` 损坏时
  > 恢复旧身份而不是重新生成——否则手机被系统杀掉 / 换 IP 后会被对端当成
  > 一台新设备。设备名册的「移除设备」只清本机名册与该设备的地址簿条目，
  > **不写屏蔽标记、不撤销同步授权**；对方仍持有口令并在线时，下一轮探测会
  > 重新发现它。真正停止与某台设备同步只有更换口令（对所有设备生效），
  > 因此不再提供「本地忽略」这一伪撤销机制。

### 4. 触发策略与省电（移动端）

- `SyncScheduler` 同步等级：**活跃**（界面可见 / 正在播放，变更去抖 3–5s，
  只探测或拉变化对端）/ **空闲**（退避 10→20→40→60 分钟封顶）/
  **后台**（零定时唤醒，`onPause` 尽力推一次、`onResume` 拉一次）/
  **省电**（低电量或系统省电模式：暂停自动，仅手点）/ **充电 + Wi-Fi**
  （允许 anti-entropy 全量校验）；
- 与省流模式联动：蜂窝下默认只同步小类别或暂停（用户可选）；
- **不承诺移动端后台常驻同步**：后台定时在 Doze / 挂起下不可靠，
  产品语义是「前台与充电时收敛」。

  > **2026-10-17 实现登记**：`SyncScheduler`（`lib/data/sync/sync_scheduler.dart`）
  > 是唯一的触发策略对象，注入 clock / 蜂窝探针 / 电量探针 / 播放状态；
  > 组合根只接线（数据变更 → `notifyLocalChange`，生命周期 → `onAppVisible` /
  > `onAppHidden`，手动 → `syncNow`），没有散落的定时器。具体取值：
  > 活跃去抖 4s、交互窗口 1 分钟（窗口过后自动降级为空闲）；空闲退避
  > 10 分钟起步翻倍封顶 60 分钟；**空闲唤醒的「无本地变更零流量」只适用于
  > 蜂窝网络**——非蜂窝（Wi-Fi / 以太网 / 桌面）的唤醒照常探测与拉取，
  > 对端变化在退避周期内收敛（最长 60 分钟一轮，回前台 / 手点更快）；
  > 省电 = 系统省电模式或电量 ≤ 20% 且未充电（**电量未知 = 桌面无电池，
  > 按外部供电等价处理**，不触发省电等级）；蜂窝「小类别」= 设置 / 音源 /
  > 凭证 / 歌单与曲目 / 会话（统计 / 历史 / 自定义封面留到 Wi-Fi），策略值
  > `SyncCellularPolicy.auto | pause` 持久化在 `sync_state_v1`，同步页可切换；
  > 待外发标记按类别维护，蜂窝小类别轮只清已外发类别（切回 Wi-Fi 补推），
  > 失败轮整体保留。
  > 电量经平台通道读取（Android `BatteryChannelHandler`、iOS `AppDelegate`；
  > 桌面未实现按「未知」处理）——`battery_plus` 与 `connectivity_plus` 的
  > dbus 约束互斥（upower ^0.7 vs nm ^0.8），依赖解析不可行。

### 5. 多设备（N≥3）

- **入站合流**：多个对端的推送在 1–2s 窗口内合并成一轮（否则一次本地变更在
  N 台间放大成 O(N²) 轮完整合并）；入站轮只消费收到的快照，不主动拉取对端；
- **对端变化感知**：局域网探测应答携带 `snapshotId`、WebDAV 用
  `getetag/getlastmodified`，未变不拉；
- **滞后设备策略**：增量日志按 `min(对端 ack)` 裁剪但设硬上限（时间 + 体积），
  超限对端走 bootstrap 全量；失联设备（如 180 天无更新）在名册标记并支持
  「从本机移除」与显式清理远端文件（不自动删除）；
- **anti-entropy**：周期性比对 `snapshotId`，不一致才全量兜底（LWW 只保证
  「有新数据时收敛」，不保证发现静默分歧）。

  > **2026-10-17 实现登记**：合流窗口 1.5s（`SyncEngine.inboundWindow`），
  > 入站轮不拉取也不推送；`snapshotId` 是外发记录集（裁剪墓碑后）的规范化
  > 哈希，随快照 JSON 的 `snapshotId` 字段与 UDP 探测应答携带，进程内按
  > `deviceId` 缓存上次拉到的值；WebDAV 的版本令牌进程内按文件名缓存。
  >
  > **增量协议（#30）**：传输单元 = 变更。`sync_journal`（drift 表，v3 迁移）
  > 按 `seq` 单调追加，**与数据写入同事务**（资料库 / 统计在 drift 事务内，
  > 设置 / 脚本 / 会话在各自的变化检测点；应用远端记录不追加——变更由来源
  > 设备广播，不做二次转发）；`sync_journal_state` 单行记录窗口起点
  > `baseSeq` 与已构建快照覆盖 `snapshotSeq`。载荷两种形态共用 `SyncEnvelope`：
  > 全量快照（`journal == null`，引导 / anti-entropy / 备份）与增量窗口
  > （`journal != null`，只带变更）；对端游标（`cursorSeq`）只应用
  > `seq > 游标` 的条目，游标小于发送方 `baseSeq`（条目已被裁剪）时改取
  > bootstrap 全量快照，`journalHead` 推进游标。ack 回执（`acks`）随载荷外发：
  > 对端据此按 `min(对端 ack)` 裁剪日志。compact 的硬上限 = 30 天 / 4 MiB /
  > 5000 条，超限时把快照覆盖推进到头部、保留最新的仍在上限内的条目，
  > 更旧的对端降级 bootstrap；失联设备（180 天无接触）不参与 minAck。
  > **发布台账（每传输一份，`publish_ledger.dart`）**：「跳过加密 / 上传」与
  > 「窗口能裁到哪」的判据只有这一处——内存指纹（成功外发过的载荷身份：快照
  > 按内容指纹、增量按窗口边界 + ack 集合）、`sync_state_v1` 的
  > `snapshotPushSeq` 持久覆盖与 `servesLiveSnapshot` 能力位；compact 的
  > 覆盖下限由 `journalCoverage` 推导（按需给实时快照的传输不约束），成功才
  > 记账（零对端与失败不记、下轮重发），push 循环只问 `plan` / 记 `mark`。
  > 传输：局域网 `GET/POST /molia-sync/v1/journal?since=`（游标落后即回全量
  > 快照），WebDAV `<deviceId>.journal.msync`（每次变更重写）+
  > `<deviceId>.snapshot.msync`（按需重写）；非本协议文件名与载荷身份不符的
  > 幽灵文件不参与合并。anti-entropy：非蜂窝 + 未省电 +（充电或前台）的轮次
  > 比对 `snapshotId`（按双方共享类别、同一裁剪口径），不一致时取全量快照
  > 兜底（同一对端 10 分钟节流）；主动请求的全量快照绕过「登记未变不交付」，
  > 修复被篡改 / 直接改库的静默分歧。名册新增 `cursorSeq` / `ackedSeq` /
  > `headSeq` / `behindBy` / `behindBytes` / 失联标记，处置动作 = 从本机移除
  > 名册与地址簿条目（不撤销授权）与显式清理远端文件（DELETE，无自动删除）。

### 6. 观测面（已完成，见 #26）

- 一轮的产物是 `SyncRoundReport`：五态 `ok / noChanges / noPeers / partial /
  failed` + 每传输明细 + 每对端名册 + **本轮变更量**（不随库大小增长）；
- 日志语义 = 本轮变更；「跳过 N 项」删除；
- 失败行必须给下一步动作；不提供「立即同步」主操作与诊断导出，运行状态在
  日志子页可查（无密钥）。

  > **2026-10-17 实现登记**：同步页「运行状态」行展示近 24 小时触发轮数 /
  > 有效传输轮数（有字节流转或有落地）/ 流量，以及当前同步等级 · 网络类型 ·
  > 是否省电（`SyncActivitySummary` + `SyncScheduler` 观测值）；窗口基于状态
  > 存储保留的最近日志条目。每传输明细新增 `skippedUnchanged`（未变跳过数）。

### 后果（v2）

- 「永远赢」的设备消失，但吸收机制意味着**一次超前戳会抬高全组基线**：
  本机写出的版本可能大于自己的墙上时钟（单向，只影响时间显示类 UI（若有），
  不影响正确性）；
- 历史删除的「删除 vs 播放」按真实时间为准，时钟大幅超前的删除会压制随后的
  播放；晚于删除但版本更小的播放只在本机复活、不把删除顶回全组；
- 移动端后台不收敛是**设计承诺**，不是缺陷；
- 空闲期的收敛节奏取决于网络类型：蜂窝下无本地变更不发轮次（省电与省流），
  非蜂窝下按退避周期探测（最长 60 分钟一轮）——对端变化在空闲期的可见延迟
  由此决定，回前台 / 手点更快；
- 增量协议落地后，`play_events` 不再参与每轮快照（#30：日志 + 游标根治）；
  anti-entropy 的全量兜底只在充电 / Wi-Fi / 前台且指纹不一致时发生（同一
  对端 10 分钟节流），WebDAV 的全量快照文件按需重写（首次引导 / 日志超硬
  上限），日常轮次只上传增量窗口；
- 日志窗口的硬上限（30 天 / 4 MiB / 5000 条）之外的对端要重新引导：
  超限设备收到的是全量快照而不是增量，代价可接受（个人设备场景）；
- 失联设备（180 天无接触）在名册标记，处置动作由用户显式选择（从本机移除 /
  清理远端文件），本机不自动删除任何远端内容。

---

## v3 修订（2026-10-21）：发现 D1 硬断代 + 事件驱动重连

> 本节取代前文与「局域网探测 / 旧状态迁移 / 协议兼容」相关的口径；更早的文本
> 保留作历史记录。载荷帧 `MSY/3` 的结构不变，变的是发现、命名空间与触发链。

### 1. 前提：内部迭代期不做兼容

项目仍处于内部快速迭代，**显式不兼容任何历史数据与协议**：旧 JSON 探测包、
旧状态 / 旧口令、旧配对码、旧局域网 HTTP 路径、旧 WebDAV 文件一律当从未存在，
不写迁移、识别或双协议分支。代价（升级后要重新开启同步并配对、首轮全量
bootstrap）小于维护两套协议的成本，也避免「旧数据被误当成新协议」的静默错乱。

### 2. 命名空间切割

| 层 | 旧（作废） | 新 |
|---|---|---|
| 同步状态 | `sync_state_v1` | `sync_state_v2` |
| 设备身份 | `sync_device_id_v1` | `sync_device_id_v2` |
| 同步口令 | `sync_passphrase_v1` | `sync_passphrase_v2` |
| WebDAV 密码 | `sync_webdav_password_v1` | `sync_webdav_password_v2` |
| 局域网发现 | JSON `molia-sync.probe` | 二进制 `MSD` + version 1 + HMAC |
| 局域网 HTTP | `/molia-sync/v1/*` | `/molia-sync/v2/*` |
| WebDAV 文件 | `<deviceId>*.msync` | `<deviceId>.p2.*.msync` |
| 配对码（v4 已删除） | `molia-pair:1:` | `molia-pair:2:`（历史） |
| 载荷帧 | `MSY`/3 | `MSY`/3 不变 |

- 新 key 缺失 = 全新安装行为：新设备 id、新口令、传输开关关闭；旧 key
  不读、不删、不迁移。
- 首次使用新 key 初始化（`sync_state_v2` 缺失或持久标记
  `sync_derived_reset_v2` 未置位）时清空派生状态：`sync_journal` /
  `sync_journal_state` / `sync_known`。只有 journal 与 known 都 reset 成功
  才写持久标记，进程中途被杀会在下次启动重试。
- **不动**用户数据：`playlists` / `playlist_tracks` / `play_history` /
  `play_events` / `sync_tombstones` 与版本三列都保留；派生状态只是索引。
- 旧配对码 `molia-pair:1:` 解析失败（按无效码处理）；旧 HTTP 路径 404；
  （v4 起 `molia-pair:2:` 与整个配对码路径也已删除，文本按普通文本处理。）
  旧 WebDAV 文件名不被 `PeerJournalNames.parse` 识别（幽灵文件，不读不删）。

### 3. 发现协议 `MSD/1`

```
magic(3)='MSD' | version(1)=1 | type(1) | mac(16) | bodyLen(2, big-endian) | body(UTF-8 JSON, ≤1024B)
type: 1=announce, 2=ack
```

body：`id` / `name` / `http` / `probe` / `addrs` / `snap` / `head` / `cats` /
`nonce` / `boot`（`name` ≤64 码点、`addrs` ≤8 条；超限按地址 → 分类 →
指纹 → 名称逐级截断，保证单包不触发 IP 分片）。

- `mac = HMAC-SHA256(discoveryKey, header_without_mac + body)[0..16]`；长度字段
  参与认证，篡改 bodyLen 直接失败。
- `discoveryKey = HKDF(PBKDF2(口令), info='molia-sync-discovery-v1', 32B)`：
  与载荷帧密钥分离，绝不复用帧的 (key, nonce) 空间；根密钥复用 `SyncCodec`
  的会话缓存，因此每包验 MAC 不需要重复 PBKDF2。
- **认证顺序是硬约束**：先按来源 IP 限流 → 验 MAC → 再解析 JSON。任何失败
  （magic / 版本 / 类型 / 长度 / MAC / JSON / 字段）一律返回 null，调用方
  按未知字节静默丢弃；旧 JSON 包首字节是 `{`，连日志都不记。
- 重放抑制：同一 burst 复用 nonce，接收端按 `(deviceId, nonce)` 30 秒去重；
  广播 + 组播重复到达只产生一次 sighting。
- `boot` 每次进程启动随机生成：对端重启后即使 `head` 未变也视为重新上线。
- 入站限流：每来源 20 包/10s、全局 100 包/10s；来源记账表有界（64 个来源，
  淘汰最久未活动的）。presence 上限 32 台，超出淘汰最久没听到的。
- announce 发送目标：v4 广播 `255.255.255.255` + v4 组播 `224.0.0.169` +
  v6 组播 `ff02::4d4f:4c49` + ≤8 个已知端点单播；`ack` 只向来源地址 / 端口
  单播。公告 burst 在启动 / 回前台 / 换网时按 `100 / 500 / 2000ms` 发三次；
  本地变更但本轮零推送时单次定向公告；其余时间不公告、不心跳。

### 4. UDP 只发现，HTTP 是数据与存活通道

- UDP 公告只携带身份、端点端口、`snap` / `head` / 类别与在线信号，**不传
  同步数据**。数据只走每设备内置 HTTP：`GET/POST /molia-sync/v2/journal`
  （增量窗口，游标落后回全量）与 `GET/POST /molia-sync/v2/snapshot`（全量
  快照 / bootstrap）。HTTP 层不做额外鉴权：载荷是密文，能通过 MAC + 解密
  的设备即已授权。
- 「收到公告」不等于「HTTP 可用」：公告只让本机把该设备列入候选，真正可达
  以 HTTP 请求 + 解密成功为准；反过来 UDP 绑定失败只降级发现，已知端点 /
  手动地址的 HTTP 直连照常（`probe_port_unavailable`，不是 `start_failed`）。
- 候选 = 手动地址簿 + 本轮 presence + `lanEndpoints`；正常轮只对候选做
  ≤8 个单播并等 400ms，全部 HTTP 失败才补一次广播（800ms），不无限重试。
  单对端最多试 3 个地址、总预算 4s。

### 5. 事件驱动重连链

- **换网**：`connectivity_plus` 原始事件 → `DataSaverService.networkEvents`
  → `SyncScheduler.onNetworkChanged()`：`refreshEnvironment` → 空闲退避重置
  → 1.5s 去抖 → `SyncTrigger.network`（强制广播发现）。蜂窝 / 后台 / 省电
  不排轮次。发现层收到 connectivity 事件**无条件重绑 UDP**（Wi-Fi 重连可能
  IP 不变但旧 socket 已死），只有接口指纹变化时才清 presence / nonce。
- **回前台**：隐藏 ≥15s 时 `LanSyncTransport.onAppResumed()` 先做 HTTP
  loopback 探活（500ms，连不上先重绑同端口、再退随机端口并持久化），再重绑
  UDP 并发公告 burst；随后调度器跑 `SyncTrigger.resume`。HTTP 重绑失败把
  传输置为 `start_failed`（UI 可见），下一轮 `start` 可重新绑定。隐藏不足
  15s 只刷新地址与公告，不重绑。
- **零对端阶梯**：启动 / 回前台 / 换网后「已配对但本轮零对端」按
  `5s / 20s / 60s / 180s` 四档重连，任一档 LAN 接触成功（`peersSeen > 0`）
  立即取消；仅前台、非省电、非蜂窝、LAN 已启用且存在已知端点 / 手动地址时
  arm；退后台 / 省电取消。
- **对端公告唤醒**：认证通过的 sighting 经引擎过滤——新设备 / `boot` 变化 /
  `snap` 变化 / `head` 前进且仍高于本机游标才通知（同一设备 2 分钟无变化不
  重复触发；最多 64 台观测状态）。调度器 1s 去抖 + 10s 冷却后跑
  `SyncTrigger.discovery`；冷却未到延后到窗口结束，不并排两轮。公告观测
  不写名册 `lastSeenAt`，避免「只是听见」被当成「接触成功」。

### 6. `lanEndpoints`：已验证端点

- `SyncStateStore.lanEndpoints`：`deviceId → LanPeerEndpoint{host, httpPort,
  probePort, verifiedAt}`；`host` 只存可路由 IP 字面量（回环 / link-local /
  zone 一律拒绝），`verifiedAt <= 0` 的条目不能入表（否则永远命中不了淘汰）。
- **只在 MAC 验证通过 + HTTP 解密成功后回写**（`onPeerVerified` →
  `rememberLanEndpoint`）；UDP 听见但 HTTP 解不开、口令不同的对端都不写。
  端点上的 deviceId 可能与解密后的数据主人不同（DHCP 复用 / 旧记录），此时
  以解密载荷的 `deviceId` 为准，不把端点记到旧 id 名下。
- 端点更新（含仅 `verifiedAt` 前进）只改内存并标脏，随引擎轮末的 `commit()`
  持久化，不在每对端成功时各写一次整份状态。上限 32 条，超出按 `verifiedAt`
  淘汰最旧；
  `removePeer` 同时清理该设备的端点；180 天未再验证的端点随名册淘汰。
- **预期对端 vs 试探性对端**：手动地址与「本轮听到的 presence」是预期对端，
  失败要计数、可把整轮打成 `partial`；只有持久化端点的是试探性对端，连不上
  是常态（换网 / 关机），失败不计数、不让整轮变 partial。

### 7. 节电预算

| 场景 | 行为 |
|---|---|
| 正常活跃 / 空闲轮（有候选） | ≤8 个单播探测 + HTTP，等 400ms，0 广播 |
| 冷启动 / 回前台 / 换网 | 3 次公告 ×（v4 广播 + v4/v6 组播 + ≤8 单播），等 1.2s |
| 已配对但全不可达 | 每轮补一次广播探测 + 800ms，阶梯最多 4 档 |
| 单对端 HTTP | 最多 3 个地址 / 总预算 4s |
| 蜂窝 | 0 广播 / 组播；只对已知端点直连 HTTP；不排网络 / 公告 / 阶梯定时器 |
| 后台 / 省电 | 0 定时器、0 公告、不主动探测 |
| 入站 | 每来源 20 包/10s、全局 100 包/10s；presence 32 台 |

### 后果（v3）

- **升级后同步是「未配置」**：旧 key 不读，传输开关为空、设备 id 与口令都是
  新的——需要重新开启同步并重新配对；旧设备名册 / 日志也不可见。
- **首轮全量 bootstrap**：新命名空间首次初始化清空 journal / known，各对端
  第一次接触只能收全量快照；用户数据（歌单 / 历史 / 统计）不丢，两端合并后
  一致。
- **不支持混版本**：旧客户端发出的 JSON 公告被静默丢弃、旧 HTTP 路径 404、
  旧配对码不再有解析器（v4 起按普通文本处理）——新旧版本不会互相发现，
  也不会误同步。
- **旧 WebDAV 文件是幽灵文件**：旧命名空间的文件不出现在列表、不被读取、
  不被 `deleteRemote` 删除；云端会一直留着，需要时由用户自己清理。
- 广播被 AP 隔离 / iOS 无 multicast entitlement 时，已同步过的设备靠
  `lanEndpoints` 单播兜底；从未配对过的设备仍需手动地址或 WebDAV。

### 已知限制

1. **发现没有按网卡绑定 socket**：`LanDiscovery` 用 v4 / v6 两个 wildcard
   `RawDatagramSocket` 发包，广播与组播的出口由系统路由表决定，没有像
   LocalSend 那样为每个接口绑定 socket，也没有固定 `multicastInterface`。
   多网卡 / 全隧道 VPN / WSL 等场景下，广播可能只走默认接口（或直接被
   VPN 黑洞），首次发现因而失败。当前兜底是「v4 广播 + v4/v6 组播 +
   `lanEndpoints` 单播 + 附近设备一键配对 / 手动地址」；已同步过的设备
   可靠单播收敛，未配对设备用附近设备探测或手动地址（v4 起配对码已删除）。
   若将来要按接口发现，
   得为每个接口绑定独立 socket，或在加入组播 / 发送前切换
   `multicastInterface`，并处理接口上下线。
2. **探测端口降级后广播到不了它**：标准端口 47825 绑定失败（Windows 宿主
   保留端口块 / 端口被占用）时 UDP 会改绑系统分配端口（见已知坑 46），而
   广播 / 组播仍发往固定的 47825——该设备收不到无目标广播。此时只能靠
   手动地址（可指定实际发现端口）/ 附近设备单播探测 / 已学到的端点单播
   （v4 起配对码已删除）。这是既有约束，不是本次发现改造引入的回归；
   HTTP 端点与数据通道不受影响。
3. **移动端后台仍不承诺收敛**：Doze / 挂起下定时器与 socket 都不可靠，
   后台不发公告、不排重连阶梯；回到前台才重绑 UDP、探活 HTTP 并补一轮。
   产品语义仍是「前台与充电时收敛」，不引入前台服务 / wake lock。


---

## v4 修订（2026-10-23）：删除配对码，收敛为一键附近配对

> 本节取代前文所有配对码 / 二维码 / 粘贴 / 扫码描述。旧的
> `molia-pair:*` 文本、二维码、剪贴板导入与相机权限全部删除：**不识别、
> 不迁移、不保留兼容分支**；旧文本按普通文本处理。已配对的设备不受影响，
> 继续使用 `MSD/1` 发现与 `MSY/3` 载荷协议，不需要重新配对。

### 1. 单一路径

- **发现**：`MSP/1`（`lib/data/sync/transport/lan_pairing_packet.dart`）复用
  现有 UDP 端口，独立 magic `MSP` + version 1 + type（1 = probe，2 = announce）
  + bodyLen + JSON，**无 MAC**；body ≤512B（`id` / `name` / `http` / `probe` /
  `addrs` / `group` / `boot` / `nonce`）。只做候选发现：不写名册
  `lastSeenAt`、不写 presence、不触发同步轮次；候选按 deviceId 去重、15 秒
  TTL、上限 32，每来源 10 包/10s、全局 50 包/10s。只在局域网传输运行、
  App 前台、非蜂窝时响应 probe；同步页打开时按 100 / 500 / 1500ms 发 probe。
- **请求**：`POST /molia-sync/v2/pair/request`、
  `GET /molia-sync/v2/pair/status?id=…`、`POST /molia-sync/v2/pair/complete`
  （invite 方向），实现在 `lib/data/sync/pairing/lan_pairing_service.dart`。
  JSON body ≤8KB、每来源限流、pending 上限 8、同一时间只允许一个待确认弹窗、
  TTL 60 秒；只在 App 前台可弹窗，后台直接返回不可用。requestId 随机
  128-bit，状态轮询必须带同一个 id。
- **加密**：临时 ECDH（PointyCastle P-256）+ HKDF-SHA256 + AES-256-GCM
  （`lib/data/sync/pairing/pairing_crypto.dart`）；校验公钥在曲线上。AAD 绑定
  requestId / intent / 双方 deviceId，防替换。口令只进安全存储，不进日志、
  错误详情、分析事件；pending 密钥与载荷过期即清。
- **确认码**：6 位数字由双方公钥、nonce、requestId 派生，发起方与接收方显示
  同一个码；用户核对，不一致必须拒绝。
- **同组 / 冲突**：request 带基于 discovery key 的 group proof（HMAC，随机
  requestId），双方口令相同则返回同组、不弹接受窗并直接补端点；双方都有组
  且口令不同则返回 conflict，不传口令、不静默换组。
- **加入 / 邀请方向**：A 无组、B 有组 → B 加密返回口令，A 加入 B 的组；
  A 有组、B 无组 → B 接受后 A 加密发送口令，B 加入 A 的组；双方都无组 →
  B 生成（或使用已有）口令，A 加入。
- **接受 = 加入同步组 = 完全授权**：对方获得本机同步口令，可解密全部同步
  数据（含音源脚本与 API Key 等密钥）；接受弹窗必须明示。模型（
  `lib/domain/models/sync_nearby_pairing.dart`）承载附近设备、请求、尝试与
  join / invite / conflict / same-group 状态；UI 在
  `lib/pages/sync_nearby_pairing_dialogs.dart`。
- **手动地址兜底**：高级设置保留「手动连接」，填 host + 探测端口；未配对时
  向该地址发 `MSP` 单播 probe，收到 announce 后走同一 `/pair/*` 流程；不提供
  口令输入、不提供配对码文本。已有同口令的设备仍沿用现有探测 / 直连逻辑。

### 2. 状态与删除项

- 已配对设备继续走现有 `MSD/1` 发现与 `MSY/3` 载荷；删除的是配对码入口，
  不是已有同步组。
- 删除：`SyncPairingCode` / `SyncPairingAddress`、`sync_pairing_qr.dart`、
  `sync_pairing_scanner.dart`、`qr` / `mobile_scanner` 依赖、Android
  `CAMERA` 权限与 camera feature、iOS `NSCameraUsageDescription`、
  `SyncProvider.pairingCode()` / `importPairingAddresses()`、
  `SyncControlPlane` / `SyncStateStore.adoptPeerAddresses`，以及旧的
  `syncPairing*` 文案与 `PlayServicesChannelHandler`（GMS 门控只服务扫码）。
- `lib/pages/sync_pairing_dialogs.dart` 的配对码部分删除，设备详情 / 地址
  清单 / 手动连接迁到 `lib/pages/sync_peer_dialogs.dart`。

### 后果（v4）

- 升级后不再有任何配对码入口；旧的 `molia-pair:*` 文本、二维码、剪贴板内容
  都不会被识别，也没有「导入失败」提示（按普通文本处理）。
- 未配对设备只能通过附近设备一键配对或手动地址进入；手动地址仍要求两台设备
  网络可达。
- 相机权限、扫码依赖与 GMS 探测通道一并移除；安装包不再包含二维码 / 扫码
  相关原生依赖。
