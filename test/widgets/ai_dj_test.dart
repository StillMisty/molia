import 'package:flutter_test/flutter_test.dart';

import 'ai_dj_page_cases.dart' as widgets_ai_dj_page;
import 'ai_dj_history_page_cases.dart' as widgets_ai_dj_history_page;
import 'ai_dj_preferences_page_cases.dart' as widgets_ai_dj_preferences_page;
import 'ai_dj_carousel_cases.dart' as widgets_ai_dj_carousel;

void main() {
  group('ai dj page', widgets_ai_dj_page.main);
  group('ai dj history page', widgets_ai_dj_history_page.main);
  group('ai dj preferences page', widgets_ai_dj_preferences_page.main);
  group('ai dj carousel', widgets_ai_dj_carousel.main);
}
