package com.pestana.estudio.chords

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.core.ChordBook
import com.pestana.estudio.core.ChordQuality
import com.pestana.estudio.core.Voicing
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.haptic
import com.pestana.estudio.ui.panel

@Composable
fun ChordsScreen(a4: Double) {
    val context = LocalContext.current
    val view = LocalView.current
    val prefs = remember { context.getSharedPreferences("pestana", Context.MODE_PRIVATE) }
    var root by remember { mutableIntStateOf(prefs.getInt("chordRoot", 0).coerceIn(0, 11)) }
    var qualityId by remember { mutableStateOf(prefs.getString("chordQuality", "maj") ?: "maj") }
    var voicingIndex by remember { mutableIntStateOf(0) }

    val player = remember { ChordPlayer(context) }
    DisposableEffect(Unit) { onDispose { player.release() } }

    val quality = ChordQuality.byId(qualityId)
    val voicings = remember(root, qualityId) { ChordBook.voicings(root, quality) }
    val current = voicings.getOrNull(voicingIndex.coerceAtMost(voicings.size - 1))

    val selectRoot: (Int) -> Unit = { r ->
        root = r
        voicingIndex = 0
        prefs.edit().putInt("chordRoot", r).apply()
    }
    val selectQuality: (String) -> Unit = { id ->
        qualityId = id
        voicingIndex = 0
        prefs.edit().putString("chordQuality", id).apply()
    }
    val next: (Int) -> Unit = { step ->
        val n = voicings.size
        if (n > 0) voicingIndex = (voicingIndex.coerceAtMost(n - 1) + step + n) % n
    }
    val strum: (Voicing) -> Unit = { v ->
        view.haptic()
        player.play(v, a4)
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.bg)) {
        val landscape = maxWidth > maxHeight
        if (landscape) {
            Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Title()
                    RootGrid(root, selectRoot)
                    QualityStrip(qualityId, selectQuality)
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 10.dp)) {
                    ChordCard(root, quality, current, voicingIndex, voicings.size, landscape = true, next, strum)
                }
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Title()
                RootGrid(root, selectRoot)
                QualityStrip(qualityId, selectQuality)
                ChordCard(root, quality, current, voicingIndex, voicings.size, landscape = false, next, strum)
            }
        }
    }
}

@Composable
private fun Title() {
    Text("Acordes", style = Type.serif(26.sp), color = Palette.fg)
}

