package com.pestana.estudio

import android.content.res.Configuration
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.pestana.estudio.chords.ChordsScreen
import com.pestana.estudio.metronome.Metronome
import com.pestana.estudio.metronome.MetronomeScreen
import com.pestana.estudio.practice.PracticeEngine
import com.pestana.estudio.practice.PracticeScreen
import com.pestana.estudio.soon.StudioSoonScreen
import com.pestana.estudio.tuner.TunerEngine
import com.pestana.estudio.tuner.TunerScreen
import com.pestana.estudio.ui.KeepScreenOn
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type

private data class Tab(val label: String, val icon: ImageVector)

private val tabs = listOf(
    Tab("Afinador", PIcons.tuningFork),
    Tab("Acordes", PIcons.chordGrid),
    Tab("Metrônomo", PIcons.metronome),
    Tab("Estúdio", PIcons.waveform),
    Tab("Treino", PIcons.practice),
)

@Composable
fun PestanaApp() {
    val context = LocalContext.current
    val tuner = remember { TunerEngine(context) }
    val metronome = remember { Metronome(context) }
    val practice = remember { PracticeEngine(context) }
    var tab by rememberSaveable { mutableIntStateOf(0) }

    // App em segundo plano: o metrônomo para (não fica tocando escondido).
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) metronome.stop()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            metronome.release()
            tuner.release()
            practice.release()
        }
    }

    // Áudio vindo de outro app ("Abrir com"/"Compartilhar"): abre o Treino e importa.
    val incoming = IncomingAudio.uri.value
    LaunchedEffect(incoming) {
        if (incoming != null) {
            if (metronome.playing) metronome.stop()
            tab = 4
            practice.close()
            practice.importSong(incoming)
            IncomingAudio.uri.value = null
        }
    }

    KeepScreenOn(tuner.running || metronome.playing || practice.isPlaying || practice.separating)

    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val selectTab: (Int) -> Unit = { i ->
        // O metrônomo desta aba não deve vazar nas telas de gravação/treino.
        if (i >= 3 && metronome.playing) metronome.stop()
        tab = i
    }

    Scaffold(
        containerColor = Palette.bg,
        contentWindowInsets = WindowInsets.safeDrawing,
        bottomBar = {
            if (!landscape) {
                Column {
                    HorizontalDivider(color = Palette.line, thickness = 0.5.dp)
                    NavigationBar(containerColor = Palette.bg, tonalElevation = 0.dp) {
                        tabs.forEachIndexed { i, t ->
                            NavigationBarItem(
                                selected = tab == i,
                                onClick = { selectTab(i) },
                                icon = { Icon(t.icon, contentDescription = null, modifier = Modifier.size(24.dp)) },
                                label = { Text(t.label, style = Type.body(11.sp), maxLines = 1) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = Palette.brass,
                                    selectedTextColor = Palette.brass,
                                    unselectedIconColor = Palette.muted,
                                    unselectedTextColor = Palette.muted,
                                    indicatorColor = Palette.panel,
                                ),
                            )
                        }
                    }
                }
            }
        },
    ) { padding ->
        Row(Modifier.fillMaxSize().background(Palette.bg).padding(padding)) {
            // Deitado: abas numa coluna à esquerda, para sobrar altura para o conteúdo.
            if (landscape) {
                NavigationRail(
                    containerColor = Palette.bg,
                    windowInsets = WindowInsets(0, 0, 0, 0),
                ) {
                    Spacer(Modifier.weight(1f))
                    tabs.forEachIndexed { i, t ->
                        NavigationRailItem(
                            selected = tab == i,
                            onClick = { selectTab(i) },
                            icon = { Icon(t.icon, contentDescription = null, modifier = Modifier.size(22.dp)) },
                            label = { Text(t.label, style = Type.body(10.sp), maxLines = 1) },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = Palette.brass,
                                selectedTextColor = Palette.brass,
                                unselectedIconColor = Palette.muted,
                                unselectedTextColor = Palette.muted,
                                indicatorColor = Palette.panel,
                            ),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                }
                VerticalDivider(color = Palette.line, thickness = 0.5.dp)
            }
            Box(Modifier.weight(1f).fillMaxHeight()) {
                when (tab) {
                    0 -> TunerScreen(tuner)
                    1 -> ChordsScreen(tuner.a4)
                    2 -> MetronomeScreen(metronome)
                    3 -> StudioSoonScreen()
                    else -> PracticeScreen(practice)
                }
            }
        }
    }
}
