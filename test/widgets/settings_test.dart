import 'package:flutter_test/flutter_test.dart';

import 'settings_page_cases.dart' as widgets_settings_page;
import 'settings_destructive_actions_cases.dart'
    as widgets_settings_destructive_actions;
import 'settings_section_card_cases.dart' as widgets_settings_section_card;
import 'settings_section_availability_cases.dart'
    as widgets_settings_section_availability;
import 'lyrics_display_settings_pages_cases.dart'
    as widgets_lyrics_display_settings_pages;

void main() {
  group('settings page', widgets_settings_page.main);
  group(
    'settings destructive actions',
    widgets_settings_destructive_actions.main,
  );
  group('settings section card', widgets_settings_section_card.main);
  group(
    'settings section availability',
    widgets_settings_section_availability.main,
  );
  group(
    'lyrics display settings pages',
    widgets_lyrics_display_settings_pages.main,
  );
}
