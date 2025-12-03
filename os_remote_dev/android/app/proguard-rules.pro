# ---- Fix Tink crypto ----
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# ---- Keep javax annotations ----
-keep class javax.annotation.** { *; }
-dontwarn javax.annotation.**

# ---- Keep ErrorProne annotations (used by Tink) ----
-keep class com.google.errorprone.annotations.** { *; }
-dontwarn com.google.errorprone.annotations.**

# ---- Keep metadata for Flutter Secure Storage ----
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**
