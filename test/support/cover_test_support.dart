import 'package:flutter/widgets.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

/// 测试用封面存储 Provider（加进 `MultiProvider(providers: [...])`）。
///
/// 生产组合根在 `local_data_stack` 构造唯一实例后挂进 Provider 树；展示用例
/// 只关心「能解析封面」时用这个空索引实例，需要真实自定义封面的用例把
/// 自己构造的 store 传进来。
SingleChildWidget coverStoreProvider([CustomCoverStore? store]) =>
    Provider<CustomCoverStore>.value(value: store ?? CustomCoverStore());

/// 给没有 `MultiProvider` 的宿主包一层封面存储 Provider。
Widget withCoverStore(Widget child, {CustomCoverStore? store}) =>
    Provider<CustomCoverStore>.value(
      value: store ?? CustomCoverStore(),
      child: child,
    );
