package com.pestana.estudio.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Cartão com o fundo de painel e a borda fina da paleta. */
fun Modifier.panel(
    radius: Dp = 22.dp,
    fill: Color = Palette.panel,
    stroke: Color = Palette.line,
    strokeWidth: Dp = 1.dp,
): Modifier {
    val shape = RoundedCornerShape(radius)
    return this.clip(shape).background(fill, shape).border(strokeWidth, stroke, shape)
}

fun Modifier.panel(shape: Shape, fill: Color = Palette.panel, stroke: Color = Palette.line, strokeWidth: Dp = 1.dp): Modifier =
    this.clip(shape).background(fill, shape).border(strokeWidth, stroke, shape)

/** Clique sem o efeito de onda do Material (o visual do app é mais sóbrio). */
@Composable
fun Modifier.plainClick(onClick: () -> Unit): Modifier =
    this.clickable(remember { MutableInteractionSource() }, indication = null, onClick = onClick)

/** Controle segmentado no estilo do iOS, com as cores do app. */
@Composable
fun Segmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.panel(radius = 10.dp).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) Palette.line else Color.Transparent)
                    .clickable { onSelect(i) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = Type.body(14.sp, if (on) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (on) Palette.fg else Palette.muted,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
            }
        }
    }
}

/** Botão quadrado pequeno (− / +). */
@Composable
fun StepButton(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.line)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = Type.body(18.sp), color = Palette.fg)
    }
}
