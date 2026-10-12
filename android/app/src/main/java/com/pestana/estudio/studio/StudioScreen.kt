package com.pestana.estudio.studio

import android.Manifest
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Segmented
import com.pestana.estudio.ui.StepButton
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.panel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun StudioScreen(studio: StudioEngine) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_RESUME -> studio.activate()
                Lifecycle.Event.ON_PAUSE -> studio.deactivate()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(obs)
            studio.deactivate()
        }
    }

    var pendingRecord by remember { mutableStateOf(false) }
    val micLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) {
            studio.micGranted()
            if (pendingRecord) studio.record()
        } else {
            studio.lastError = "Sem o microfone não dá para gravar. Libere em Configurações › Apps › Pestana › Permissões."
        }
        pendingRecord = false
    }
    val record = {
        if (studio.hasMicPermission()) studio.record() else {
            pendingRecord = true
            micLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    val askMic = { if (!studio.hasMicPermission()) micLauncher.launch(Manifest.permission.RECORD_AUDIO) }

    Box(Modifier.fillMaxSize().background(Palette.bg)) {
        if (studio.project != null) {
            BackHandler { studio.closeProject() }
            ProjectScreen(studio, onRecord = record, askMic = askMic, share = { file ->
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = if (file.name.endsWith(".wav")) "audio/wav" else "audio/mp4"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(Intent.createChooser(intent, "Compartilhar mixagem"))
            })
        } else {
            ProjectList(studio)
        }
    }

    studio.lastError?.let { msg ->
        AlertDialog(
            onDismissRequest = { studio.lastError = null },
            confirmButton = { TextButton(onClick = { studio.lastError = null }) { Text("OK", color = Palette.brass) } },
            title = { Text("Estúdio", style = Type.serif(20.sp, FontWeight.Bold)) },
            text = { Text(msg, style = Type.body(15.sp)) },
            containerColor = Palette.panel,
            titleContentColor = Palette.fg,
            textContentColor = Palette.fg,
        )
    }
}

// MARK: lista de músicas

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectList(studio: StudioEngine) {
    var renaming by remember { mutableStateOf<StudioProject?>(null) }
    var deleting by remember { mutableStateOf<StudioProject?>(null) }
    var creating by remember { mutableStateOf(false) }
    val fmt = remember { SimpleDateFormat("d MMM yyyy, HH:mm", Locale.forLanguageTag("pt-BR")) }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Estúdio", style = Type.serif(26.sp), color = Palette.fg, modifier = Modifier.weight(1f))
            SPillButton("Nova música", PIcons.plus, filled = true) { creating = true }
        }
        if (!studio.available) {
            SCard { Text("O motor de áudio do Estúdio não carregou neste aparelho.", style = Type.body(14.sp), color = Palette.off) }
        }
        if (studio.projects.isEmpty()) {
            SCard {
                Icon(PIcons.waveform, null, tint = Palette.brass, modifier = Modifier.size(28.dp))
                Text("Grave em camadas", style = Type.serif(18.sp, FontWeight.Bold), color = Palette.fg)
                Text(
                    "Grave o violão, depois ouça essa faixa enquanto grava a voz por cima, depois um solo… " +
                        "Cada gravação vira uma camada que você mixa do seu jeito.",
                    style = Type.body(13.sp),
                    color = Palette.muted,
                )
                listOf(
                    "1" to "Crie uma música e escolha o BPM — o clique ajuda a manter o tempo.",
                    "2" to "Toque em gravar. As faixas que já existem tocam enquanto você grava a próxima.",
                    "3" to "Ajuste volume, pan e efeitos de cada faixa.",
                    "4" to "Exporte e mande pelo WhatsApp ou salve no celular.",
                ).forEach { (n, t) ->
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(Modifier.size(22.dp).panel(shape = CircleShape, fill = Palette.bg, stroke = Palette.brass), contentAlignment = Alignment.Center) {
                            Text(n, style = Type.mono(11.sp, FontWeight.Bold), color = Palette.brass)
                        }
                        Text(t, style = Type.body(13.sp), color = Palette.fg)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(PIcons.headphones, null, tint = Palette.brass, modifier = Modifier.size(18.dp))
                    Text("Use fone de ouvido: assim o som das outras faixas não vaza para a nova gravação.", style = Type.body(12.sp), color = Palette.muted)
                }
                SPillButton("Criar primeira música", PIcons.plus, filled = true) { creating = true }
            }
        }
        studio.projects.forEach { p ->
            var menu by remember(p.id) { mutableStateOf(false) }
            Box {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .panel(radius = 16.dp)
                        .combinedClickable(onClick = { studio.open(p.id) }, onLongClick = { menu = true })
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(PIcons.waveform, null, tint = Palette.brass, modifier = Modifier.size(22.dp))
                    Column(Modifier.weight(1f)) {
                        Text(p.name, style = Type.serif(17.sp, FontWeight.Bold), color = Palette.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            "${p.tracks.size} ${if (p.tracks.size == 1) "faixa" else "faixas"} · ${p.bpm.toInt()} BPM · ${fmt.format(Date(p.updatedAt))}",
                            style = Type.mono(11.sp),
                            color = Palette.muted,
                        )
                    }
                    Box(Modifier.size(32.dp).clip(CircleShape).clickable { menu = true }, contentAlignment = Alignment.Center) {
                        Text("⋮", style = Type.body(20.sp, FontWeight.Bold), color = Palette.muted)
                    }
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Renomear") }, onClick = { menu = false; renaming = p })
                    DropdownMenuItem(text = { Text("Apagar", color = Palette.off) }, onClick = { menu = false; deleting = p })
                }
            }
        }
    }
    renaming?.let { p -> NameDialog("Renomear música", p.name, { renaming = null }) { studio.rename(p.id, it); renaming = null } }
    if (creating) {
        NameDialog("Nova música", "Música ${studio.projects.size + 1}", { creating = false }, action = "Criar",
            hint = "Dê um nome para o projeto. Dá para mudar depois.") {
            creating = false
            studio.newProject(it.trim())
        }
    }
    deleting?.let { p ->
        ConfirmDialog("Apagar música?", "\"${p.name}\" e todas as gravações serão apagadas do celular.", "Apagar", { deleting = null }) {
            studio.deleteProject(p.id); deleting = null
        }
    }
}

