import 'package:flutter_test/flutter_test.dart';

import 'settings_defaults_cases.dart' as settings_defaults;
import 'settings_registry_cases.dart' as settings_registry;
import 'settings_scope_cases.dart' as settings_scope;

void main() {
  group('settings defaults', settings_defaults.main);
  group('settings registry', settings_registry.main);
  group('settings scope', settings_scope.main);
}
