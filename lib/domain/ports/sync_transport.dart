import '../models/device_sync.dart';

/// 同步传输端口：把「本地快照 ↔ 远端快照」的搬运与加密解耦。
///
/// 实现（局域网直连 / WebDAV）负责发现对端、加解密与网络错误容忍；
/// 引擎只消费 [pull] 返回的快照并调用 [push] 发布合并结果。
/// 任何单点失败都不应抛出（返回部分结果或空列表），错误经日志与状态呈现。
abstract interface class SyncTransport {
  /// 传输标识（持久化配置键）：`lan` / `webdav`。
  String get kind;

  /// 启动常驻资源（局域网为 UDP/HTTP 监听；WebDAV 无操作）。
  Future<void> start();

  /// 停止常驻资源。
  Future<void> stop();

  bool get isRunning;

  /// 拉取当前可获得的远端快照（解密失败的对端跳过）。
  Future<List<SyncEnvelope>> pull();

  /// 推送本地快照（对端后续轮次拉取可见）。
  Future<void> push(SyncEnvelope envelope);

  /// 对端主动送来的快照（局域网 POST / WebDAV 无此通道时为广播流）。
  Stream<SyncEnvelope> get incoming;
}