@Composable
internal fun NameDialog(
    title: String,
    initial: String,
    onDismiss: () -> Unit,
    action: String = "Salvar",
    hint: String? = null,
    onSave: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = Type.serif(20.sp, FontWeight.Bold)) },
        text = {
          Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (hint != null) Text(hint, style = Type.body(14.sp), color = Palette.muted)
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Palette.brass, unfocusedBorderColor = Palette.line, cursorColor = Palette.brass,
                    focusedTextColor = Palette.fg, unfocusedTextColor = Palette.fg,
                ),
            )
          }
        },
        confirmButton = { TextButton(onClick = { onSave(text) }) { Text(action, color = Palette.brass) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancelar", color = Palette.muted) } },
        containerColor = Palette.panel,
        titleContentColor = Palette.fg,
    )
}

@Composable
internal fun ConfirmDialog(title: String, text: String, action: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = Type.serif(20.sp, FontWeight.Bold)) },
        text = { Text(text, style = Type.body(15.sp)) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(action, color = Palette.off) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancelar", color = Palette.muted) } },
        containerColor = Palette.panel,
        titleContentColor = Palette.fg,
        textContentColor = Palette.fg,
    )
}

// MARK: projeto aberto

@Composable
private fun ProjectScreen(studio: StudioEngine, onRecord: () -> Unit, askMic: () -> Unit, share: (java.io.File) -> Unit) {
    val p = studio.project ?: return
    var renaming by remember { mutableStateOf(false) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val landscape = maxWidth > maxHeight
        val leftWidth = maxWidth * 0.36f
        if (landscape) {
            Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(
                    Modifier.width(leftWidth).verticalScroll(rememberScrollState()).padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    TopBar(studio, share)
                    Title(p.name) { renaming = true }
                    TransportBar(studio, onRecord)
                    SettingsCard(studio)
                    InputCard(studio, askMic)
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
                    TracksSection(studio)
                }
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    TopBar(studio, share)
                    Title(p.name) { renaming = true }
                    SettingsCard(studio)
                    InputCard(studio, askMic)
                    TracksSection(studio)
                }
                val armed = studio.transport == Transport.RECORDING || studio.transport == Transport.COUNT_IN
                Box(Modifier.fillMaxWidth().height(1.dp).background(if (armed) Palette.off else Palette.line))
                Box(Modifier.fillMaxWidth().background(Palette.panel).padding(horizontal = 16.dp, vertical = 10.dp)) {
                    TransportBar(studio, onRecord)
                }
            }
        }
    }
    if (renaming) NameDialog("Renomear música", p.name, { renaming = false }) { studio.rename(p.id, it); renaming = false }
}

