import 'package:flutter_test/flutter_test.dart';

import 'battery_probe_cases.dart' as services_battery_probe;
import 'single_instance_lock_cases.dart' as services_single_instance_lock;
import 'window/playback_menu_cases.dart' as services_window_playback_menu;
import 'window/process_liveness_cases.dart' as services_window_process_liveness;
import 'memory/app_memory_manager_cases.dart'
    as services_memory_app_memory_manager;

void main() {
  group('battery probe', services_battery_probe.main);
  group('single instance lock', services_single_instance_lock.main);
  group('playback menu', services_window_playback_menu.main);
  group('process liveness', services_window_process_liveness.main);
  group('app memory manager', services_memory_app_memory_manager.main);
}
