/// 焦点作用域内的按键让位声明：焦点位于 [child] 内时登记方向键 / Space /
/// Enter 等，让桌面壳层的全局快捷键让位给获得焦点的行 / chip / 按钮。
///
/// 为什么用不可聚焦的 [Focus] 包一层：`FocusNode.hasFocus` 在子树取得焦点
/// 时为真，判定与焦点树同源，不需要在页面里手写 `primaryFocus` 祖先比较。
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/key_claims.dart';

/// 页面版搜索结果区的按键让位范围（遮罩整窗另有自己的登记）。
final Set<LogicalKeyboardKey> searchResultClaimedKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
};

class KeyClaimScope extends StatefulWidget {
  const KeyClaimScope({super.key, required this.child, this.keys});

  final Widget child;

  /// 覆盖默认让位键；null = [searchResultClaimedKeys]。
  final Set<LogicalKeyboardKey>? keys;

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
      keys: widget.keys ?? searchResultClaimedKeys,
      active: () => _node.hasFocus,
    );
  }

  @override
  void didUpdateWidget(covariant KeyClaimScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKeys = oldWidget.keys ?? searchResultClaimedKeys;
    final nextKeys = widget.keys ?? searchResultClaimedKeys;
    if (!setEquals(oldKeys, nextKeys)) {
      KeyClaims.remove(_claim);
      _claim = KeyClaims.add(keys: nextKeys, active: () => _node.hasFocus);
    }
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