@Composable
private fun TopBar(studio: StudioEngine, share: (java.io.File) -> Unit) {
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.clip(RoundedCornerShape(10.dp)).clickable { studio.closeProject() }.padding(vertical = 6.dp, horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(PIcons.chevronLeft, null, tint = Palette.brass, modifier = Modifier.size(20.dp))
            Text("Músicas", style = Type.body(16.sp), color = Palette.brass)
        }
        Spacer(Modifier.weight(1f))
        if (studio.busy != null) {
            CircularProgressIndicator(color = Palette.brass, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(studio.busy ?: "", style = Type.mono(11.sp), color = Palette.muted)
            Spacer(Modifier.width(10.dp))
        }
        Box {
            SPillButton("Exportar", PIcons.share, filled = true, enabled = studio.busy == null) { menu = true }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Column { Text("M4A"); Text("leve, bom para WhatsApp", style = Type.body(12.sp), color = Palette.muted) } },
                    onClick = { menu = false; scope.launch { studio.exportMix(wav = false)?.let(share) } },
                )
                DropdownMenuItem(
                    text = { Column { Text("WAV"); Text("sem perdas", style = Type.body(12.sp), color = Palette.muted) } },
                    onClick = { menu = false; scope.launch { studio.exportMix(wav = true)?.let(share) } },
                )
            }
        }
    }
}

@Composable
private fun Title(name: String, onRename: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(name, style = Type.serif(24.sp), color = Palette.fg, modifier = Modifier.weight(1f, fill = false), maxLines = 2, overflow = TextOverflow.Ellipsis)
        Box(Modifier.size(36.dp).clip(CircleShape).clickable(onClick = onRename), contentAlignment = Alignment.Center) {
            Icon(PIcons.pencil, "Renomear", tint = Palette.muted, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun SettingsCard(studio: StudioEngine) {
    val p = studio.project ?: return
    var open by remember { mutableStateOf(false) }
    SCard(padding = 12.dp) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { open = !open },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(PIcons.metronome, null, tint = Palette.brass, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(
                "${p.bpm.toInt()} BPM · ${p.beatsPerBar}/4 · ${if (studio.clickEnabled) "clique" else "sem clique"} · " +
                    if (studio.countInBars == 0) "sem contagem" else "contagem ${studio.countInBars}",
                style = Type.mono(12.sp),
                color = Palette.fg,
                modifier = Modifier.weight(1f),
            )
            Icon(if (open) PIcons.chevronDown else PIcons.chevronRight, null, tint = Palette.muted, modifier = Modifier.size(16.dp))
        }
        if (open) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Andamento", style = Type.body(14.sp), color = Palette.fg, modifier = Modifier.weight(1f))
                StepButton("−") { studio.setBpm(p.bpm - 1) }
                Text("${p.bpm.toInt()}", style = Type.mono(15.sp, FontWeight.Bold), color = Palette.fg)
                StepButton("+") { studio.setBpm(p.bpm + 1) }
            }
            Slider(
                value = p.bpm.toFloat(),
                onValueChange = { studio.setBpm(it.toDouble().let { v -> Math.round(v).toDouble() }) },
                valueRange = 30f..250f,
                colors = sSliderColors(),
            )
            Segmented(
                options = listOf("2/4", "3/4", "4/4", "6/8"),
                selected = listOf(2, 3, 4, 6).indexOf(p.beatsPerBar).coerceAtLeast(0),
                onSelect = { studio.setBeatsPerBar(listOf(2, 3, 4, 6)[it]) },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Clique do metrônomo", style = Type.body(14.sp), color = Palette.fg, modifier = Modifier.weight(1f))
                SSwitch(studio.clickEnabled) { studio.changeClick(it) }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Contagem antes de gravar", style = Type.body(14.sp), color = Palette.fg, modifier = Modifier.weight(1f))
                for (b in 0..2) SChip(if (b == 0) "Não" else "$b", selected = studio.countInBars == b) { studio.changeCountIn(b) }
            }
        }
    }
}

