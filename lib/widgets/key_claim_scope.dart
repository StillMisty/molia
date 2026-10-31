/// 焦点作用域内的按键让位声明：焦点位于 [child] 内时登记方向键 / Space /
/// Enter 等，让桌面壳层的全局快捷键让位给获得焦点的行 / chip / 按钮。
///
/// 为什么用不可聚焦的 [Focus] 包一层：`FocusNode.hasFocus` 在子树取得焦点
/// 时为真，判定与焦点树同源，不需要在页面里手写 `primaryFocus` 祖先比较。
library;

import 'package:material_ui/material_ui.dart';

import '../services/key_claims.dart';

class KeyClaimScope extends StatefulWidget {
  const KeyClaimScope({super.key, required this.child});

  final Widget child;

  @override
  State<KeyClaimScope> createState() => _KeyClaimScopeState();
}

class _KeyClaimScopeState extends State<KeyClaimScope> {
  final FocusNode _node = FocusNode(
    debugLabel: 'keyClaimScope',
    canRequestFocus: false,
    skipTraversal: true,
  );
  late KeyClaim _claim;

  @override
  void initState() {
    super.initState();
    _claim = KeyClaims.add(
      keys: searchClaimedKeys,
      active: () => _node.hasFocus,
    );
  }

  @override
  void dispose() {
    KeyClaims.remove(_claim);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
