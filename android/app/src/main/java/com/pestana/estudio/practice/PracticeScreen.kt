package com.pestana.estudio.practice

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.panel
import kotlin.math.abs
import kotlin.math.roundToInt

@Composable
fun PracticeScreen(engine: PracticeEngine) {
    // Sai da aba ou o app vai para segundo plano: pausa.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_STOP) engine.deactivate() }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(obs)
            engine.deactivate()
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) engine.importSong(uri)
    }

    Box(Modifier.fillMaxSize().background(Palette.bg)) {
        if (engine.current != null) {
            BackHandler { engine.close() }
            PlayerScreen(engine)
        } else {
            LibraryScreen(engine) { picker.launch(arrayOf("audio/*")) }
        }
    }

    engine.lastError?.let { msg ->
        AlertDialog(
            onDismissRequest = { engine.lastError = null },
            confirmButton = { TextButton(onClick = { engine.lastError = null }) { Text("OK", color = Palette.brass) } },
            title = { Text("Treino", style = Type.serif(20.sp, FontWeight.Bold)) },
            text = { Text(msg, style = Type.body(15.sp)) },
            containerColor = Palette.panel,
            titleContentColor = Palette.fg,
            textContentColor = Palette.fg,
        )
    }
}

// MARK: estilo

@Composable
private fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth().panel(radius = 16.dp).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

@Composable
private fun SectionTitle(text: String) {
    Text(text.uppercase(), style = Type.mono(11.sp, FontWeight.SemiBold), color = Palette.muted)
}

@Composable
private fun Chip(title: String, selected: Boolean = false, tint: Color = Palette.brass, onClick: () -> Unit) {
    Box(
        Modifier
            .panel(
                radius = 10.dp,
                fill = if (selected) tint.copy(alpha = 0.22f) else Palette.bg,
                stroke = if (selected) tint else Palette.line,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Text(title, style = Type.body(13.sp, FontWeight.SemiBold), color = if (selected) tint else Palette.fg)
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, size: Dp, enabled: Boolean = true, label: String? = null, onClick: () -> Unit) {
    Box(
        Modifier
            .size(size)
            .alpha(if (enabled) 1f else 0.4f)
            .panel(shape = CircleShape, fill = Palette.bg)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Palette.fg, modifier = Modifier.size(size * 0.46f))
    }
}

@Composable
private fun BrassButton(text: String, icon: ImageVector?, busy: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.5f)
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.brass)
            .clickable(enabled = enabled && !busy, onClick = onClick)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) {
            CircularProgressIndicator(color = Palette.bg, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        } else if (icon != null) {
            Icon(icon, null, tint = Palette.bg, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(10.dp))
        Text(text, style = Type.body(16.sp, FontWeight.SemiBold), color = Palette.bg)
    }
}

@Composable
private fun sliderColors() = SliderDefaults.colors(
    thumbColor = Palette.brass,
    activeTrackColor = Palette.brass,
    inactiveTrackColor = Palette.line,
)