@Composable
private fun InputCard(studio: StudioEngine, askMic: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    var editFx by remember { mutableStateOf(false) }
    var latency by remember { mutableStateOf(false) }
    SCard(padding = 12.dp) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { open = !open },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(PIcons.mic, null, tint = Palette.brass, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(studio.inputName, style = Type.body(14.sp, FontWeight.SemiBold), color = Palette.fg, maxLines = 1)
                Text(
                    "${studio.monitorEffects.preset.title.lowercase()} · ${if (studio.monitorEnabled) "com retorno" else "sem retorno"}",
                    style = Type.mono(11.sp),
                    color = Palette.muted,
                )
            }
            LevelBar(studio.inputLevel, Modifier.width(60.dp))
            Spacer(Modifier.width(8.dp))
            Icon(if (open) PIcons.chevronDown else PIcons.chevronRight, null, tint = Palette.muted, modifier = Modifier.size(16.dp))
        }
        if (open) {
            if (!studio.hasMicPermission()) {
                SPillButton("Permitir microfone", PIcons.mic, filled = true, onClick = askMic)
            }
            InputPicker(studio)
            SSlider("Ganho", studio.inputGainDb, -12f..24f, "%+.0f dB".format(studio.inputGainDb)) { studio.changeInputGain(it) }
            if (studio.monitorEnabled && !studio.headphones) {
                Text(
                    "Conecte um fone de ouvido. Sem fone, o som do alto-falante volta para o microfone e pode dar microfonia.",
                    style = Type.body(12.sp),
                    color = Palette.off,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Ouvir a entrada", style = Type.body(14.sp), color = Palette.fg)
                    Text(
                        if (studio.headphones) "Retorno com efeitos ao vivo" else "Use fone de ouvido para não microfonar",
                        style = Type.body(12.sp),
                        color = if (studio.headphones) Palette.muted else Palette.off,
                    )
                }
                SSwitch(studio.monitorEnabled) { studio.changeMonitor(it) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Efeito", style = Type.body(12.sp), color = Palette.muted)
                    PresetMenu(studio.monitorEffects) { studio.changeMonitorEffects(it) }
                }
                SPillButton("Ajustar", PIcons.sliders, filled = false) { editFx = true }
            }
            Row(
                Modifier.clip(RoundedCornerShape(8.dp)).clickable { latency = true }.padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Compensação de atraso: %.0f ms (ajuste %+.0f)".format(studio.measuredLatencyMs() + studio.latencyAdjustMs, studio.latencyAdjustMs),
                    style = Type.mono(11.sp),
                    color = Palette.muted,
                )
            }
        }
    }
    if (editFx) EffectsSheet("Efeito da entrada", studio.monitorEffects, studio, { editFx = false }) { studio.changeMonitorEffects(it) }
    if (latency) LatencyDialog(studio) { latency = false }
}

@Composable
private fun InputPicker(studio: StudioEngine) {
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { studio.updateRoute() }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Entrada", style = Type.body(14.sp), color = Palette.fg, modifier = Modifier.weight(1f))
        Box {
            Row(
                Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = studio.transport == Transport.STOPPED) { studio.updateRoute(); open = true }.padding(4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(studio.inputName, style = Type.body(14.sp, FontWeight.SemiBold), color = Palette.brass, maxLines = 1)
                Icon(PIcons.chevronDown, null, tint = Palette.brass, modifier = Modifier.size(14.dp))
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                studio.inputs.forEach { opt ->
                    DropdownMenuItem(
                        text = { Text(opt.name, color = if (opt.id == studio.selectedInputId) Palette.brass else Palette.fg) },
                        onClick = { open = false; studio.selectInput(opt.id) },
                    )
                }
            }
        }
    }
}

@Composable
private fun LatencyDialog(studio: StudioEngine, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Atraso da gravação", style = Type.serif(20.sp, FontWeight.Bold)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "O app mede o atraso do áudio do celular (%.0f ms) e adianta cada gravação para ela cair no tempo. ".format(studio.measuredLatencyMs()) +
                        "Se o que você grava ficar atrasado em relação às outras faixas, aumente; se ficar adiantado, diminua.",
                    style = Type.body(14.sp),
                )
                SSlider("Ajuste fino", studio.latencyAdjustMs, -200f..200f, "%+.0f ms".format(studio.latencyAdjustMs)) {
                    studio.changeLatencyAdjust(Math.round(it / 5f) * 5f)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK", color = Palette.brass) } },
        containerColor = Palette.panel,
        titleContentColor = Palette.fg,
        textContentColor = Palette.fg,
    )
}

@Composable
internal fun PresetMenu(current: EffectSettings, onSelect: (EffectSettings) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(8.dp)).clickable { open = true }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(current.preset.title, style = Type.body(16.sp, FontWeight.SemiBold), color = Palette.brass)
            Icon(PIcons.chevronDown, null, tint = Palette.brass, modifier = Modifier.size(14.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            EffectPreset.entries.filter { it != EffectPreset.CUSTOM }.forEach { pr ->
                DropdownMenuItem(
                    text = { Text(pr.title, color = if (pr == current.preset) Palette.brass else Palette.fg) },
                    onClick = {
                        open = false
                        // Mantém o amp escolhido ao trocar de preset.
                        onSelect(EffectSettings.preset(pr).copy(ampModel = current.ampModel, ampInputDB = current.ampInputDB, ampOutputDB = current.ampOutputDB))
                    },
                )
            }
        }
    }
}

// MARK: transporte

