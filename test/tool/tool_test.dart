import 'package:flutter_test/flutter_test.dart';

import 'apk_size_cases.dart' as tool_apk_size;
import 'data_report_cases.dart' as tool_data_report;
import 'desktop_size_cases.dart' as tool_desktop_size;
import 'perf_report_cases.dart' as tool_perf_report;
import 'platform_cases.dart' as tool_platform;
import '../packaging/linux_desktop_cases.dart' as packaging_linux_desktop;

void main() {
  group('apk size', tool_apk_size.main);
  group('data report', tool_data_report.main);
  group('desktop size', tool_desktop_size.main);
  group('perf report', tool_perf_report.main);
  group('platform', tool_platform.main);
  group('linux desktop', packaging_linux_desktop.main);
}
