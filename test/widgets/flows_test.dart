import 'package:flutter_test/flutter_test.dart';

import 'onboarding_flow_cases.dart' as widgets_onboarding_flow;
import 'listening_sync_page_cases.dart' as widgets_listening_sync_page;
import 'any_listen_page_cases.dart' as widgets_any_listen_page;
import 'accessibility_journey_cases.dart' as widgets_accessibility_journey;

void main() {
  group('onboarding flow', widgets_onboarding_flow.main);
  group('listening sync page', widgets_listening_sync_page.main);
  group('any listen page', widgets_any_listen_page.main);
  group('accessibility journey', widgets_accessibility_journey.main);
}
