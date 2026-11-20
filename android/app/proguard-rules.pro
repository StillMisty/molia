# Keep Jackson classes
-keep class com.fasterxml.jackson.** { *; }
-keep interface com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**

# Keep JNIgen interop classes (ADR-0038)：类名 / 方法由生成代码按字符串查找，
# 混淆会直接 ClassNotFoundException / NoSuchMethodError。
-keep class top.stillmisty.molia.interop.** { *; }

# Keep Pigeon native interop classes (issue #78)：除生成物自带的 @Keep 外，
# host 实现的类名也会被 JNI 按字符串查找；release 冒烟覆盖该路径。
-keep class top.stillmisty.molia.pigeon.** { *; }

# Keep SAF 共享 host（issue #85）：@Keep 已标注；整包保留，避免数据类 /
# 回调方法在 release 裁剪后 Pigeon 与旧通道共用的实例失效。
-keep class top.stillmisty.molia.saf.** { *; }

# Keep AndroidX annotations
-keep class androidx.annotation.** { *; }
-dontwarn androidx.annotation.**

# Additional rules
-keepattributes *Annotation*
-keepattributes Signature
-keep class * extends androidx.annotation.NonNull { *; }
