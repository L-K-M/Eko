plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:6.1.2")
}

sourceSets.test {
    resources.srcDir(rootProject.projectDir.resolve("../protocol/test-vectors"))
}

tasks.test {
    useJUnitPlatform()
}
