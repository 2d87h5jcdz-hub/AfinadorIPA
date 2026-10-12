package com.pestana.estudio.studio

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.panel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

private val HEADER_W = 112.dp
private val LANE_H = 64.dp
private val RULER_H = 22.dp

@Composable
internal fun TracksSection(studio: StudioEngine) {
    val p = studio.project ?: return
    var pxPerSec by remember { mutableFloatStateOf(40f) } // dp por segundo
    var selected by remember { mutableStateOf<Pair<String, String>?>(null) } // (trackId, clipId)
    var editing by remember { mutableStateOf<String?>(null) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) studio.importAudioAsync(uri)
    }
    val stopped = studio.transport == Transport.STOPPED

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Faixas", style = Type.serif(20.sp), color = Palette.fg)
            Text("${p.tracks.size}", style = Type.mono(12.sp), color = Palette.muted)
            Spacer(Modifier.weight(1f))
            SIconButton(PIcons.toEnd, "Fim da faixa armada", size = 38.dp, fill = Palette.brass, tint = Palette.bg, stroke = Palette.brass,
                enabled = stopped && studio.armedTrackId != null) { studio.armedTrackId?.let { studio.seekToEnd(it) } }
            SIconButton(PIcons.zoomOut, "Menos zoom", size = 38.dp) { pxPerSec = (pxPerSec / 1.5f).coerceAtLeast(6f) }
            SIconButton(PIcons.zoomIn, "Mais zoom", size = 38.dp) { pxPerSec = (pxPerSec * 1.5f).coerceAtMost(400f) }
        }

        if (p.tracks.isEmpty()) {
            SCard {
                Text("Nenhuma faixa ainda", style = Type.body(15.sp, FontWeight.SemiBold), color = Palette.fg)
                Text(
                    "Toque no botão vermelho para gravar (a faixa é criada sozinha), ou importe um áudio para tocar junto.",
                    style = Type.body(13.sp),
                    color = Palette.muted,
                )
            }
        } else {
            Timeline(studio, p, pxPerSec, selected, onSelect = { selected = it }, onEdit = { editing = it })
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SPillButton("Nova faixa", PIcons.plus, filled = false, enabled = stopped) { studio.addEmptyTrack() }
            SPillButton("Importar áudio", PIcons.importFile, filled = false, enabled = stopped && studio.busy == null) {
                importer.launch(arrayOf("audio/*"))
            }
        }

        val sel = selected
        val selTrack = sel?.let { s -> p.tracks.firstOrNull { it.id == s.first } }
        val selClip = sel?.let { s -> selTrack?.clips?.firstOrNull { it.id == s.second } }
        if (selTrack != null && selClip != null) {
            SCard(padding = 12.dp) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Trecho de ${selTrack.name}", style = Type.body(14.sp, FontWeight.SemiBold), color = Palette.fg)
                        Text("${formatClock(selClip.offset)} – ${formatClock(selClip.end)}", style = Type.mono(11.sp), color = Palette.muted)
                    }
                    Box(Modifier.size(32.dp).clip(CircleShape).clickable { selected = null }, contentAlignment = Alignment.Center) {
                        Text("✕", color = Palette.muted)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SChip("Mover p/ cursor", enabled = stopped) { studio.moveClip(selClip.id, selTrack.id, studio.position) }
                    SChip("Fim da faixa", enabled = stopped) { studio.seekToEnd(selTrack.id) }
                    SChip("Apagar trecho", tint = Palette.off, enabled = stopped) {
                        studio.deleteClip(selClip.id, selTrack.id); selected = null
                    }
                }
                Text("Dica: arraste o trecho para o lado para mudá-lo de lugar.", style = Type.body(11.sp), color = Palette.muted)
            }
        }
    }
    editing?.let { id ->
        p.tracks.firstOrNull { it.id == id }?.let { t -> TrackSheet(studio, t) { editing = null } } ?: run { editing = null }
    }
}

