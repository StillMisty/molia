import 'package:flutter_test/flutter_test.dart';

import 'favorites_layout_cases.dart' as app_favorites_layout;
import 'favorites_locate_cases.dart' as app_favorites_locate;
import 'favorites_page_state_cases.dart' as app_favorites_page_state;
import 'favorites_selection_cases.dart' as app_favorites_selection;
import 'report_cases.dart' as app_report;

void main() {
  group('favorites layout', app_favorites_layout.main);
  group('favorites locate', app_favorites_locate.main);
  group('favorites page state', app_favorites_page_state.main);
  group('favorites selection', app_favorites_selection.main);
  group('report', app_report.main);
}
