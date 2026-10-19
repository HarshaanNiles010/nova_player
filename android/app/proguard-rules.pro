# ML Kit (lyrics translation) reads some of its classes by reflection;
# shrinking them made language identification crash in release builds.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
