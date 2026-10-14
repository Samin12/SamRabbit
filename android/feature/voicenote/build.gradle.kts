plugins { id("com.android.library") }

android {
    namespace = "com.resonolabs.feature.voicenote"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Voice note (side button): record with the text fields' dictation (:feature:compose, OpenAI
// transcription through the runtime), then hand the words to the runtime's /v1/capture, which
// sends them to the Mac bridge. One shot: no talk-back, nothing is ever spoken.
dependencies {
    implementation(project(":core:design"))
    implementation(project(":core:input"))
    implementation(project(":feature:compose"))
    implementation(project(":runtime-host"))
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub on the JVM; the kept-note encoding is tested with the reference jar.
    testImplementation("org.json:json:20231013")
}
