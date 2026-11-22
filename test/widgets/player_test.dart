import 'package:flutter_test/flutter_test.dart';

import 'player_cover_deck_cases.dart' as widgets_player_cover_deck;
import 'player_layout_cases.dart' as widgets_player_layout;
import 'desktop_now_playing_bar_cases.dart' as widgets_desktop_now_playing_bar;
import 'player_play_mode_cases.dart' as widgets_player_play_mode;
import 'playback_details_section_cases.dart'
    as widgets_playback_details_section;
import 'cross_fade_swap_cases.dart' as widgets_cross_fade_swap;
import 'sleep_timer_sheet_cases.dart' as widgets_sleep_timer_sheet;
import 'window_controls_cases.dart' as widgets_window_controls;
import 'desktop_brand_capsule_cases.dart' as widgets_desktop_brand_capsule;

void main() {
  group('player cover deck', widgets_player_cover_deck.main);
  group('player layout', widgets_player_layout.main);
  group('desktop now playing bar', widgets_desktop_now_playing_bar.main);
  group('player play mode', widgets_player_play_mode.main);
  group('playback details section', widgets_playback_details_section.main);
  group('cross fade swap', widgets_cross_fade_swap.main);
  group('sleep timer sheet', widgets_sleep_timer_sheet.main);
  group('window controls', widgets_window_controls.main);
  group('desktop brand capsule', widgets_desktop_brand_capsule.main);
}
