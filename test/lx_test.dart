import 'package:flutter_test/flutter_test.dart';

import 'lx_core_cases.dart' as lx_core;
import 'lx_engine_native_cases.dart' as lx_engine_native;
import 'lx_script_update_cases.dart' as lx_script_update;
import 'lx_supervisor_cases.dart' as lx_supervisor;

void main() {
  group('lx core', lx_core.main);
  group('lx engine native', lx_engine_native.main);
  group('lx script update', lx_script_update.main);
  group('lx supervisor', lx_supervisor.main);
}