// MARK: biblioteca

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LibraryScreen(engine: PracticeEngine, onImport: () -> Unit) {
    var renaming by remember { mutableStateOf<PracticeSong?>(null) }
    var deleting by remember { mutableStateOf<PracticeSong?>(null) }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = Palette.fg)) { append("Trei") }
                    withStyle(SpanStyle(color = Palette.brass)) { append("no") }
                },
                style = Type.serif(26.sp),
            )
            Text(
                "Toque junto com suas músicas: mude o tom, a velocidade, repita um trecho e tire um instrumento com IA.",
                style = Type.body(13.sp),
                color = Palette.muted,
            )
        }
        val importing = engine.busy == "Importando…"
        BrassButton(
            if (importing) "Importando…" else "Importar música (MP3, M4A, WAV)",
            PIcons.importFile,
            busy = importing,
            onClick = onImport,
        )
        if (engine.library.isEmpty()) {
            Card {
                Icon(PIcons.practice, null, tint = Palette.brass, modifier = Modifier.size(28.dp))
                Text("Nenhuma música ainda", style = Type.body(16.sp, FontWeight.SemiBold), color = Palette.fg)
                Text(
                    "Toque em Importar e escolha um arquivo de áudio do celular (Downloads, Drive, WhatsApp…).",
                    style = Type.body(13.sp),
                    color = Palette.muted,
                )
            }
        } else {
            SectionTitle("Suas músicas")
            engine.library.forEach { song ->
                var menu by remember(song.id) { mutableStateOf(false) }
                Box {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .panel(radius = 16.dp)
                            .combinedClickable(onClick = { engine.open(song) }, onLongClick = { menu = true })
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(
                            if (song.hasStems) PIcons.waveform else PIcons.note,
                            null,
                            tint = Palette.brass,
                            modifier = Modifier.size(22.dp),
                        )
                        Column(Modifier.weight(1f)) {
                            Text(
                                song.title,
                                style = Type.body(16.sp, FontWeight.SemiBold),
                                color = Palette.fg,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(subtitle(song), style = Type.mono(12.sp), color = Palette.muted)
                        }
                        Box(
                            Modifier.size(32.dp).clip(CircleShape).clickable { menu = true },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text("⋮", style = Type.body(20.sp, FontWeight.Bold), color = Palette.muted)
                        }
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Renomear") }, onClick = { menu = false; renaming = song })
                        DropdownMenuItem(
                            text = { Text("Apagar", color = Palette.off) },
                            onClick = { menu = false; deleting = song },
                        )
                    }
                }
            }
            Text("Segure uma música para renomear ou apagar.", style = Type.body(12.sp), color = Palette.muted)
        }
    }

    renaming?.let { song ->
        var text by remember(song.id) { mutableStateOf(song.title) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Renomear", style = Type.serif(20.sp, FontWeight.Bold)) },
            text = {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Palette.brass,
                        unfocusedBorderColor = Palette.line,
                        cursorColor = Palette.brass,
                        focusedTextColor = Palette.fg,
                        unfocusedTextColor = Palette.fg,
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = { engine.rename(song, text); renaming = null }) { Text("Salvar", color = Palette.brass) }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancelar", color = Palette.muted) } },
            containerColor = Palette.panel,
            titleContentColor = Palette.fg,
        )
    }
    deleting?.let { song ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Apagar música?", style = Type.serif(20.sp, FontWeight.Bold)) },
            text = { Text("\"${song.title}\" e os instrumentos separados serão apagados do celular.", style = Type.body(15.sp)) },
            confirmButton = {
                TextButton(onClick = { engine.delete(song); deleting = null }) { Text("Apagar", color = Palette.off) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancelar", color = Palette.muted) } },
            containerColor = Palette.panel,
            titleContentColor = Palette.fg,
            textContentColor = Palette.fg,
        )
    }
}

private fun subtitle(song: PracticeSong): String {
    val parts = mutableListOf(PracticeNotes.time(song.duration))
    if (song.hasStems) parts += "separada"
    if (song.semitones != 0) parts += PracticeNotes.intervalText(song.semitones)
    if (song.speed != 1.0) parts += "${(song.speed * 100).roundToInt()}%"
    return parts.joinToString(" · ")
}

// MARK: player

@Composable
private fun PlayerScreen(engine: PracticeEngine) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val landscape = maxWidth > maxHeight
        if (landscape) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Header(engine)
                    PlayerCard(engine)
                    LoopCard(engine)
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    PitchCard(engine)
                    SpeedCard(engine)
                    StemsCard(engine)
                }
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Header(engine)
                PlayerCard(engine)
                LoopCard(engine)
                PitchCard(engine)
                SpeedCard(engine)
                StemsCard(engine)
            }
        }
    }
}

