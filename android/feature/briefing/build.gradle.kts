plugins { id("com.android.library") }

android {
    namespace = "com.resonolabs.feature.briefing"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// The morning brief (CONTRACTS-WAVE8 B4): the runtime's cached GET /v1/briefing, a full page with
// the item actions (a Gmail draft at most: nothing is ever sent), and the model the Cards board
// widget shares.
dependencies {
    implementation(project(":core:design"))
    implementation(project(":core:input"))
    implementation(project(":runtime-host"))
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub on the JVM; parsing tests use the reference jar.
    testImplementation("org.json:json:20231013")
}
