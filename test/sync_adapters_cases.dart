import 'package:flutter_test/flutter_test.dart';

import 'sync_ai_dj_adapter_cases.dart' as sync_ai_dj_adapter;
import 'sync_cover_adapter_cases.dart' as sync_cover_adapter;
import 'sync_history_adapter_cases.dart' as sync_history_adapter;
import 'sync_library_adapter_cases.dart' as sync_library_adapter;
import 'sync_platform_access_cases.dart' as sync_platform_access;
import 'sync_prefs_adapter_cases.dart' as sync_prefs_adapter;
import 'sync_roster_cases.dart' as sync_roster;
import 'sync_session_adapter_cases.dart' as sync_session_adapter;
import 'sync_state_cases.dart' as sync_state;
import 'sync_state_store_cases.dart' as sync_state_store;

void main() {
  group('sync ai dj adapter', sync_ai_dj_adapter.main);
  group('sync cover adapter', sync_cover_adapter.main);
  group('sync history adapter', sync_history_adapter.main);
  group('sync library adapter', sync_library_adapter.main);
  group('sync platform access', sync_platform_access.main);
  group('sync prefs adapter', sync_prefs_adapter.main);
  group('sync roster', sync_roster.main);
  group('sync session adapter', sync_session_adapter.main);
  group('sync state', sync_state.main);
  group('sync state store', sync_state_store.main);
}
