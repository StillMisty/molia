import 'package:flutter_test/flutter_test.dart';

import 'listening_heatmap_cases.dart' as listening_heatmap;
import 'paged_list_cases.dart' as paged_list;
import 'row_actions_cases.dart' as row_actions;
import 'track_table_header_cases.dart' as track_table_header;
import 'volume_control_cases.dart' as volume_control;

void main() {
  group('listening heatmap', listening_heatmap.main);
  group('paged list', paged_list.main);
  group('row actions', row_actions.main);
  group('track table header', track_table_header.main);
  group('volume control', volume_control.main);
}
