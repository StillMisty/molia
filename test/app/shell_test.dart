import 'package:flutter_test/flutter_test.dart';

import 'adaptive_layout_cases.dart' as app_adaptive_layout;
import 'app_lifecycle_coordinator_cases.dart' as app_app_lifecycle_coordinator;
import 'shell_presentation_cases.dart' as app_shell_presentation;
import 'bootstrap/desktop_stack_cases.dart' as app_bootstrap_desktop_stack;

void main() {
  group('adaptive layout', app_adaptive_layout.main);
  group('app lifecycle coordinator', app_app_lifecycle_coordinator.main);
  group('shell presentation', app_shell_presentation.main);
  group('desktop stack', app_bootstrap_desktop_stack.main);
}
