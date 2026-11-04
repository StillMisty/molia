import 'package:flutter_test/flutter_test.dart';

import 'process_liveness_cases.dart' as process_liveness;
import 'single_instance_cases.dart' as single_instance;
import 'tray_settings_cases.dart' as tray_settings;
import 'window_bounds_cases.dart' as window_bounds;
import 'window_settings_cases.dart' as window_settings;

void main() {
  group('process liveness', process_liveness.main);
  group('single instance', single_instance.main);
  group('tray settings', tray_settings.main);
  group('window bounds', window_bounds.main);
  group('window settings', window_settings.main);
}
