import 'package:flutter_test/flutter_test.dart';

import 'app_color_picker_cases.dart' as app_color_picker;
import 'cover_fallback_cases.dart' as cover_fallback;
import 'cover_picker_sheet_cases.dart' as cover_picker_sheet;
import 'icon_swap_cases.dart' as icon_swap;
import 'track_menu_tile_cases.dart' as track_menu_tile;

void main() {
  group('app color picker', app_color_picker.main);
  group('cover fallback', cover_fallback.main);
  group('cover picker sheet', cover_picker_sheet.main);
  group('icon swap', icon_swap.main);
  group('track menu tile', track_menu_tile.main);
}
