import 'package:flutter_test/flutter_test.dart';

import 'local_endpoints_service_cases.dart' as local_endpoints_service;
import 'local_network_permission_channel_cases.dart'
    as local_network_permission_channel;

/// 本机地址枚举与局域网权限通道。
///
/// 单独成文件：权限用例会初始化 widget binding（装 HttpOverrides），
/// 与真实 HTTP 传输用例同进程会拦截后者。
void main() {
  group('local endpoints service', local_endpoints_service.main);
  group(
    'local network permission channel',
    local_network_permission_channel.main,
  );
}
