import 'package:flutter_test/flutter_test.dart';

import 'peer_journal_protocol_cases.dart' as peer_journal_protocol;
import 'webdav_sync_transport_cases.dart' as webdav_sync_transport;

/// WebDAV 传输与对端日志协议。
///
/// 单独成文件：这些用例走真实 HTTP，不能被同一进程里
/// `TestWidgetsFlutterBinding` 的 HttpOverrides（一律 400）拦截。
void main() {
  group('webdav sync transport', webdav_sync_transport.main);
  group('peer journal protocol', peer_journal_protocol.main);
}
