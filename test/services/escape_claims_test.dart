import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/escape_claims.dart';

/// Esc 占用登记表单测：add / remove / any 与「现算」语义。
void main() {
  setUp(EscapeClaims.reset);
  tearDown(EscapeClaims.reset);

  test('any：无登记方时为 false', () {
    expect(EscapeClaims.any, isFalse);
  });

  test('add / remove：登记恒真判定后接管，注销后回到不接管', () {
    bool claim() => true;
    EscapeClaims.add(claim);
    expect(EscapeClaims.any, isTrue);
    EscapeClaims.remove(claim);
    expect(EscapeClaims.any, isFalse);
  });

  test('any：判定现算，登记方状态翻转无需重新登记', () {
    var active = false;
    bool claim() => active;
    EscapeClaims.add(claim);
    expect(EscapeClaims.any, isFalse, reason: '登记但此刻不接管 → false');
    active = true;
    expect(EscapeClaims.any, isTrue, reason: '状态翻转后立即生效');
    active = false;
    expect(EscapeClaims.any, isFalse, reason: '不再接管后立即失效');
  });

  test('any：任一登记方接管即为 true', () {
    bool never() => false;
    bool always() => true;
    EscapeClaims.add(never);
    expect(EscapeClaims.any, isFalse);
    EscapeClaims.add(always);
    expect(EscapeClaims.any, isTrue);
    EscapeClaims.remove(always);
    expect(EscapeClaims.any, isFalse, reason: '仅剩不接管的登记方');
  });

  test('remove：未登记时为空操作；重复 add 只登记一次', () {
    bool claim() => true;
    EscapeClaims.remove(claim);
    expect(EscapeClaims.any, isFalse);
    EscapeClaims.add(claim);
    EscapeClaims.add(claim);
    EscapeClaims.remove(claim);
    expect(EscapeClaims.any, isFalse, reason: 'Set 语义：一次 remove 即注销');
  });
}
