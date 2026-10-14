// Static framework RRO (target package "android") that turns a side-button (KEYCODE_POWER) double
// press into a launch of SamRabbit's non-exported .SideButtonToggle alias, and a triple press into the
// theater-mode signal the app turns into a voice note (theater never sleeps the screen). Resource-only: no code.
// Install: deploy.sh zipaligns it, signs it with the platform key and copies it to /oem/overlay
// (the only overlay directory on the R1 that is both scanned and writable). A reboot is required:
// static RROs are scanned at boot and PhoneWindowManager reads the target activity once in init().
plugins { id("com.android.application") }

android {
    namespace = "com.resonolabs.overlay.powerbutton"
    compileSdk = 36

    defaultConfig {
        // No applicationIdSuffix on any build type: the overlay package name is part of the device
        // contract (cmd overlay list android). Debug vs release only changes the target activity.
        applicationId = "com.resonolabs.overlay.powerbutton"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }

    // Framework config names must survive untouched; resources.arsc stays stored for mmap.
    androidResources { noCompress += listOf("arsc") }
}

// AGP 9 built-in Kotlin adds kotlin-stdlib to every application module; an RRO ships no code.
// Strip it from the variant classpaths only: lint's own tool classpath still needs Kotlin.
configurations.configureEach {
    if (name.endsWith("RuntimeClasspath") || name.endsWith("CompileClasspath")) {
        exclude(group = "org.jetbrains.kotlin")
    }
}
