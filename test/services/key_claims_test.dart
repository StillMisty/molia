import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/key_claims.dart';
import 'package:molia/widgets/key_claim_scope.dart';

/// 全局快捷键让位协议：登记哪些键、判定现算、dispose 注销。
void main() {
  setUp(KeyClaims.reset);
  tearDown(KeyClaims.reset);

  test('登记 / 注销 / 现算：只接管登记键，状态翻转立即生效', () {
    var active = false;
    final claim = KeyClaims.add(
      keys: {LogicalKeyboardKey.space, LogicalKeyboardKey.arrowDown},
      active: () => active,
    );

    expect(KeyClaims.claims(LogicalKeyboardKey.space), isFalse);
    active = true;
    expect(KeyClaims.claims(LogicalKeyboardKey.space), isTrue);
    expect(KeyClaims.claims(LogicalKeyboardKey.arrowDown), isTrue);
    expect(
      KeyClaims.claims(LogicalKeyboardKey.enter),
      isFalse,
      reason: '未登记的键不接管',
    );

    KeyClaims.remove(claim);
    expect(KeyClaims.claims(LogicalKeyboardKey.space), isFalse);
  });

  test('多个登记取并集；不接管的登记不影响其它登记', () {
    final never = KeyClaims.add(
      keys: {LogicalKeyboardKey.enter},
      active: () => false,
    );
    final always = KeyClaims.add(
      keys: {LogicalKeyboardKey.enter},
      active: () => true,
    );
    expect(KeyClaims.claims(LogicalKeyboardKey.enter), isTrue);

    KeyClaims.remove(always);
    expect(KeyClaims.claims(LogicalKeyboardKey.enter), isFalse);
    KeyClaims.remove(never);
    expect(KeyClaims.claims(LogicalKeyboardKey.enter), isFalse);
  });

  testWidgets('KeyClaimScope 只在自身子树有焦点时接管', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              KeyClaimScope(
                child: TextField(
                  key: const ValueKey('claimed'),
                  autofocus: true,
                ),
              ),
              TextField(key: const ValueKey('outside')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(KeyClaims.claims(LogicalKeyboardKey.arrowDown), isTrue);

    await tester.tap(find.byKey(const ValueKey('outside')));
    await tester.pump();
    expect(
      KeyClaims.claims(LogicalKeyboardKey.arrowDown),
      isFalse,
      reason: '焦点离开子树后不再接管',
    );
  });

  test('reset 清空全部登记（测试收尾防串扰）', () {
    KeyClaims.add(keys: {LogicalKeyboardKey.numpadEnter}, active: () => true);
    expect(KeyClaims.claims(LogicalKeyboardKey.numpadEnter), isTrue);
    KeyClaims.reset();
    expect(KeyClaims.claims(LogicalKeyboardKey.numpadEnter), isFalse);
  });
}
