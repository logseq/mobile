package com.logseq.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.logseq.app.R

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
    val darkSurface = Color(0xff101318)

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
    )

    val darkScheme = darkColorScheme(
        primary = Color(0xff9bd3d4),
        onPrimary = Color(0xff002d38),
        primaryContainer = Color(0xff0d4f50),
        onPrimaryContainer = Color(0xffbbebec),
        secondary = Color(0xffb8cad6),
        secondaryContainer = Color(0xff3a4a55),
        onSecondaryContainer = Color(0xffd4e6f2),
        surface = darkSurface,
        background = darkSurface,
        surfaceContainerLowest = Color(0xff0b0e12),
        surfaceContainerLow = Color(0xff14171d),
        surfaceContainer = Color(0xff181c22),
        surfaceContainerHigh = Color(0xff1d2229),
        surfaceContainerHighest = Color(0xff22272f),
    )
}

internal fun logseqThemeMode(appearance: String): String = when (appearance) {
    "light" -> "light"
    "dark" -> "dark"
    else -> "system"
}
