import 'package:flutter_test/flutter_test.dart';

import 'source_manager_bili_cases.dart' as source_manager_bili;
import 'source_manager_builtin_lyric_cases.dart' as source_manager_builtin_lyric;
import 'sources_page_dialog_navigation_cases.dart' as sources_page_dialog_navigation;
import 'sources_page_menu_dialog_cases.dart' as sources_page_menu_dialog;

void main() {
  group('source manager bili', source_manager_bili.main);
  group('source manager builtin lyric', source_manager_builtin_lyric.main);
  group('sources page dialog navigation', sources_page_dialog_navigation.main);
  group('sources page menu dialog', sources_page_menu_dialog.main);
}
