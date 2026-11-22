import 'package:flutter_test/flutter_test.dart';

import 'contrast_cases.dart' as theme_contrast;
import 'predictive_back_cases.dart' as theme_predictive_back;

void main() {
  group('contrast', theme_contrast.main);
  group('predictive back', theme_predictive_back.main);
}