@Composable
private fun Header(engine: PracticeEngine) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            Modifier.size(38.dp).panel(shape = CircleShape).clickable { engine.close() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(PIcons.chevronLeft, "Voltar à biblioteca", tint = Palette.fg, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                engine.current?.title ?: "",
                style = Type.serif(20.sp),
                color = Palette.fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                if (engine.useStems) "INSTRUMENTOS SEPARADOS" else "MÚSICA ORIGINAL",
                style = Type.mono(11.sp, FontWeight.Medium),
                color = if (engine.useStems) Palette.ok else Palette.muted,
            )
        }
        if (engine.busy != null) {
            CircularProgressIndicator(color = Palette.brass, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun PlayerCard(engine: PracticeEngine) {
    Card {
        Scrubber(engine)
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RoundIcon(PIcons.back5, 50.dp, label = "Voltar 5 segundos") { engine.skip(-5.0) }
            Box(
                Modifier
                    .size(76.dp)
                    .clip(CircleShape)
                    .background(Palette.brass)
                    .clickable(enabled = engine.busy == null) { engine.togglePlay() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (engine.isPlaying) PIcons.pause else PIcons.play,
                    if (engine.isPlaying) "Pausar" else "Tocar",
                    tint = Palette.bg,
                    modifier = Modifier.size(34.dp),
                )
            }
            RoundIcon(PIcons.forward5, 50.dp, label = "Avançar 5 segundos") { engine.skip(5.0) }
        }
    }
}

@Composable
private fun Scrubber(engine: PracticeEngine) {
    var drag by remember { mutableStateOf<Float?>(null) }
    val upper = engine.duration.coerceAtLeast(0.1).toFloat()
    val shown = (drag ?: engine.position.toFloat()).coerceIn(0f, upper)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Box(contentAlignment = Alignment.Center) {
            // faixa do loop A-B atrás do slider
            val a = engine.loopA
            val b = engine.loopB
            if (a != null) {
                Canvas(Modifier.fillMaxWidth().height(20.dp)) {
                    val inset = 10.dp.toPx()
                    val w = size.width - 2 * inset
                    val x0 = inset + w * (a / upper).toFloat()
                    val x1 = b?.let { inset + w * (it / upper).toFloat() } ?: (x0 + 2.dp.toPx())
                    drawRoundRect(
                        Palette.brass.copy(alpha = 0.28f),
                        topLeft = Offset(x0, 0f),
                        size = Size((x1 - x0).coerceAtLeast(2f), size.height),
                        cornerRadius = CornerRadius(3.dp.toPx()),
                    )
                }
            }
            Slider(
                value = shown,
                onValueChange = { drag = it },
                onValueChangeFinished = {
                    drag?.let { engine.seek(it.toDouble()) }
                    drag = null
                },
                valueRange = 0f..upper,
                colors = sliderColors(),
            )
        }
        Row {
            Text(PracticeNotes.time(shown.toDouble()), style = Type.mono(12.sp), color = Palette.muted)
            Spacer(Modifier.weight(1f))
            Text("-" + PracticeNotes.time((upper - shown).toDouble()), style = Type.mono(12.sp), color = Palette.muted)
        }
    }
}

@Composable
private fun LoopCard(engine: PracticeEngine) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("Repetir trecho (A-B)")
            Spacer(Modifier.weight(1f))
            val a = engine.loopA
            val b = engine.loopB
            val status = when {
                a != null && b != null -> "${PracticeNotes.time(a)} → ${PracticeNotes.time(b)}"
                a != null -> "A ${PracticeNotes.time(a)} · marque o B"
                else -> "desligado"
            }
            Text(status, style = Type.mono(12.sp), color = if (engine.loopActive) Palette.ok else Palette.muted)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Chip("A", selected = engine.loopA != null) { engine.setLoopA() }
            Chip("B", selected = engine.loopB != null) { engine.setLoopB() }
            Chip("Limpar") { engine.clearLoop() }
            Spacer(Modifier.weight(1f))
            engine.loopA?.let { a ->
                Box(Modifier.size(36.dp).clip(CircleShape).clickable { engine.seek(a) }, contentAlignment = Alignment.Center) {
                    Icon(PIcons.loopBack, "Voltar ao A", tint = Palette.brass, modifier = Modifier.size(22.dp))
                }
            }
        }
    }
}

