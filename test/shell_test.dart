import 'package:flutter_test/flutter_test.dart';

import 'app_shell_progress_cases.dart' as app_shell_progress;
import 'shell_chrome_cases.dart' as shell_chrome;
import 'shell_page_layer_cases.dart' as shell_page_layer;
import 'window_double_tap_cases.dart' as window_double_tap;

void main() {
  group('app shell progress', app_shell_progress.main);
  group('shell chrome', shell_chrome.main);
  group('shell page layer', shell_page_layer.main);
  group('window double tap', window_double_tap.main);
}
