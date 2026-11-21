import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 与 [Offstage] 行为一致、但隐藏时**不布局子级**的门控件。
///
/// 不能直接用 [Offstage]：`RenderOffstage.performLayout` 在 offstage 时仍会
/// `child.layout(constraints)`，隐藏页每帧（窗口 resize 每像素）都要重排整棵
/// 页面子树，这是本仓桌面窗口拖拽卡顿的主因。这里除布局外的契约与
/// [Offstage] 相同：隐藏时尺寸取 [BoxConstraints.smallest]，不 paint、
/// 不 hitTest、`paintsChild == false`、不进 semantics，finder 的
/// `skipOffstage` 也按隐藏处理。
///
/// 显示/隐藏切换只把本件标脏；重新显示时子级用当时的约束补一次布局
/// （隐藏期间子级若被标脏，也会在这次布局中处理）。
class LayoutSkippingOffstage extends SingleChildRenderObjectWidget {
  const LayoutSkippingOffstage({super.key, this.hidden = true, super.child});

  /// 是否隐藏子树。隐藏期间不布局、不绘制、不命中、不参与语义。
  final bool hidden;

  @override
  RenderLayoutSkippingOffstage createRenderObject(BuildContext context) =>
      RenderLayoutSkippingOffstage(hidden: hidden);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLayoutSkippingOffstage renderObject,
  ) {
    renderObject.hidden = hidden;
  }

  @override
  SingleChildRenderObjectElement createElement() =>
      _LayoutSkippingOffstageElement(this);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<bool>('hidden', hidden));
  }
}

/// [LayoutSkippingOffstage] 的元素：隐藏时不让 `skipOffstage` finder 访问
/// 子级，保持与 [Offstage] 一致的可见性语义。
class _LayoutSkippingOffstageElement extends SingleChildRenderObjectElement {
  _LayoutSkippingOffstageElement(LayoutSkippingOffstage super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    if (!(widget as LayoutSkippingOffstage).hidden) {
      super.debugVisitOnstageChildren(visitor);
    }
  }
}

/// 隐藏时跳过子级布局的 [RenderOffstage] 替代实现。
///
/// 尺寸、绘制、命中、语义与 [RenderOffstage] 一致；唯一差异是
/// `performLayout` 在隐藏分支不调用 `child.layout`。
class RenderLayoutSkippingOffstage extends RenderProxyBox {
  RenderLayoutSkippingOffstage({this._hidden = true, RenderBox? child})
    : super(child);

  bool get hidden => _hidden;
  bool _hidden;
  set hidden(bool value) {
    if (value == _hidden) return;
    _hidden = value;
    // 本件在壳层里始终拿 tight 约束（`_ShellPageLayer` 外层 SizedBox.expand），
    // 因此是 relayout boundary：隐藏 / 显示只登记自己，不把整条父链标脏。
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      hidden ? 0.0 : super.computeMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      hidden ? 0.0 : super.computeMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      hidden ? 0.0 : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      hidden ? 0.0 : super.computeMaxIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      hidden ? null : super.computeDistanceToActualBaseline(baseline);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => hidden ? null : super.computeDryBaseline(constraints, baseline);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      hidden ? constraints.smallest : super.computeDryLayout(constraints);

  @override
  void performLayout() {
    if (hidden) {
      // 尺寸取 constraints.smallest（壳层里是 tight 约束，即父级给定尺寸），
      // 刻意不调用 child.layout —— 隐藏页不参与本帧布局。
      size = constraints.smallest;
      return;
    }
    super.performLayout();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !hidden && super.hitTest(result, position: position);

  @override
  bool paintsChild(RenderBox child) {
    assert(child.parent == this);
    return !hidden;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (hidden) return;
    super.paint(context, offset);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (hidden) return;
    super.visitChildrenForSemantics(visitor);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<bool>('hidden', hidden));
  }

  @override
  List<DiagnosticsNode> debugDescribeChildren() {
    final RenderBox? child = this.child;
    if (child == null) return const <DiagnosticsNode>[];
    return <DiagnosticsNode>[
      child.toDiagnosticsNode(
        name: 'child',
        style: hidden
            ? DiagnosticsTreeStyle.offstage
            : DiagnosticsTreeStyle.sparse,
      ),
    ];
  }
}
