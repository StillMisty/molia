import 'package:flutter_test/flutter_test.dart';

import 'ai_settings_store_cases.dart' as ai_settings_store;
import 'auto_source_swap_service_cases.dart' as auto_source_swap_service;
import 'escape_claims_cases.dart' as escape_claims;
import 'global_hotkeys_cases.dart' as global_hotkeys;
import 'key_claims_cases.dart' as key_claims;
import 'notification_cases.dart' as notification;
import 'shortcut_bindings_cases.dart' as shortcut_bindings;
import 'window_bounds_store_cases.dart' as window_bounds_store;

void main() {
  group('ai settings store', ai_settings_store.main);
  group('auto source swap service', auto_source_swap_service.main);
  group('escape claims', escape_claims.main);
  group('global hotkeys', global_hotkeys.main);
  group('key claims', key_claims.main);
  group('notification', notification.main);
  group('shortcut bindings', shortcut_bindings.main);
  group('window bounds store', window_bounds_store.main);
}
