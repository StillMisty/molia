# Keep Jackson classes
-keep class com.fasterxml.jackson.** { *; }
-keep interface com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**

# Keep JNIgen interop classes (ADR-0038)：类名 / 方法由生成代码按字符串查找，
# 混淆会直接 ClassNotFoundException / NoSuchMethodError。
-keep class top.stillmisty.molia.interop.** { *; }

# Keep AndroidX annotations
-keep class androidx.annotation.** { *; }
-dontwarn androidx.annotation.**

# Additional rules
-keepattributes *Annotation*
-keepattributes Signature
-keep class * extends androidx.annotation.NonNull { *; }
