import java.util.TreeSet
import java.util.zip.ZipFile
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.mikepenz.aboutlibraries.plugin.android")
}

android {
    namespace = "dev.eko.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.eko.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures.compose = true
    testOptions.unitTests.isIncludeAndroidResources = true
    packaging.resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

// Third-party notices (res/raw/aboutlibraries.json, shown by LicensesActivity): generated
// offline from each variant's resolved graph plus config/libraries and config/licenses.
// The build fails on a dependency without a license or with one outside the allow-list;
// proprietary SDK terms are allowed only for the artifacts they cover.
aboutLibraries {
    offlineMode = true
    collect {
        configPath = file("config")
        fetchRemoteLicense = false
        fetchRemoteFunding = false
    }
    library {
        requireLicense = true
    }
    license {
        strictMode = com.mikepenz.aboutlibraries.plugin.StrictMode.FAIL
        allowedLicenses.addAll("Apache-2.0", "MIT", "BSD-3-Clause")
        // Google's proprietary SDK terms, only for the ML Kit barcode scanner and the
        // Play services libraries it pulls in. Named in the README's License section.
        allowedLicensesMap = mapOf(
            "ML Kit Terms of Service" to listOf(
                "com.google.android.gms:play-services-mlkit-barcode-scanning",
                "com.google.mlkit:barcode-scanning",
                "com.google.mlkit:barcode-scanning-common",
                "com.google.mlkit:common",
                "com.google.mlkit:vision-common",
                "com.google.mlkit:vision-interfaces",
            ),
            "ASDKL" to listOf(
                "com.google.android.gms:play-services-base",
                "com.google.android.gms:play-services-basement",
                "com.google.android.gms:play-services-tasks",
                "com.google.android.odml:image",
            ),
        )
    }
}

// Google's ML Kit and Play services AARs list the open-source code they embed (TensorFlow Lite,
// Abseil, protobuf, ...) in third_party_licenses.txt/.json at the AAR root, which AGP does not
// package. Merge those texts, deduplicated and sorted, into assets/licenses/ so the APK carries
// them and LicensesActivity lists them. CI checks the result with scripts/android_notices.py scan.
abstract class GoogleSdkNoticesTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val artifacts: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun merge() {
        // Verbatim text -> the component names it is listed under and the AARs that embed it.
        val texts = HashMap<String, Pair<TreeSet<String>, TreeSet<String>>>()
        for (aar in artifacts.files.filter { it.name.endsWith(".aar") }) {
            ZipFile(aar).use { zip ->
                val list = zip.getEntry("third_party_licenses.txt") ?: return@use
                val index = zip.getEntry("third_party_licenses.json")
                    ?: throw GradleException("${aar.name}: third_party_licenses.txt without its .json index")
                val bytes = zip.getInputStream(list).use { it.readBytes() }
                @Suppress("UNCHECKED_CAST")
                val spans = zip.getInputStream(index).use { groovy.json.JsonSlurper().parse(it) }
                    as Map<String, Map<String, Number>>
                for ((name, span) in spans) {
                    val start = span.getValue("start").toInt()
                    // A missing or zero length runs to the end of the file (oss-licenses format).
                    val length = span["length"]?.toInt() ?: 0
                    val end = if (length > 0) start + length else bytes.size
                    val text = String(bytes, start, end - start, Charsets.UTF_8).trim()
                    val (names, sources) = texts.getOrPut(text) { TreeSet<String>() to TreeSet<String>() }
                    names += name
                    sources += aar.name
                }
            }
        }

        val dir = outputDir.get().asFile.resolve("licenses")
        dir.deleteRecursively()
        if (texts.isEmpty()) return
        dir.mkdirs()
        val rule = "=".repeat(72)
        val entries = texts.entries
            .sortedWith(compareBy({ it.value.first.joinToString(", ").lowercase() }, { it.key }))
            .joinToString("") { (text, where) ->
                "$rule\n${where.first.joinToString(", ")}\nEmbedded in: ${where.second.joinToString(", ")}\n\n$text\n\n"
            }
        dir.resolve("Google-SDK-Third-Party-Notices.txt").writeText(
            "Open-source components embedded in Google ML Kit and Google Play services libraries,\n" +
                "as listed in the third_party_licenses files of their AARs.\n\n" + entries,
        )
    }
}

androidComponents {
    onVariants { variant ->
        val googleSdkNotices = tasks.register<GoogleSdkNoticesTask>("${variant.name}GoogleSdkNotices") {
            artifacts.from(
                variant.runtimeConfiguration.incoming.artifactView {
                    componentFilter { it is ModuleComponentIdentifier }
                }.files,
            )
        }
        variant.sources.assets?.addGeneratedSourceDirectory(googleSdkNotices, GoogleSdkNoticesTask::outputDir)
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":outbox"))
    implementation(project(":capture"))
    implementation(project(":pairing"))
    implementation(project(":transport"))

    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.11.0")
    implementation("androidx.core:core-ktx:1.19.0")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation("androidx.camera:camera-camera2:1.6.1")
    implementation("androidx.camera:camera-lifecycle:1.6.1")
    implementation("androidx.camera:camera-view:1.6.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.robolectric:robolectric:4.17")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
