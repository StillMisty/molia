// Widget 域 Pigeon native interop（JNI）试点，见 issue #78 / ADR-0038 §9。
//
// 生成（JDK 21，Kotlin 先编译，见 tool/pigeon/generate.sh）：
//   dart run pigeon --input tool/pigeon/widget.dart \
//     --dart_out lib/platform/pigeon/widget.g.dart \
//     --kotlin_out android/app/src/main/kotlin/top/stillmisty/molia/pigeon/WidgetApi.g.kt \
//     --kotlin_package top.stillmisty.molia.pigeon
//
// 只做同步 HostApi：Pigeon native interop 不支持 @TaskQueue /
// @EventChannelApi / @ProxyApi。旧 `top.stillmisty.molia/widget` channel
// 保留为 fallback，契约测试通过前不删。
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    appDirectory: './',
    kotlinOptions: KotlinOptions(
      useJni: true,
      // AGP9 内置 Kotlin 的 release 编译产物；不是 Flutter 模板默认的
      // build/app/tmp/kotlin-classes/release。
      jniClassPaths: <String>[
        'build/app/intermediates/built_in_kotlinc/release/compileReleaseKotlin/classes',
      ],
    ),
  ),
)
/// 小组件要展示的播放快照；字段名与旧 channel payload 保持一致。
class WidgetPayload {
  WidgetPayload({
    required this.songName,
    required this.artistName,
    required this.albumArtUrl,
    required this.isPlaying,
  });

  String songName;
  String artistName;
  String albumArtUrl;
  bool isPlaying;
}

@HostApi()
abstract class WidgetApi {
  void update(WidgetPayload payload);
}
