import 'package:flutter_test/flutter_test.dart';

import 'color_usage_cases.dart' as architecture_color_usage;
import 'icon_usage_cases.dart' as architecture_icon_usage;
import 'm3e_button_cases.dart' as architecture_m3e_button;
import 'm3e_component_usage_cases.dart' as architecture_m3e_component_usage;
import 'm3e_typography_cases.dart' as architecture_m3e_typography;
import 'media_query_usage_cases.dart' as architecture_media_query_usage;
import 'prefs_usage_cases.dart' as architecture_prefs_usage;
import 'settings_keys_cases.dart' as architecture_settings_keys;
import 'settings_registry_usage_cases.dart'
    as architecture_settings_registry_usage;
import 'shape_usage_cases.dart' as architecture_shape_usage;
import 'tooltip_usage_cases.dart' as architecture_tooltip_usage;
import 'tray_import_cases.dart' as architecture_tray_import;

void main() {
  group('color usage', architecture_color_usage.main);
  group('icon usage', architecture_icon_usage.main);
  group('m3e button', architecture_m3e_button.main);
  group('m3e component usage', architecture_m3e_component_usage.main);
  group('m3e typography', architecture_m3e_typography.main);
  group('media query usage', architecture_media_query_usage.main);
  group('prefs usage', architecture_prefs_usage.main);
  group('settings keys', architecture_settings_keys.main);
  group('settings registry usage', architecture_settings_registry_usage.main);
  group('shape usage', architecture_shape_usage.main);
  group('tooltip usage', architecture_tooltip_usage.main);
  group('tray import', architecture_tray_import.main);
}
