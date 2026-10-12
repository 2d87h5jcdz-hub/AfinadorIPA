package com.pestana.estudio.metronome

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.core.Tempo
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Segmented
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.haptic
import com.pestana.estudio.ui.panel

@Composable
fun MetronomeScreen(metronome: Metronome) {
    // Sincroniza as bolinhas com o som, quadro a quadro.
    LaunchedEffect(metronome.playing) {
        while (metronome.playing) {
            withFrameNanos { metronome.pollBeat() }
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.bg)) {
        val landscape = maxWidth > maxHeight
        if (landscape) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Header()
                    BeatDots(metronome)
                    BpmDisplay(metronome, landscape = true)
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    BpmControls(metronome, compact = true)
                    SignaturePicker(metronome)
                    ActionButtons(metronome)
                }
            }
        } else {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = maxHeight)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.SpaceBetween,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(22.dp),
                ) {
                    Header()
                    BeatDots(metronome)
                    BpmDisplay(metronome, landscape = false)
                    BpmControls(metronome, compact = false)
                    SignaturePicker(metronome)
                }
                Box(Modifier.padding(top = 22.dp)) { ActionButtons(metronome) }
            }
        }
    }
}

@Composable
private fun Header() {
    Row(Modifier.fillMaxWidth()) {
        Text("Metrônomo", style = Type.serif(26.sp), color = Palette.fg)
    }
}

@Composable
private fun BpmDisplay(m: Metronome, landscape: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("${m.bpm.toInt()}", style = Type.serif(if (landscape) 84.sp else 110.sp), color = Palette.fg)
        Text("BPM · ${m.tempoName}", style = Type.mono(13.sp), color = Palette.muted)
    }
}

@Composable
private fun BpmControls(m: Metronome, compact: Boolean) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 10.dp),
    ) {
        RoundButton("−5") { m.changeBpm(m.bpm - 5) }
        RoundButton("−1") { m.changeBpm(m.bpm - 1) }
        Slider(
            value = m.bpm.toFloat(),
            onValueChange = { m.changeBpm(it.toDouble()) },
            valueRange = Tempo.MIN_BPM.toFloat()..Tempo.MAX_BPM.toFloat(),
            colors = SliderDefaults.colors(
                thumbColor = Palette.brass,
                activeTrackColor = Palette.brass,
                inactiveTrackColor = Palette.line,
            ),
            modifier = Modifier.weight(1f),
        )
        RoundButton("+1") { m.changeBpm(m.bpm + 1) }
        RoundButton("+5") { m.changeBpm(m.bpm + 5) }
    }
}

@Composable
private fun SignaturePicker(m: Metronome) {
    val sigs = Tempo.signatures
    Segmented(
        options = sigs.map { it.label },
        selected = sigs.indexOfFirst { it.beats == m.beatsPerBar }.coerceAtLeast(0),
        onSelect = { m.changeBeats(sigs[it].beats) },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun ActionButtons(m: Metronome) {
    val view = LocalView.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(
            Modifier
                .width(96.dp)
                .panel(shape = RoundedCornerShape(50))
                .clickable {
                    view.haptic()
                    m.tap()
                }
                .padding(vertical = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("Tap", style = Type.body(16.sp, FontWeight.Bold), color = Palette.fg)
        }
        Row(
            Modifier
                .weight(1f)
                .clip(RoundedCornerShape(50))
                .background(if (m.playing) Palette.off else Palette.brass)
                .clickable { m.toggle() }
                .padding(vertical = 16.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (m.playing) PIcons.stop else PIcons.play, null, tint = Palette.bg, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(if (m.playing) "Parar" else "Iniciar", style = Type.body(17.sp, FontWeight.Bold), color = Palette.bg)
        }
    }
}

@Composable
private fun BeatDots(m: Metronome) {
    Row(
        Modifier.height(40.dp).padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (i in 0 until m.beatsPerBar) {
            val on = m.currentBeat == i
            val accent = i == 0 || (m.beatsPerBar == 6 && i == 3)
            val scale by animateFloatAsState(if (on) 1.15f else 1f, tween(80), label = "batida")
            val fill = if (on) (if (i == 0) Palette.ok else Palette.brass) else Palette.panel
            Box(
                Modifier
                    .size(if (accent) 30.dp else 24.dp)
                    .scale(scale)
                    .clip(CircleShape)
                    .background(fill)
                    .border(if (accent) 2.dp else 1.dp, if (accent) Palette.brass else Palette.line, CircleShape),
            )
        }
    }
}

@Composable
private fun RoundButton(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(40.dp)
            .panel(shape = CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = Type.mono(13.sp, FontWeight.SemiBold), color = Palette.fg)
    }
}
