package com.pestana.estudio.studio

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Segmented
import com.pestana.estudio.ui.Type
import kotlin.math.abs
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TrackSheet(studio: StudioEngine, track: StudioTrack, onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var editFx by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = Palette.panel) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(track.name, style = Type.serif(22.sp), color = Palette.fg, modifier = Modifier.weight(1f))
                Box(Modifier.size(36.dp).clip(RoundedCornerShape(50)).clickable { renaming = true }, contentAlignment = Alignment.Center) {
                    Icon(PIcons.pencil, "Renomear", tint = Palette.muted, modifier = Modifier.size(18.dp))
                }
            }
            Text(
                "${track.clips.size} ${if (track.clips.size == 1) "trecho" else "trechos"} · ${formatClock(track.end, tenths = false)}" +
                    if (track.isImported) " · importada" else "",
                style = Type.mono(11.sp),
                color = Palette.muted,
            )
            SSlider("Volume", track.volume, 0f..1.5f, "${(track.volume * 100).roundToInt()}%") { studio.updateTrack(track.copy(volume = it)) }
            SSlider("Pan", track.pan, -1f..1f, panText(track.pan)) {
                studio.updateTrack(track.copy(pan = if (abs(it) < 0.06f) 0f else it))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SChip("Mudo", track.isMuted, Palette.off) { studio.updateTrack(track.copy(isMuted = !track.isMuted)) }
                SChip("Solo", track.isSolo, Palette.ok) { studio.updateTrack(track.copy(isSolo = !track.isSolo)) }
                SChip("Efeitos ligados", track.effectsOn) { studio.updateTrack(track.copy(effectsOn = !track.effectsOn)) }
            }
            SLabel("Efeito")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { PresetMenu(track.effects) { studio.updateTrack(track.copy(effects = it)) } }
                SPillButton("Ajustar", PIcons.sliders, filled = false) { editFx = true }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SChip("Gravar nesta faixa", studio.armedTrackId == track.id, Palette.off, enabled = studio.transport == Transport.STOPPED) {
                    studio.arm(track.id)
                }
                SChip("Ir para o fim", enabled = studio.transport == Transport.STOPPED) { studio.seekToEnd(track.id); onDismiss() }
            }
            Spacer(Modifier.height(4.dp))
            Row(
                Modifier.clip(RoundedCornerShape(8.dp)).clickable { deleting = true }.padding(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(PIcons.trash, null, tint = Palette.off, modifier = Modifier.size(18.dp))
                Text("Apagar faixa", style = Type.body(14.sp), color = Palette.off)
            }
        }
    }
    if (renaming) NameDialog("Renomear faixa", track.name, { renaming = false }) {
        if (it.isNotBlank()) studio.updateTrack(track.copy(name = it.trim()))
        renaming = false
    }
    if (deleting) ConfirmDialog("Apagar faixa?", "\"${track.name}\" e suas gravações serão apagadas.", "Apagar", { deleting = false }) {
        deleting = false
        studio.deleteTrack(track.id)
        onDismiss()
    }
    if (editFx) EffectsSheet("Efeitos · ${track.name}", track.effects, studio, { editFx = false }) {
        studio.updateTrack(track.copy(effects = it))
    }
}