@Composable
private fun PitchCard(engine: PracticeEngine) {
    var keyMenu by remember { mutableStateOf(false) }
    val st = engine.semitones
    val key = engine.current?.originalKey
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("Tom")
            Spacer(Modifier.weight(1f))
            Box {
                Text(
                    "Tom original: ${key?.let { PracticeNotes.name(it) } ?: "?"}",
                    style = Type.body(12.sp, FontWeight.SemiBold),
                    color = Palette.brass,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { keyMenu = true }.padding(4.dp),
                )
                DropdownMenu(expanded = keyMenu, onDismissRequest = { keyMenu = false }) {
                    DropdownMenuItem(text = { Text("Não sei") }, onClick = { engine.setOriginalKey(null); keyMenu = false })
                    for (k in 0 until 12) {
                        DropdownMenuItem(
                            text = { Text(PracticeNotes.name(k)) },
                            onClick = { engine.setOriginalKey(k); keyMenu = false },
                        )
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            RoundIcon(PIcons.minus, 46.dp, enabled = st - 1 in PracticeEngine.SEMITONES, label = "Meio tom abaixo") {
                engine.changeSemitones(st - 1)
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(PracticeNotes.intervalText(st), style = Type.body(18.sp, FontWeight.Bold), color = Palette.fg)
                val line = if (key != null) {
                    if (st == 0) "Tom: ${PracticeNotes.name(key)}" else "${PracticeNotes.name(key)} → ${PracticeNotes.transposed(key, st)}"
                } else {
                    if (st == 0) "Sem mudança" else "Ex.: um acorde de C vira ${PracticeNotes.transposed(0, st)}"
                }
                Text(line, style = Type.body(13.sp), color = Palette.muted)
            }
            RoundIcon(PIcons.plus, 46.dp, enabled = st + 1 in PracticeEngine.SEMITONES, label = "Meio tom acima") {
                engine.changeSemitones(st + 1)
            }
        }
    }
}

@Composable
private fun SpeedCard(engine: PracticeEngine) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("Velocidade")
            Spacer(Modifier.weight(1f))
            Text("${(engine.speed * 100).roundToInt()}%", style = Type.mono(16.sp, FontWeight.Bold), color = Palette.fg)
        }
        Slider(
            value = engine.speed.toFloat(),
            onValueChange = { engine.changeSpeed(it.toDouble()) },
            valueRange = PracticeEngine.SPEED_MIN.toFloat()..PracticeEngine.SPEED_MAX.toFloat(),
            colors = sliderColors(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (p in listOf(0.5, 0.75, 0.9, 1.0)) {
                Chip("${(p * 100).roundToInt()}%", selected = abs(engine.speed - p) < 0.005) { engine.changeSpeed(p) }
            }
        }
    }
}

// MARK: instrumentos (IA)

@Composable
private fun StemsCard(engine: PracticeEngine) {
    Card {
        SectionTitle("Instrumentos")
        if (engine.current?.hasStems == true) Mixer(engine) else SeparatePanel(engine)
    }
}

