package dev.eko.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF075E54),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFB8F2E6),
    onPrimaryContainer = Color(0xFF003831),
    secondary = Color(0xFF4D5F91),
    secondaryContainer = Color(0xFFDCE1FF),
    background = Color(0xFFF7F9F7),
    surface = Color(0xFFFCFDFC),
    surfaceVariant = Color(0xFFE2E9E5),
    error = Color(0xFFB3261E),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF8DD8CA),
    onPrimary = Color(0xFF003731),
    primaryContainer = Color(0xFF005048),
    onPrimaryContainer = Color(0xFFB8F2E6),
    secondary = Color(0xFFB7C4F9),
    secondaryContainer = Color(0xFF354677),
    background = Color(0xFF101513),
    surface = Color(0xFF151B18),
    surfaceVariant = Color(0xFF3F4945),
    error = Color(0xFFFFB4AB),
)

@Composable
fun EkoTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        typography = androidx.compose.material3.Typography(),
        content = content,
    )
}
