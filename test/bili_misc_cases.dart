import 'package:flutter_test/flutter_test.dart';

import 'bili_discover_cases.dart' as bili_discover;
import 'bili_ranking_cases.dart' as bili_ranking;
import 'bili_wbi_cases.dart' as bili_wbi;

void main() {
  group('bili discover', bili_discover.main);
  group('bili ranking', bili_ranking.main);
  group('bili wbi', bili_wbi.main);
}