@Composable
private fun TransportBar(studio: StudioEngine, onRecord: () -> Unit) {
    val p = studio.project ?: return
    val t = studio.transport
    val busyTransport = t == Transport.COUNT_IN || t == Transport.RECORDING
    var drag by remember { mutableStateOf<Float?>(null) }
    val total = maxOf(studio.duration, studio.position, 1.0)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(formatClock(drag?.toDouble() ?: studio.position), style = Type.mono(22.sp, FontWeight.Bold), color = Palette.fg)
            Text("  / ${formatClock(studio.duration)}", style = Type.mono(13.sp), color = Palette.muted)
            Spacer(Modifier.weight(1f))
            val (label, color) = when (t) {
                Transport.STOPPED -> "PARADO" to Palette.muted
                Transport.PLAYING -> "TOCANDO" to Palette.ok
                Transport.COUNT_IN -> "CONTAGEM ${studio.countInBeat}" to Palette.brass
                Transport.RECORDING -> "● GRAVANDO" to Palette.off
            }
            Text(
                label,
                style = Type.mono(11.sp, FontWeight.Bold),
                color = color,
                modifier = Modifier.panel(shape = RoundedCornerShape(50), fill = Palette.bg, stroke = color).padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
        if (t == Transport.COUNT_IN) {
            Row(Modifier.height(64.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("${studio.countInBeat}", style = Type.serif(54.sp), color = Palette.brass, modifier = Modifier.width(50.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Prepare-se…", style = Type.body(15.sp, FontWeight.SemiBold), color = Palette.fg)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (i in 1..maxOf(1, p.beatsPerBar)) {
                            Box(
                                Modifier.size(16.dp).panel(
                                    shape = CircleShape,
                                    fill = if (i == studio.countInBeat) (if (i == 1) Palette.ok else Palette.brass) else Palette.bg,
                                    stroke = if (i == 1) Palette.brass else Palette.line,
                                ),
                            )
                        }
                    }
                }
            }
        } else {
            Slider(
                value = (drag ?: studio.position.toFloat()).coerceIn(0f, total.toFloat()),
                onValueChange = { drag = it },
                onValueChangeFinished = { drag?.let { studio.seek(it.toDouble()) }; drag = null },
                valueRange = 0f..total.toFloat(),
                enabled = !busyTransport,
                colors = sSliderColors(),
            )
            val beatLen = 60.0 / maxOf(20.0, p.bpm)
            val beatIdx = Math.floor((drag?.toDouble() ?: studio.position) / beatLen).toLong()
            val armedName = p.tracks.firstOrNull { it.id == studio.armedTrackId }?.name
            Row {
                Text("compasso ${beatIdx / p.beatsPerBar + 1} · tempo ${beatIdx % p.beatsPerBar + 1}", style = Type.mono(11.sp), color = Palette.muted)
                Spacer(Modifier.weight(1f))
                Text(
                    when {
                        t == Transport.RECORDING -> "● Gravando em ${armedName ?: "…"}"
                        armedName != null -> "● Gravar em $armedName"
                        else -> "● Gravar em nova faixa"
                    },
                    style = Type.mono(11.sp),
                    color = Palette.off,
                    maxLines = 1,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SIconButton(PIcons.toStart, "Voltar ao início", enabled = !busyTransport) { studio.seek(0.0) }
            SIconButton(PIcons.toEnd, "Ir para o fim da faixa armada", enabled = !busyTransport && studio.armedTrackId != null) {
                studio.armedTrackId?.let { studio.seekToEnd(it) }
            }
            Row(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(50))
                    .background(if (t == Transport.STOPPED) Palette.brass else Palette.line)
                    .clickable { studio.togglePlay() }
                    .padding(vertical = 13.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(if (t == Transport.STOPPED) PIcons.play else PIcons.stop, null, tint = if (t == Transport.STOPPED) Palette.bg else Palette.fg, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (t == Transport.STOPPED) "Tocar" else "Parar", style = Type.body(17.sp, FontWeight.Bold), color = if (t == Transport.STOPPED) Palette.bg else Palette.fg)
            }
            Box(
                Modifier
                    .size(52.dp)
                    .panel(shape = CircleShape, fill = if (busyTransport) Palette.off else Palette.bg, stroke = Palette.off, strokeWidth = 2.dp)
                    .clickable { if (busyTransport) studio.stop() else onRecord() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (busyTransport) PIcons.stop else PIcons.record,
                    if (busyTransport) "Parar gravação" else "Gravar",
                    tint = if (busyTransport) Palette.bg else Palette.off,
                    modifier = Modifier.size(26.dp),
                )
            }
        }
    }
}
