package com.logseq.logseq.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.logseq.logseq.R

// Port of the former Dart theme — M3 fidelity scheme seeded
// on the Logseq accent; the light/dark surfaces match the previous theme so
// backend-side token lookups (surface-container-* names in LuiTheme)
// resolve to the same colors the previous app showed.
internal object LogseqTheme {
    val inter = FontFamily(
        Font(R.font.inter_regular, FontWeight.Normal),
        Font(R.font.inter_medium, FontWeight.Medium),
        Font(R.font.inter_semibold, FontWeight.SemiBold),
        Font(R.font.inter_bold, FontWeight.Bold),
        Font(R.font.inter_regular_italic, FontWeight.Normal, FontStyle.Italic),
        Font(R.font.inter_medium_italic, FontWeight.Medium, FontStyle.Italic),
        Font(R.font.inter_semibold_italic, FontWeight.SemiBold, FontStyle.Italic),
        Font(R.font.inter_bold_italic, FontWeight.Bold, FontStyle.Italic),
    )

    private fun TextStyle.withInter() = copy(fontFamily = inter, letterSpacing = 0.sp)

    val typography = Typography().let { base ->
        base.copy(
            displayLarge = base.displayLarge.withInter(),
            displayMedium = base.displayMedium.withInter(),
            displaySmall = base.displaySmall.withInter(),
            headlineLarge = base.headlineLarge.withInter(),
            headlineMedium = base.headlineMedium.withInter(),
            headlineSmall = base.headlineSmall.withInter(),
            titleLarge = base.titleLarge.withInter(),
            titleMedium = base.titleMedium.withInter(),
            titleSmall = base.titleSmall.withInter(),
            bodyLarge = base.bodyLarge.withInter(),
            bodyMedium = base.bodyMedium.withInter(),
            bodySmall = base.bodySmall.withInter(),
            labelLarge = base.labelLarge.withInter(),
            labelMedium = base.labelMedium.withInter(),
            labelSmall = base.labelSmall.withInter(),
        )
    }

    val accent = Color(0xff1b6898)
    val lightSurface = Color(0xfff8f9ff)
    private val solarizedBackground = Color(0xff002d38)

    // Material Expressive menus read the tertiary container roles for selection.
    private fun ColorScheme.withMenuSelectionColors() = copy(
        tertiaryContainer = secondaryContainer,
        onTertiaryContainer = onSecondaryContainer,
    )

    val lightScheme = lightColorScheme(
        primary = accent,
        onPrimary = Color.White,
        primaryContainer = Color(0xffcfe5ff),
        onPrimaryContainer = Color(0xff001d32),
        secondary = Color(0xff51616f),
        secondaryContainer = Color(0xffd5e5f4),
        onSecondaryContainer = Color(0xff0e1d2a),
        surface = lightSurface,
        // Match the iOS app chrome background (#fcfcfc) instead of the M3
        // default pink-tinted surface.
        background = Color(0xfffcfcfc),
        surfaceContainerLowest = Color(0xffffffff),
        surfaceContainerLow = Color(0xfff2f3f8),
        surfaceContainer = Color(0xffeceef4),
        surfaceContainerHigh = Color(0xffe6e8ef),
        surfaceContainerHighest = Color(0xffe0e2ea),
    ).withMenuSelectionColors()

    val darkScheme = darkColorScheme(
        primary = Color(0xff9bd3d4),
        onPrimary = Color(0xff002d38),
        primaryContainer = Color(0xff0d4f50),
        onPrimaryContainer = Color(0xffbbebec),
        secondary = Color(0xffb8cad6),
        secondaryContainer = Color(0xff3a4a55),
        onSecondaryContainer = Color(0xffd4e6f2),
        surface = solarizedBackground,
        background = solarizedBackground,
        onBackground = Color(0xffedfdfd),
        onSurface = Color(0xffedfdfd),
        onSurfaceVariant = Color(0xff9ab1b5),
        surfaceVariant = Color(0xff19394d),
        surfaceDim = solarizedBackground,
        surfaceBright = Color(0xff315860),
        surfaceContainerLowest = Color(0xff00242e),
        surfaceContainerLow = Color(0xff0b3540),
        surfaceContainer = Color(0xff143d48),
        surfaceContainerHigh = Color(0xff1e4651),
        surfaceContainerHighest = Color(0xff274f5a),
    ).withMenuSelectionColors()

    val blackScheme = darkScheme.copy(
        surface = Color.Black,
        background = Color.Black,
        secondaryContainer = Color(0xff38383a),
        onSecondaryContainer = Color(0xfff4f4f5),
        onBackground = Color(0xfff4f4f5),
        onSurface = Color(0xfff4f4f5),
        onSurfaceVariant = Color(0xffa1a1aa),
        surfaceVariant = Color(0xff242424),
        surfaceDim = Color.Black,
        surfaceBright = Color(0xff333333),
        surfaceContainerLowest = Color.Black,
        surfaceContainerLow = Color(0xff1c1c1e),
        surfaceContainer = Color(0xff222224),
        surfaceContainerHigh = Color(0xff28282a),
        surfaceContainerHighest = Color(0xff303032),
    )

    fun colorScheme(dark: Boolean, darkTheme: String): ColorScheme = when {
        !dark -> lightScheme
        darkTheme == "solarized" -> darkScheme
        else -> blackScheme
    }

    fun semanticColors(scheme: ColorScheme): Map<String, Color> {
        val groupedRowBackground = if (scheme.background == lightScheme.background) {
            Color.White
        } else {
            Color.White.copy(alpha = 0.08f).compositeOver(scheme.background)
        }
        return mapOf(
            "background" to scheme.background,
            "surface" to groupedRowBackground,
            "card" to groupedRowBackground,
            "code-container" to scheme.surfaceContainerHighest,
        )
    }
}

internal fun logseqThemeMode(appearance: String): String = when (appearance) {
    "light" -> "light"
    "dark" -> "dark"
    else -> "system"
}
