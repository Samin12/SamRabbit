plugins { id("com.android.library") }

android {
    namespace = "com.resonolabs.feature.cards"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core:design"))
    implementation(project(":core:input"))
    implementation(project(":runtime-host"))
    implementation(project(":feature:calendar"))
    implementation(project(":feature:tasks"))
    implementation(project(":feature:genui"))
    implementation(project(":feature:t3"))
    implementation(project(":feature:compose"))
    implementation(project(":feature:briefing"))
    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub on the JVM; widget parsing tests use the reference jar.
    testImplementation("org.json:json:20231013")
}
