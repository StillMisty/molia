import 'package:flutter_test/flutter_test.dart';

import 'cover_deck_metrics_cases.dart' as cover_deck_metrics;
import 'player_cold_start_cases.dart' as player_cold_start;
import 'player_cover_deck_cases.dart' as player_cover_deck;
import 'player_cover_press_cases.dart' as player_cover_press;
import 'player_cover_swap_cases.dart' as player_cover_swap;
import 'player_cover_visibility_cases.dart' as player_cover_visibility;

void main() {
  group('cover deck metrics', cover_deck_metrics.main);
  group('player cold start', player_cold_start.main);
  group('player cover deck', player_cover_deck.main);
  group('player cover press', player_cover_press.main);
  group('player cover swap', player_cover_swap.main);
  group('player cover visibility', player_cover_visibility.main);
}
