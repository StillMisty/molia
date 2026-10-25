import 'package:flutter_test/flutter_test.dart';

import 'ai_settings_store_cases.dart' as ai_settings_store;
import 'auto_source_swap_service_cases.dart' as auto_source_swap_service;
import 'escape_claims_cases.dart' as escape_claims;
import 'notification_cases.dart' as notification;
import 'shortcut_bindings_cases.dart' as shortcut_bindings;

void main() {
  group('ai settings store', ai_settings_store.main);
  group('auto source swap service', auto_source_swap_service.main);
  group('escape claims', escape_claims.main);
  group('notification', notification.main);
  group('shortcut bindings', shortcut_bindings.main);
}