@Composable
private fun Timeline(
    studio: StudioEngine,
    p: StudioProject,
    pxPerSec: Float,
    selected: Pair<String, String>?,
    onSelect: (Pair<String, String>?) -> Unit,
    onEdit: (String) -> Unit,
) {
    val density = LocalDensity.current
    val scroll = rememberScrollState()
    val seconds = max(p.duration, studio.position) + 30.0
    val widthDp = (seconds * pxPerSec).dp
    val pxPerSecPx = with(density) { pxPerSec.dp.toPx() }

    // Acompanha a cabeça de reprodução enquanto toca/grava.
    val pos by rememberUpdatedState(studio.position)
    LaunchedEffect(studio.transport, pxPerSec) {
        if (studio.transport == Transport.STOPPED) return@LaunchedEffect
        while (true) {
            val x = (pos * pxPerSecPx).toInt()
            val view = scroll.viewportSize
            if (view > 0 && (x < scroll.value || x > scroll.value + view * 0.85)) scroll.animateScrollTo((x - view * 0.15).toInt().coerceAtLeast(0))
            kotlinx.coroutines.delay(200)
        }
    }

    Row(Modifier.fillMaxWidth().panel(radius = 14.dp).padding(vertical = 4.dp)) {
        // Cabeçalhos das faixas
        Column(Modifier.width(HEADER_W)) {
            Box(Modifier.height(RULER_H).padding(start = 8.dp), contentAlignment = Alignment.CenterStart) {
                Text(formatClock(studio.position).let { it }, style = Type.mono(10.sp), color = Palette.muted)
            }
            p.tracks.forEach { t -> TrackHeader(studio, t, onEdit) }
        }
        Box(Modifier.width(1.dp).height(RULER_H + LANE_H * p.tracks.size).background(Palette.line))
        // Linha do tempo (rola na horizontal)
        Column(Modifier.weight(1f).horizontalScroll(scroll)) {
            Ruler(p, pxPerSec, widthDp, studio)
            p.tracks.forEach { t -> Lane(studio, p, t, pxPerSec, widthDp, selected, onSelect) }
        }
    }
}

@Composable
private fun TrackHeader(studio: StudioEngine, t: StudioTrack, onEdit: (String) -> Unit) {
    val armed = studio.armedTrackId == t.id
    val stopped = studio.transport == Transport.STOPPED
    Column(
        Modifier.width(HEADER_W).height(LANE_H).padding(horizontal = 6.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(22.dp)
                    .clip(CircleShape)
                    .border(2.dp, Palette.off, CircleShape)
                    .background(if (armed) Palette.off else Palette.bg)
                    .clickable(enabled = stopped) { studio.arm(t.id) },
            )
            Spacer(Modifier.width(6.dp))
            Text(
                t.name + " ›",
                style = Type.serif(13.sp, FontWeight.Bold),
                color = Palette.fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).clickable { onEdit(t.id) },
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            MiniToggle("M", t.isMuted, Palette.off) { studio.updateTrack(t.copy(isMuted = !t.isMuted)) }
            MiniToggle("S", t.isSolo, Palette.ok) { studio.updateTrack(t.copy(isSolo = !t.isSolo)) }
            if (t.hasEffects) MiniToggle("FX", t.effectsOn, Palette.brass) { studio.updateTrack(t.copy(effectsOn = !t.effectsOn)) }
            LevelBar(studio.trackLevels[t.id] ?: 0f, Modifier.weight(1f))
        }
    }
}

@Composable
private fun MiniToggle(title: String, on: Boolean, tint: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Box(
        Modifier
            .height(22.dp)
            .width(if (title.length > 1) 28.dp else 22.dp)
            .panel(radius = 5.dp, fill = if (on) tint.copy(alpha = 0.25f) else Palette.bg, stroke = if (on) tint else Palette.line)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = Type.mono(10.sp, FontWeight.Bold), color = if (on) tint else Palette.muted)
    }
}

@Composable
private fun Ruler(p: StudioProject, pxPerSec: Float, widthDp: androidx.compose.ui.unit.Dp, studio: StudioEngine) {
    val measurer = rememberTextMeasurer()
    val pos = studio.position
    Canvas(
        Modifier
            .width(widthDp)
            .height(RULER_H)
            .pointerInput(pxPerSec) {
                detectTapGestures { o -> studio.seek((o.x / pxPerSec.dp.toPx()).toDouble()) }
            },
    ) {
        val pps = pxPerSec.dp.toPx()
        val bar = 60.0 / max(20.0, p.bpm) * p.beatsPerBar
        // Mostra um número a cada N compassos, conforme o zoom.
        val every = generateSequence(1) { it * 2 }.first { it * bar * pps >= 36.dp.toPx() }
        var k = 0
        while (k * bar * pps < size.width) {
            val x = (k * bar * pps).toFloat()
            val major = k % every == 0
            drawLine(Palette.line, Offset(x, if (major) 4.dp.toPx() else size.height * 0.6f), Offset(x, size.height), 1.dp.toPx())
            if (major) {
                val l = measurer.measure("${k + 1}", Type.mono(10.sp).copy(color = Palette.muted))
                drawText(l, topLeft = Offset(x + 3.dp.toPx(), 2.dp.toPx()))
            }
            k++
        }
        val px = (pos * pps).toFloat()
        drawLine(Palette.brass, Offset(px, 0f), Offset(px, size.height), 2.dp.toPx())
    }
}

