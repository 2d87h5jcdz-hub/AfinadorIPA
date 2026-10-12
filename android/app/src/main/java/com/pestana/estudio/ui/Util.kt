package com.pestana.estudio.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp

tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** Vibração curta: [strong] para confirmações (corda afinada, nota de referência). */
fun View.haptic(strong: Boolean = false) {
    val c = when {
        strong && Build.VERSION.SDK_INT >= 30 -> HapticFeedbackConstants.CONFIRM
        strong -> HapticFeedbackConstants.LONG_PRESS
        Build.VERSION.SDK_INT >= 27 -> HapticFeedbackConstants.KEYBOARD_PRESS
        else -> HapticFeedbackConstants.KEYBOARD_TAP
    }
    performHapticFeedback(c)
}

/** Mantém a tela acesa enquanto [on] (afinador ouvindo, metrônomo tocando). */
@Composable
fun KeepScreenOn(on: Boolean) {
    val view = LocalView.current
    DisposableEffect(on) {
        view.keepScreenOn = on
        onDispose { view.keepScreenOn = false }
    }
}

/** Sobe o conteúdo [d] e encolhe o espaço que ele ocupa (como um padding negativo). */
fun Modifier.pullUp(d: Dp): Modifier = layout { measurable, constraints ->
    val p = measurable.measure(constraints)
    val dy = d.roundToPx()
    layout(p.width, (p.height - dy).coerceAtLeast(0)) { p.place(0, -dy) }
}
