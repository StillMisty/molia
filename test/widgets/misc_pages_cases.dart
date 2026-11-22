import 'package:flutter_test/flutter_test.dart';

import 'downloads_manage_page_cases.dart' as widgets_downloads_manage_page;
import 'diagnostics_page_cases.dart' as widgets_diagnostics_page;
import 'listening_heatmap_cases.dart' as widgets_listening_heatmap;

void main() {
  group('downloads manage page', widgets_downloads_manage_page.main);
  group('diagnostics page', widgets_diagnostics_page.main);
  group('listening heatmap', widgets_listening_heatmap.main);
}