@Composable
private fun Lane(
    studio: StudioEngine,
    p: StudioProject,
    t: StudioTrack,
    pxPerSec: Float,
    widthDp: androidx.compose.ui.unit.Dp,
    selected: Pair<String, String>?,
    onSelect: (Pair<String, String>?) -> Unit,
) {
    // Picos da forma de onda de cada arquivo (calculados fora da thread principal).
    val peaks by produceState(initialValue = emptyMap<String, FloatArray>(), t.clips.map { it.fileName }) {
        value = withContext(Dispatchers.IO) {
            t.clips.map { it.fileName }.distinct().associateWith { Waveforms.compute(studio.store.file(p.id, it)) }
        }
    }
    var dragClip by remember { mutableStateOf<String?>(null) }
    var dragDx by remember { mutableFloatStateOf(0f) }
    val stopped = studio.transport == Transport.STOPPED
    val clips by rememberUpdatedState(t.clips)
    val recStart = studio.recordingStart
    val recording = studio.armedTrackId == t.id && recStart != null && studio.transport == Transport.RECORDING

    Canvas(
        Modifier
            .width(widthDp)
            .height(LANE_H)
            .pointerInput(pxPerSec, t.id) {
                detectTapGestures { o ->
                    val sec = o.x / pxPerSec.dp.toPx()
                    val hit = clips.firstOrNull { sec >= it.offset && sec <= it.end }
                    if (hit != null) onSelect(t.id to hit.id) else { onSelect(null); studio.seek(sec.toDouble()) }
                }
            }
            .pointerInput(pxPerSec, t.id, stopped) {
                if (!stopped) return@pointerInput
                detectDragGestures(
                    onDragStart = { o ->
                        val sec = o.x / pxPerSec.dp.toPx()
                        dragClip = clips.firstOrNull { sec >= it.offset && sec <= it.end }?.id
                        dragDx = 0f
                        dragClip?.let { onSelect(t.id to it) }
                    },
                    onDragEnd = {
                        val id = dragClip
                        if (id != null) {
                            val c = clips.firstOrNull { it.id == id }
                            if (c != null) studio.moveClip(id, t.id, c.offset + dragDx / pxPerSec.dp.toPx())
                        }
                        dragClip = null; dragDx = 0f
                    },
                    onDragCancel = { dragClip = null; dragDx = 0f },
                ) { change, amount ->
                    if (dragClip != null) { change.consume(); dragDx += amount.x }
                }
            },
    ) {
        val pps = pxPerSec.dp.toPx()
        // grade de compassos
        val bar = 60.0 / max(20.0, p.bpm) * p.beatsPerBar
        var k = 0
        while (k * bar * pps < size.width) {
            val x = (k * bar * pps).toFloat()
            drawLine(Palette.line.copy(alpha = 0.5f), Offset(x, 0f), Offset(x, size.height), 1f)
            k++
        }
        drawLine(Palette.line, Offset(0f, size.height - 1), Offset(size.width, size.height - 1), 1f)
        val armed = studio.armedTrackId == t.id
        for (c in t.clips) {
            val dx = if (c.id == dragClip) dragDx else 0f
            val x0 = (c.offset * pps).toFloat() + dx
            val w = (c.duration * pps).toFloat().coerceAtLeast(2f)
            val top = 6.dp.toPx()
            val h = size.height - 12.dp.toPx()
            val sel = selected?.second == c.id
            drawRoundRect(
                if (armed) Palette.brass.copy(alpha = 0.18f) else Palette.line.copy(alpha = 0.55f),
                topLeft = Offset(x0, top), size = Size(w, h), cornerRadius = CornerRadius(5.dp.toPx()),
            )
            val pk = peaks[c.fileName]
            if (pk != null && pk.isNotEmpty()) {
                val mid = top + h / 2
                val step = 2.dp.toPx()
                var x = 0f
                val col = if (armed) Palette.brass else Palette.muted
                while (x < w) {
                    val sec = c.fileStart + x / pps
                    val i = (sec * STUDIO_RATE / Waveforms.FRAMES).toInt()
                    val v = if (i in pk.indices) pk[i] else 0f
                    val a = (v * h * 0.48f).coerceAtLeast(0.5f)
                    drawLine(col, Offset(x0 + x, mid - a), Offset(x0 + x, mid + a), 1.4.dp.toPx())
                    x += step
                }
            }
            drawRoundRect(
                if (sel) Palette.fg else if (armed) Palette.brass else Palette.line,
                topLeft = Offset(x0, top), size = Size(w, h), cornerRadius = CornerRadius(5.dp.toPx()),
                style = Stroke(if (sel) 2.dp.toPx() else 1.dp.toPx()),
            )
        }
        // Gravação ao vivo
        if (recording) {
            val x0 = ((recStart ?: 0.0) * pps).toFloat()
            val x1 = (studio.position * pps).toFloat()
            drawRoundRect(
                Palette.off.copy(alpha = 0.35f), topLeft = Offset(x0, 6.dp.toPx()),
                size = Size((x1 - x0).coerceAtLeast(2f), size.height - 12.dp.toPx()), cornerRadius = CornerRadius(5.dp.toPx()),
            )
        }
        val px = (studio.position * pps).toFloat()
        drawLine(Palette.brass, Offset(px, 0f), Offset(px, size.height), 2.dp.toPx())
    }
}
