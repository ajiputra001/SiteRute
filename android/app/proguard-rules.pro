# Project-specific R8 rules. Flutter's Gradle plugin passes this file to release builds.

# FixSynthesizer reads Location.mFieldsMask by name on API 24-30 (see the long note on
# clearMockFlag: this only affects fixes read back inside this app, it does not hide the
# mock bit from other apps). Without the keep rule R8 may rename or strip the field, and
# the reflection sits inside runCatching so the failure would be silent.
-keepclassmembers class android.location.Location {
    private int mFieldsMask;
    private byte mFieldsMask;
}
