# Keep ML Kit classes used at runtime via reflection.
-keep class com.google.mlkit.** { *; }

# Only the Latin text-recognition model is bundled, so the other scripts' option
# classes aren't on the classpath. Suppress R8's missing-class warnings.
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# llama_flutter_android: the JNI progress/token callbacks are invoked from C++
# via kotlin.jvm.functions.Function1.invoke. Renaming them breaks inference.
-keep class com.write4me.llama_flutter_android.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
-keep class kotlin.jvm.functions.** { *; }
-keepclassmembers class kotlin.jvm.functions.** { *; }
