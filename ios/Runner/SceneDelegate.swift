import Flutter
import UIKit

/// UIScene 生命周期入口（Flutter 3.41+ 默认）。
///
/// 目前只承接 Flutter 的场景事件（前后台、窗口尺寸等），没有自定义逻辑；
/// 需要处理场景级回调时在这里重写，不要把 UI 状态逻辑放回 AppDelegate。
class SceneDelegate: FlutterSceneDelegate {}
