import 'dart:async';

import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 测试用内存密钥存储（替代 flutter_secure_storage）。
class MemorySyncSecretStore implements SyncSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// 测试用内存传输：可注入远端快照、记录推送内容并提供入站流。
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport({this.kind = 'lan'});

  @override
  final String kind;

  bool _running = false;
  final List<SyncEnvelope> available = [];
  final List<SyncEnvelope> pushed = [];
  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<List<SyncEnvelope>> pull() async => List.of(available);

  @override
  Future<void> push(SyncEnvelope envelope) async {
    pushed.add(envelope);
  }

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;
}
