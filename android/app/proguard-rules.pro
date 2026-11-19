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

# Keep AndroidX annotations
-keep class androidx.annotation.** { *; }
-dontwarn androidx.annotation.**

# Additional rules
-keepattributes *Annotation*
-keepattributes Signature
-keep class * extends androidx.annotation.NonNull { *; }
