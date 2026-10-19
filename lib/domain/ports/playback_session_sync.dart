/// 播放会话的跨设备同步端口：只暴露同步适配器真正需要的原始会话读写。
///
/// 为什么是「原始 JSON」而不是 `PlaybackSession`：同步记录的内容就是会话键里
/// 的原始 map（含 `savedAt` 与脚本 payload），远端记录也是同一份 wire format；
/// 在这里转成领域对象会丢字段，也会把同步语义绑死在本地模型上。
///
/// 为什么单独建端口：会话落盘必须只有一个写队列（`PlaybackSessionStore` 的
/// `pendingWrite`）。同步适配器若直接持有 store，就会在组合根里再建一个实例、
/// 形成第二个队列；依赖这个端口后，生产接线只能把「协调者」交给同步栈。
library;

/// 会话同步记录的内容时间键（毫秒时间戳；旧记录缺省按 0 处理）。
///
/// 放在端口而不是 store：data 层的同步适配器只通过端口认识会话，不应该为了
/// 一个键名 import services 层的具体实现。
const String kPlaybackSessionSavedAtKey = 'savedAt';

/// 同步侧对播放会话的最小读写面。
///
/// 实现必须把 [applyRemote] / [clearRemote] 交给同一个会话写队列，保证远端
/// 应用与本地保存 / 清除严格按调用顺序串行，不会互相插队或复活已清除的会话。
abstract interface class PlaybackSessionSyncPort {
  /// 读取原始会话 JSON（含 [kPlaybackSessionSavedAtKey]；无记录或损坏返回 null）。
  Future<Map<String, dynamic>?> loadRaw();

  /// 原样应用远端会话（内容须自包含 `savedAt`）。
  Future<void> applyRemote(Map<String, dynamic> raw);

  /// 应用远端删除：清空本地会话（不触发本地「待外发」标记）。
  Future<void> clearRemote();
}
