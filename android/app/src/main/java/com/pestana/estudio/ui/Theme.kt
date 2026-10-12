package com.pestana.estudio.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

/** Paleta do Pestana (a mesma do app iOS). */
object Palette {
    val bg = Color(0xFF16120F)
    val panel = Color(0xFF211B16)
    val line = Color(0xFF3A3029)
    val fg = Color(0xFFF3EBE1)
    val muted = Color(0xFFA8998A)
    val brass = Color(0xFFD9A441)
    val ok = Color(0xFF5FCF8A)
    val off = Color(0xFFE2694A)
}

/** Títulos em serifada pesada, números em monoespaçada. */
object Type {
    fun serif(size: TextUnit, weight: FontWeight = FontWeight.Black) =
        TextStyle(fontFamily = FontFamily.Serif, fontWeight = weight, fontSize = size)

    fun mono(size: TextUnit, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontFamily = FontFamily.Monospace, fontWeight = weight, fontSize = size)

    fun body(size: TextUnit = 15.sp, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size, fontWeight = weight)
}

private val scheme = darkColorScheme(
    primary = Palette.brass,
    onPrimary = Palette.bg,
    secondary = Palette.ok,
    onSecondary = Palette.bg,
    background = Palette.bg,
    onBackground = Palette.fg,
    surface = Palette.bg,
    onSurface = Palette.fg,
    surfaceVariant = Palette.panel,
    onSurfaceVariant = Palette.muted,
    surfaceContainer = Palette.panel,
    surfaceContainerHigh = Palette.panel,
    outline = Palette.line,
    outlineVariant = Palette.line,
    error = Palette.off,
)

@Composable
fun PestanaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