@Composable
private fun RootGrid(root: Int, onSelect: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (row in 0 until 2) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (col in 0 until 6) {
                    val r = row * 6 + col
                    val selected = r == root
                    Box(
                        Modifier
                            .weight(1f)
                            .panel(radius = 12.dp, fill = if (selected) Palette.brass else Palette.panel)
                            .clickable { onSelect(r) }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            ChordBook.rootNames[r],
                            style = Type.serif(18.sp, FontWeight.Bold),
                            color = if (selected) Palette.bg else Palette.fg,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun QualityStrip(selectedId: String, onSelect: (String) -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ChordQuality.all.forEach { q ->
            val selected = q.id == selectedId
            Box(
                Modifier
                    .panel(
                        shape = RoundedCornerShape(50),
                        fill = if (selected) Palette.line else Palette.panel,
                        stroke = if (selected) Palette.brass else Palette.line,
                    )
                    .clickable { onSelect(q.id) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Text(
                    q.suffix.ifEmpty { "Maior" },
                    style = Type.body(14.sp, FontWeight.SemiBold),
                    color = if (selected) Palette.fg else Palette.muted,
                )
            }
        }
    }
}

@Composable
private fun ChordCard(
    root: Int,
    quality: ChordQuality,
    current: Voicing?,
    voicingIndex: Int,
    count: Int,
    landscape: Boolean,
    next: (Int) -> Unit,
    strum: (Voicing) -> Unit,
) {
    val currentState by rememberUpdatedState(current)
    val nextState by rememberUpdatedState(next)
    val strumState by rememberUpdatedState(strum)
    Column(
        Modifier.fillMaxWidth().panel().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                Text(ChordBook.name(root, quality), style = Type.serif(44.sp), color = Palette.fg, maxLines = 1)
                Text(
                    "${ChordBook.solfege[root]} ${quality.label.lowercase()}",
                    style = Type.body(14.sp),
                    color = Palette.muted,
                )
            }
            NotesView(root, quality)
        }

        if (current != null) {
            val measurer = rememberTextMeasurer()
            Canvas(
                Modifier
                    .fillMaxWidth()
                    .height(if (landscape) 200.dp else 260.dp)
                    .pointerInput(Unit) {
                        detectTapGestures(onTap = { currentState?.let(strumState) })
                    }
                    .pointerInput(Unit) {
                        var total = 0f
                        detectHorizontalDragGestures(
                            onDragStart = { total = 0f },
                            onDragEnd = {
                                if (total < -30.dp.toPx()) nextState(1)
                                if (total > 30.dp.toPx()) nextState(-1)
                            },
                        ) { _, dx -> total += dx }
                    },
            ) {
                drawChord(current, measurer)
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            ArrowButton(left = true) { next(-1) }
            Spacer(Modifier.weight(1f))
            Text(
                "Posição ${voicingIndex.coerceAtMost(count - 1) + 1} de $count",
                style = Type.mono(12.sp),
                color = Palette.muted,
            )
            Spacer(Modifier.weight(1f))
            ArrowButton(left = false) { next(1) }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(50))
                .background(Palette.brass)
                .clickable { current?.let(strum) }
                .padding(vertical = 14.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(PIcons.speaker, null, tint = Palette.bg, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(8.dp))
            Text("Tocar acorde", style = Type.body(16.sp, FontWeight.Bold), color = Palette.bg)
        }
    }
}

@Composable
private fun ArrowButton(left: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (left) PIcons.chevronLeft else PIcons.chevronRight,
            contentDescription = if (left) "Posição anterior" else "Próxima posição",
            tint = Palette.fg,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun NotesView(root: Int, quality: ChordQuality) {
    val names = ChordBook.notes(root, quality)
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        names.forEachIndexed { i, n ->
            Column(Modifier.widthIn(min = 26.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(n, style = Type.serif(15.sp, FontWeight.Bold), color = Palette.fg)
                Text(quality.degrees[i], style = Type.mono(10.sp), color = Palette.muted)
            }
        }
    }
}

/** Diagrama do braço: 5 casas, pestana, dedos (fundamental em verde), cordas soltas e abafadas. */
private fun DrawScope.drawChord(v: Voicing, measurer: TextMeasurer) {
    val base = if (v.highestFret <= 4) 1 else v.lowestFret
    val rows = 5
    val left = 44.dp.toPx()
    val right = 44.dp.toPx()
    val top = 34.dp.toPx()
    val bottom = 8.dp.toPx()
    val gridW = size.width - left - right
    val gridH = size.height - top - bottom
    val dx = gridW / 5
    val dy = gridH / rows

    // trastes
    for (r in 0..rows) {
        val y = top + r * dy
        val isNut = r == 0 && base == 1
        drawLine(
            if (isNut) Palette.fg else Palette.line,
            Offset(left, y),
            Offset(left + gridW, y),
            strokeWidth = if (isNut) 5.dp.toPx() else 1.5.dp.toPx(),
        )
    }
    // cordas (mais grossas no grave)
    for (s in 0 until 6) {
        val x = left + s * dx
        drawLine(Palette.muted, Offset(x, top), Offset(x, top + gridH), strokeWidth = (2.2f - s * 0.25f).dp.toPx())
    }
    // número da casa
    if (base > 1) {
        val t = measurer.measure("${base}ª", Type.mono(13.sp, FontWeight.SemiBold).copy(color = Palette.muted))
        drawText(t, topLeft = Offset(left - 22.dp.toPx() - t.size.width / 2f, top + dy / 2 - t.size.height / 2f))
    }

    val firstPlayed = v.frets.indexOfFirst { it >= 0 }.coerceAtLeast(0)
    // pestana
    v.barre?.let { b ->
        val lastAtBarre = v.frets.indexOfLast { it == b }.let { if (it < 0) firstPlayed else it }
        if (lastAtBarre > firstPlayed) {
            val y = top + ((b - base) + 0.5f) * dy
            val x1 = left + firstPlayed * dx
            val x2 = left + lastAtBarre * dx
            val h = 11.dp.toPx()
            drawRoundRect(
                Palette.brass,
                topLeft = Offset(x1 - h, y - h),
                size = Size(x2 - x1 + 2 * h, 2 * h),
                cornerRadius = CornerRadius(h, h),
            )
        }
    }

    // dedos, cordas soltas e abafadas
    for (s in 0 until 6) {
        val f = v.frets[s]
        val x = left + s * dx
        when {
            f < 0 -> {
                val t = measurer.measure("×", Type.body(18.sp, FontWeight.SemiBold).copy(color = Palette.muted))
                drawText(t, topLeft = Offset(x - t.size.width / 2f, top - 16.dp.toPx() - t.size.height / 2f))
            }
            f == 0 -> drawCircle(
                Palette.fg,
                radius = 7.dp.toPx(),
                center = Offset(x, top - 16.dp.toPx()),
                style = Stroke(width = 1.8.dp.toPx()),
            )
            f != v.barre -> {
                val y = top + ((f - base) + 0.5f) * dy
                val isRoot = s == v.frets.indexOfFirst { it >= 0 }
                drawCircle(if (isRoot) Palette.ok else Palette.brass, radius = 12.dp.toPx(), center = Offset(x, y))
            }
        }
    }
}
