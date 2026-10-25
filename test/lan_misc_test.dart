import 'package:flutter_test/flutter_test.dart';

import 'local_endpoints_service_cases.dart' as local_endpoints_service;
import 'local_network_permission_channel_cases.dart' as local_network_permission_channel;

void main() {
  group('local endpoints service', local_endpoints_service.main);
  group('local network permission channel', local_network_permission_channel.main);
}
