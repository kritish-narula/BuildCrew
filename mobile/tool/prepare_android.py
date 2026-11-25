#!/usr/bin/env python3
"""Generate + harden the Android host project. Idempotent; used locally and in CI.

Why generated instead of committed: `flutter create` emits Gradle files that match the exact
Flutter version in use, so upgrading Flutter never leaves us with a stale, broken android/ dir.
We then apply a small, explicit set of patches:
  * applicationId/namespace com.buildcrew.app (permanent — changing it breaks updates)
  * release signing from android/key.properties (the permanent release key; CI writes it)
  * Java 8+ API desugaring (needed by flutter_local_notifications) + androidx.core (FileProvider)
  * permissions, no cloud backup, HTTPS-only network config, FileProvider for self-update
  * our MainActivity (updater bridge), launcher icons, R8 keep-rules

Usage (from mobile/):  python3 tool/prepare_android.py
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"
OVERLAY = ROOT / "android_overlay"
APP_ID = "com.buildcrew.app"


def fail(msg: str) -> None:
    print(f"::error::prepare_android: {msg}")
    sys.exit(1)


def sub_once(text: str, pattern: str, repl: str, what: str, flags=0) -> str:
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n == 0:
        fail(f"could not patch {what} — Flutter template changed? pattern: {pattern}")
    return new


def ensure_project() -> None:
    if (ANDROID / "app").exists():
        return
    subprocess.run(["flutter", "create", "--org", "com.buildcrew", "--project-name", "buildcrew",
                    "--platforms", "android", "."], cwd=ROOT, check=True)
    stray = ROOT / "test" / "widget_test.dart"  # template test references a MyApp we don't have
    if stray.exists() and "MyApp" in stray.read_text():
        stray.unlink()


def patch_gradle() -> None:
    f = ANDROID / "app" / "build.gradle.kts"
    if not f.exists():
        fail("expected Kotlin DSL android/app/build.gradle.kts")
    g = f.read_text()
    if "BUILDCREW_PATCHED" in g:
        return
    # Top-level import: inside android {} the name `java` resolves to Gradle's java extension.
    g = "import java.util.Properties\n\n" + g
    g = sub_once(g, r'namespace\s*=\s*"[^"]+"', f'namespace = "{APP_ID}"', "namespace")
    g = sub_once(g, r'applicationId\s*=\s*"[^"]+"', f'applicationId = "{APP_ID}"', "applicationId")
    g = sub_once(g, r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", "compileOptions")
    signing = '''
    // BUILDCREW_PATCHED — permanent release key. Every APK MUST be signed with the same key,
    // otherwise Android refuses to install it over the previous version (no in-place updates).
    signingConfigs {
        create("release") {
            val keyProps = Properties()
            val keyFile = rootProject.file("key.properties")
            if (keyFile.exists()) {
                keyFile.inputStream().use { keyProps.load(it) }
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {'''
    g = sub_once(g, r"\n\s*buildTypes\s*\{", signing, "buildTypes")
    g = sub_once(g, r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                 'signingConfig = if (rootProject.file("key.properties").exists()) '
                 'signingConfigs.getByName("release") else signingConfigs.getByName("debug")\n'
                 '            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
                 "release signingConfig")
    g += '''
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.13.1")
}
'''
    f.write_text(g)
    (ANDROID / "app" / "proguard-rules.pro").write_text(
        "# flutter_local_notifications uses Gson with generic types\n"
        "-keep class com.dexterous.** { *; }\n"
        "-keepattributes Signature\n-keepattributes *Annotation*\n"
        "-keep class com.google.gson.reflect.TypeToken { *; }\n"
        "-keep class * extends com.google.gson.reflect.TypeToken\n"
        "-dontwarn com.google.errorprone.annotations.**\n")


def patch_manifest() -> None:
    f = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    m = f.read_text()
    if "BUILDCREW_PATCHED" in m:
        return
    perms = '''
    <!-- BUILDCREW_PATCHED -->
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- Self-update from GitHub Releases (user grants "install unknown apps" once) -->
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
    <!-- "Update ready" notification on Android 13+ -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
'''
    m = sub_once(m, r"(<manifest[^>]*>)", r"\1" + perms.replace("\\", "\\\\"), "<manifest>")
    m = sub_once(m, r'android:label="[^"]*"', 'android:label="BuildCrew"', "label")
    m = sub_once(m, r"(<application)", r'\1\n        android:allowBackup="false"\n'
                 r'        android:fullBackupContent="false"\n'
                 r'        android:dataExtractionRules="@xml/data_extraction_rules"\n'
                 r'        android:networkSecurityConfig="@xml/network_security_config"', "<application>")
    provider = '''
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.updates"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/update_paths" />
        </provider>
    </application>'''
    m = sub_once(m, r"\s*</application>", provider.replace("\\", "\\\\"), "</application>")
    f.write_text(m)


def apply_overlay() -> None:
    kotlin_root = ANDROID / "app" / "src" / "main" / "kotlin"
    for old in kotlin_root.rglob("MainActivity.kt"):
        if "buildcrew/updater" not in old.read_text():
            old.unlink()
    dest = kotlin_root / Path(*APP_ID.split(".")) / "MainActivity.kt"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(OVERLAY / "kotlin" / "MainActivity.kt", dest)
    res = ANDROID / "app" / "src" / "main" / "res"
    for src in (OVERLAY / "res").rglob("*"):
        if src.is_file():
            out = res / src.relative_to(OVERLAY / "res")
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, out)
    # Remove template adaptive icon so our PNG icons are used on Android 8+.
    for adaptive in res.glob("mipmap-anydpi*/ic_launcher*.xml"):
        adaptive.unlink()


if __name__ == "__main__":
    ensure_project()
    patch_gradle()
    patch_manifest()
    apply_overlay()
    print("prepare_android: OK")
