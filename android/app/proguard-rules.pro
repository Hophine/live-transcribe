# ML Kit registers its components by looking the registrars up reflectively
# when the process starts, so nothing in the code references their
# constructors and R8 strips them. The lookup then fails with "Invalid
# component registrar" and translation is dead for the whole run - in a
# release build only, which is why a debug build never shows it.
-keepclassmembers class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
-keep class com.google.mlkit.**Registrar { public <init>(); }

# The translator is created by name from the registered components.
-keep class com.google.mlkit.nl.translate.** { *; }
