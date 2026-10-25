import 'package:flutter_test/flutter_test.dart';

import 'sync_activity_cases.dart' as sync_activity;
import 'sync_activity_log_cases.dart' as sync_activity_log;
import 'sync_notices_cases.dart' as sync_notices;
import 'sync_peer_actions_cases.dart' as sync_peer_actions;
import 'sync_peer_status_cases.dart' as sync_peer_status;
import 'sync_provider_lifecycle_cases.dart' as sync_provider_lifecycle;
import 'sync_script_adapter_cases.dart' as sync_script_adapter;
import 'sync_statistics_adapter_cases.dart' as sync_statistics_adapter;

void main() {
  group('sync activity', sync_activity.main);
  group('sync activity log', sync_activity_log.main);
  group('sync notices', sync_notices.main);
  group('sync peer actions', sync_peer_actions.main);
  group('sync peer status', sync_peer_status.main);
  group('sync provider lifecycle', sync_provider_lifecycle.main);
  group('sync script adapter', sync_script_adapter.main);
  group('sync statistics adapter', sync_statistics_adapter.main);
}