@Composable
private fun SeparatePanel(engine: PracticeEngine) {
    var askDownload by remember { mutableStateOf(false) }
    if (engine.separating) {
        val p = engine.separationProgress.toFloat().coerceIn(0f, 1f)
        LinearProgressIndicator(
            progress = { p },
            modifier = Modifier.fillMaxWidth(),
            color = Palette.brass,
            trackColor = Palette.line,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "${engine.separationStage} ${(p * 100).roundToInt()}%",
                style = Type.body(14.sp, FontWeight.SemiBold),
                color = Palette.fg,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { engine.cancelSeparation() }) { Text("Cancelar", color = Palette.off) }
        }
        Text(
            "Leva alguns minutos (a IA roda no próprio celular). Deixe o app aberto — a tela fica acesa.",
            style = Type.body(12.sp),
            color = Palette.muted,
        )
        return
    }
    BrassButton("Separar instrumentos (IA)", PIcons.sparkle, enabled = engine.busy == null) {
        if (engine.modelReady) engine.separateCurrent() else askDownload = true
    }
    Text(
        "Separa em: Voz, Bateria, Baixo, Violão/Guitarra, Piano e Outros. Depois dá para tirar o violão e tocar por cima, ou tirar a voz e cantar.",
        style = Type.body(12.sp),
        color = Palette.muted,
    )
    if (askDownload) {
        AlertDialog(
            onDismissRequest = { askDownload = false },
            title = { Text("Baixar o modelo de IA?", style = Type.serif(20.sp, FontWeight.Bold)) },
            text = {
                Text(
                    "Na primeira vez o app baixa o separador (cerca de ${ModelStore.APPROX_MB} MB). Prefira o Wi-Fi. " +
                        "Depois disso tudo funciona sem internet, no próprio celular.",
                    style = Type.body(15.sp),
                )
            },
            confirmButton = {
                TextButton(onClick = { askDownload = false; engine.separateCurrent() }) { Text("Baixar e separar", color = Palette.brass) }
            },
            dismissButton = { TextButton(onClick = { askDownload = false }) { Text("Agora não", color = Palette.muted) } },
            containerColor = Palette.panel,
            titleContentColor = Palette.fg,
            textContentColor = Palette.fg,
        )
    }
}

@Composable
private fun Mixer(engine: PracticeEngine) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Usar instrumentos separados", style = Type.body(15.sp, FontWeight.SemiBold), color = Palette.fg, modifier = Modifier.weight(1f))
        Switch(
            checked = engine.useStems,
            onCheckedChange = { engine.changeUseStems(it) },
            enabled = engine.busy == null,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.bg,
                checkedTrackColor = Palette.brass,
                uncheckedThumbColor = Palette.muted,
                uncheckedTrackColor = Palette.bg,
                uncheckedBorderColor = Palette.line,
            ),
        )
    }
    if (engine.useStems) {
        val stems = engine.availableStems
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (StemKind.GUITAR in stems) Chip("Sem violão") { engine.removeOnly(StemKind.GUITAR) }
            if (StemKind.VOCALS in stems) Chip("Karaokê") { engine.removeOnly(StemKind.VOCALS) }
            Chip("Tudo") { engine.resetMix() }
        }
        stems.forEach { kind -> StemRow(engine, kind) }
        if (StemKind.GUITAR !in stems) {
            Text("Este modelo não separa o violão: ele fica em \"Outros\".", style = Type.body(12.sp), color = Palette.muted)
        }
    }
    Row(
        Modifier.clip(RoundedCornerShape(8.dp)).clickable { engine.deleteStems() }.padding(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(PIcons.trash, null, tint = Palette.off, modifier = Modifier.size(16.dp))
        Text("Apagar separação", style = Type.body(13.sp), color = Palette.off)
    }
}

@Composable
private fun StemRow(engine: PracticeEngine, kind: StemKind) {
    val st = engine.stemMix[kind] ?: StemMix()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            kind.title,
            style = Type.body(14.sp, FontWeight.SemiBold),
            color = if (engine.isAudible(kind)) Palette.fg else Palette.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(96.dp),
        )
        Toggle("M", st.muted, Palette.off) { engine.toggleMute(kind) }
        Toggle("S", st.solo, Palette.ok) { engine.toggleSolo(kind) }
        Slider(
            value = st.volume,
            onValueChange = { engine.setStemVolume(kind, it) },
            valueRange = 0f..1.5f,
            colors = sliderColors(),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun Toggle(title: String, on: Boolean, tint: Color, onClick: () -> Unit) {
    Box(
        Modifier
            .size(width = 32.dp, height = 30.dp)
            .panel(radius = 8.dp, fill = if (on) tint.copy(alpha = 0.25f) else Palette.bg, stroke = if (on) tint else Palette.line)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = Type.mono(13.sp, FontWeight.Bold), color = if (on) tint else Palette.muted)
    }
}
