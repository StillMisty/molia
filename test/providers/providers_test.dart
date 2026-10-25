import 'package:flutter_test/flutter_test.dart';

import 'ai_dj_history_controller_cases.dart' as ai_dj_history_controller;
import 'nav_provider_cases.dart' as nav_provider;
import 'playback_volume_cases.dart' as playback_volume;

void main() {
  group('ai dj history controller', ai_dj_history_controller.main);
  group('nav provider', nav_provider.main);
  group('playback volume', playback_volume.main);
}
