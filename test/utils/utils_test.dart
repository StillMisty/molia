import 'package:flutter_test/flutter_test.dart';

import '../html_unescape_cases.dart' as html_unescape;
import 'playback_cover_decode_cases.dart' as playback_cover_decode;
import 'responsive_cases.dart' as responsive;
import 'source_label_cases.dart' as source_label;

void main() {
  group('html unescape', html_unescape.main);
  group('playback cover decode', playback_cover_decode.main);
  group('responsive', responsive.main);
  group('source label', source_label.main);
}