private fun panText(p: Float) = when {
    abs(p) < 0.02f -> "centro"
    p < 0 -> "esq ${(-p * 100).roundToInt()}"
    else -> "dir ${(p * 100).roundToInt()}"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EffectsSheet(
    title: String,
    initial: EffectSettings,
    studio: StudioEngine,
    onDismiss: () -> Unit,
    onChange: (EffectSettings) -> Unit,
) {
    var e by remember { mutableStateOf(initial) }
    val set: (EffectSettings) -> Unit = { n ->
        e = n.copy(preset = if (n.preset == e.preset && n != e) EffectPreset.CUSTOM else n.preset)
        onChange(e)
    }
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var amps by remember { mutableStateOf(studio.amps()) }
    val ampPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) studio.importAmp(uri) { name ->
            amps = studio.amps()
            if (name != null) set(e.copy(ampModel = name))
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = Palette.panel) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(title, style = Type.serif(22.sp), color = Palette.fg)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                EffectPreset.entries.filter { it != EffectPreset.CUSTOM }.forEach { pr ->
                    SChip(pr.title, e.preset == pr) {
                        val n = EffectSettings.preset(pr).copy(ampModel = e.ampModel, ampInputDB = e.ampInputDB, ampOutputDB = e.ampOutputDB)
                        e = n; onChange(n)
                    }
                }
            }

            Section("Noise gate", e.gateEnabled, { set(e.copy(gateEnabled = it)) }) {
                SSlider("Limiar", e.gateThresholdDB, -80f..-20f, "%.0f dB".format(e.gateThresholdDB)) { set(e.copy(gateThresholdDB = it)) }
            }
            Section("Equalizador", null, null) {
                SSlider("Graves (100 Hz)", e.eqLowDB, -12f..12f, "%+.1f dB".format(e.eqLowDB)) { set(e.copy(eqLowDB = snap(it))) }
                SSlider("Médios (1 kHz)", e.eqMidDB, -12f..12f, "%+.1f dB".format(e.eqMidDB)) { set(e.copy(eqMidDB = snap(it))) }
                SSlider("Agudos (8 kHz)", e.eqHighDB, -12f..12f, "%+.1f dB".format(e.eqHighDB)) { set(e.copy(eqHighDB = snap(it))) }
            }
            Section("Compressor", e.compressorEnabled, { set(e.copy(compressorEnabled = it)) }) {
                SSlider("Intensidade", e.compressorAmount, 0f..1f, "${(e.compressorAmount * 100).roundToInt()}%") { set(e.copy(compressorAmount = it)) }
            }
            Section("Drive", e.driveAmount > 0, { set(e.copy(driveAmount = if (it) 0.4f else 0f)) }) {
                Segmented(DRIVE_STYLES.map { it.substringBefore(" ") }, e.driveStyle, { set(e.copy(driveStyle = it)) }, Modifier.fillMaxWidth())
                SSlider("Quantidade", e.driveAmount, 0f..1f, "${(e.driveAmount * 100).roundToInt()}%") { set(e.copy(driveAmount = it)) }
            }
            Section("Amplificador (NAM)", e.ampModel != null, { if (!it) set(e.copy(ampModel = null)) else amps.firstOrNull()?.let { a -> set(e.copy(ampModel = a)) } ?: ampPicker.launch(arrayOf("*/*")) }) {
                var menu by remember { mutableStateOf(false) }
                Box {
                    Row(Modifier.clip(RoundedCornerShape(8.dp)).clickable { menu = true }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(e.ampModel?.removeSuffix(".nam") ?: "Escolher modelo…", style = Type.body(15.sp, FontWeight.SemiBold), color = Palette.brass)
                        Icon(PIcons.chevronDown, null, tint = Palette.brass, modifier = Modifier.size(14.dp))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        amps.forEach { a -> DropdownMenuItem(text = { Text(a.removeSuffix(".nam")) }, onClick = { menu = false; set(e.copy(ampModel = a)) }) }
                        DropdownMenuItem(text = { Text("Importar arquivo .nam…", color = Palette.brass) }, onClick = { menu = false; ampPicker.launch(arrayOf("*/*")) })
                        if (e.ampModel != null) DropdownMenuItem(text = { Text("Sem amplificador", color = Palette.off) }, onClick = { menu = false; set(e.copy(ampModel = null)) })
                    }
                }
                Text(
                    "Modelos .nam (Neural Amp Modeler) de amplificadores reais. Baixe em tone3000.com e importe aqui.",
                    style = Type.body(12.sp),
                    color = Palette.muted,
                )
                SSlider("Entrada", e.ampInputDB, -12f..12f, "%+.0f dB".format(e.ampInputDB), enabled = e.ampModel != null) { set(e.copy(ampInputDB = snap(it))) }
                SSlider("Saída", e.ampOutputDB, -12f..12f, "%+.0f dB".format(e.ampOutputDB), enabled = e.ampModel != null) { set(e.copy(ampOutputDB = snap(it))) }
            }
            Section("Modulação", e.modType != 0, { set(e.copy(modType = if (it) 1 else 0)) }) {
                Segmented(MOD_TYPES.drop(1), (e.modType - 1).coerceAtLeast(0), { set(e.copy(modType = it + 1)) }, Modifier.fillMaxWidth())
                SSlider("Velocidade", e.modRate, 0.05f..10f, "%.2f Hz".format(e.modRate), enabled = e.modType != 0) { set(e.copy(modRate = it)) }
                SSlider("Profundidade", e.modDepth, 0f..1f, "${(e.modDepth * 100).roundToInt()}%", enabled = e.modType != 0) { set(e.copy(modDepth = it)) }
                SSlider("Mistura", e.modMix, 0f..1f, "${(e.modMix * 100).roundToInt()}%", enabled = e.modType != 0) { set(e.copy(modMix = it)) }
            }
            Section("Delay", e.delayMix > 0, { set(e.copy(delayMix = if (it) 0.2f else 0f)) }) {
                SSlider("Mistura", e.delayMix, 0f..1f, "${(e.delayMix * 100).roundToInt()}%") { set(e.copy(delayMix = it)) }
                SSlider("Tempo", e.delayTime, 0.05f..1.5f, "%.0f ms".format(e.delayTime * 1000)) { set(e.copy(delayTime = it)) }
                SSlider("Repetições", e.delayFeedback, 0f..0.9f, "${(e.delayFeedback * 100).roundToInt()}%") { set(e.copy(delayFeedback = it)) }
            }
            Section("Reverb", e.reverbMix > 0, { set(e.copy(reverbMix = if (it) 0.2f else 0f)) }) {
                SSlider("Mistura", e.reverbMix, 0f..1f, "${(e.reverbMix * 100).roundToInt()}%") { set(e.copy(reverbMix = it)) }
            }
        }
    }
}

private fun snap(v: Float) = (v * 2).roundToInt() / 2f

@Composable
private fun Section(title: String, on: Boolean?, onToggle: ((Boolean) -> Unit)?, content: @Composable () -> Unit) {
    SCard(padding = 12.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Type.body(15.sp, FontWeight.SemiBold), color = Palette.fg, modifier = Modifier.weight(1f))
            if (on != null && onToggle != null) SSwitch(on, onChange = onToggle)
        }
        if (on != false) content()
    }
}
