import 'package:flutter_test/flutter_test.dart';

import 'cached_page_service_cases.dart' as cached_page_service;
import 'discover_provider_cases.dart' as discover_provider;
import 'discover_runner_cases.dart' as discover_runner;
import 'fan_out_search_session_cases.dart' as fan_out_search_session;

void main() {
  group('cached page service', cached_page_service.main);
  group('discover provider', discover_provider.main);
  group('discover runner', discover_runner.main);
  group('fan out search session', fan_out_search_session.main);
}
