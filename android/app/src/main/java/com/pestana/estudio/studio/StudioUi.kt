package com.pestana.estudio.studio

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.panel

@Composable
internal fun SCard(modifier: Modifier = Modifier, padding: Dp = 14.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth().panel(radius = 16.dp).padding(padding),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

@Composable
internal fun SLabel(text: String, color: Color = Palette.muted) {
    Text(text.uppercase(), style = Type.mono(11.sp, FontWeight.SemiBold), color = color)
}

@Composable
internal fun SChip(title: String, selected: Boolean = false, tint: Color = Palette.brass, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier
            .alpha(if (enabled) 1f else 0.45f)
            .panel(radius = 10.dp, fill = if (selected) tint.copy(alpha = 0.22f) else Palette.bg, stroke = if (selected) tint else Palette.line)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Text(title, style = Type.body(13.sp, FontWeight.SemiBold), color = if (selected) tint else Palette.fg, maxLines = 1)
    }
}

@Composable
internal fun SIconButton(
    icon: ImageVector,
    label: String,
    size: Dp = 44.dp,
    fill: Color = Palette.bg,
    tint: Color = Palette.fg,
    stroke: Color = Palette.line,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(size)
            .alpha(if (enabled) 1f else 0.4f)
            .panel(shape = CircleShape, fill = fill, stroke = stroke)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(size * 0.48f))
    }
}

@Composable
internal fun SPillButton(text: String, icon: ImageVector?, filled: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier
            .alpha(if (enabled) 1f else 0.5f)
            .clip(RoundedCornerShape(50))
            .background(if (filled) Palette.brass else Palette.bg)
            .panel(shape = RoundedCornerShape(50), fill = if (filled) Palette.brass else Palette.bg, stroke = if (filled) Palette.brass else Palette.brass)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = if (filled) Palette.bg else Palette.brass, modifier = Modifier.size(18.dp))
        Text(text, style = Type.body(14.sp, FontWeight.SemiBold), color = if (filled) Palette.bg else Palette.brass, maxLines = 1)
    }
}

@Composable
internal fun sSliderColors() = SliderDefaults.colors(
    thumbColor = Palette.brass,
    activeTrackColor = Palette.brass,
    inactiveTrackColor = Palette.line,
)

@Composable
internal fun SSwitch(checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Switch(
        checked = checked,
        onCheckedChange = onChange,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = Palette.bg,
            checkedTrackColor = Palette.brass,
            uncheckedThumbColor = Palette.muted,
            uncheckedTrackColor = Palette.bg,
            uncheckedBorderColor = Palette.line,
        ),
    )
}

/** Linha "Rótulo ……… valor" + slider. */
@Composable
internal fun SSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    valueText: String,
    enabled: Boolean = true,
    onChange: (Float) -> Unit,
) {
    Column(Modifier.alpha(if (enabled) 1f else 0.45f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Type.body(13.sp), color = Palette.fg, modifier = Modifier.weight(1f))
            Text(valueText, style = Type.mono(12.sp), color = Palette.muted)
        }
        Slider(
            value = value.coerceIn(range.start, range.endInclusive),
            onValueChange = onChange,
            valueRange = range,
            enabled = enabled,
            colors = sSliderColors(),
            modifier = Modifier.height(32.dp),
        )
    }
}

/** Medidor de nível horizontal (verde → latão → vermelho). */
@Composable
internal fun LevelBar(level: Float, modifier: Modifier = Modifier) {
    val v = level.coerceIn(0f, 1f)
    Box(modifier.height(6.dp).clip(RoundedCornerShape(3.dp)).background(Palette.line)) {
        Box(
            Modifier
                .fillMaxWidth(v)
                .height(6.dp)
                .background(if (v > 0.9f) Palette.off else if (v > 0.6f) Palette.brass else Palette.ok),
        )
    }
}

@Composable
internal fun Spacer8() = Box(Modifier.width(8.dp))

fun formatClock(t: Double, tenths: Boolean = true): String {
    if (!t.isFinite() || t < 0) return if (tenths) "0:00.0" else "0:00"
    val total = t
    val m = (total / 60).toInt()
    val s = total - m * 60
    return if (tenths) "%d:%04.1f".format(m, s).replace(',', '.') else "%d:%02d".format(m, s.toInt())
}

/** "0:12.345" (posição exata, como no canto da régua do iOS). */
fun formatClockMs(t: Double): String {
    if (!t.isFinite() || t < 0) return "0:00.000"
    val m = (t / 60).toInt()
    val s = t - m * 60
    return "%d:%06.3f".format(java.util.Locale.US, m, s)
}
