package com.pestana.estudio.tuner

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.ActivityCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.pestana.estudio.core.NeedleSpring
import com.pestana.estudio.core.Note
import com.pestana.estudio.core.Tuning
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Segmented
import com.pestana.estudio.ui.StepButton
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.findActivity
import com.pestana.estudio.ui.haptic
import com.pestana.estudio.ui.panel
import com.pestana.estudio.ui.pullUp
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

@Composable
fun TunerScreen(tuner: TunerEngine) {
    val context = LocalContext.current
    val view = LocalView.current
    var granted by remember { mutableStateOf(tuner.hasPermission()) }
    var denied by rememberSaveable { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        denied = !ok
        if (ok) tuner.start()
    }

    // Microfone ligado só com a aba aberta e o app na frente.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    granted = tuner.hasPermission()
                    if (granted) tuner.start()
                }
                Lifecycle.Event.ON_PAUSE -> tuner.stop()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            tuner.stop()
        }
    }

    LaunchedEffect(tuner.tunedEvents) {
        if (tuner.tunedEvents > 0) view.haptic(strong = true)
    }

    val askPermission = {
        val activity = context.findActivity()
        val permanentlyDenied = denied && activity != null &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.RECORD_AUDIO)
        if (permanentlyDenied) {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            context.startActivity(intent)
        } else {
            launcher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.bg)) {
        val landscape = maxWidth > maxHeight
        if (landscape) {
            Row(
                Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                    Dial(tuner, granted, denied, askPermission, landscape = true)
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Header(tuner.running)
                    ModeRow(tuner)
                    Strings(tuner)
                    SettingsRow(tuner)
                }
            }
        } else {
            // Retrato: ajustes encostados embaixo; se faltar altura, a tela rola.
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = maxHeight)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    Header(tuner.running)
                    Dial(tuner, granted, denied, askPermission, landscape = false)
                    ModeRow(tuner)
                    Strings(tuner)
                }
                Column(Modifier.padding(top = 18.dp)) {
                    SettingsRow(tuner)
                }
            }
        }
    }
}

@Composable
private fun Header(running: Boolean) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = Palette.fg)) { append("Afina") }
                withStyle(SpanStyle(color = Palette.brass)) { append("dor") }
            },
            style = Type.serif(26.sp),
        )
        Spacer(Modifier.weight(1f))
        Text(
            if (running) "OUVINDO" else "MICROFONE DESLIGADO",
            style = Type.mono(11.sp, FontWeight.Medium),
            color = if (running) Palette.ok else Palette.muted,
            modifier = Modifier.padding(bottom = 4.dp),
        )
    }
}

@Composable
private fun Dial(
    tuner: TunerEngine,
    granted: Boolean,
    denied: Boolean,
    askPermission: () -> Unit,
    landscape: Boolean,
) {
    val r = tuner.reading
    val inTune = r != null && abs(r.cents) <= 5
    Column(
        Modifier
            .fillMaxWidth()
            .panel()
            .padding(horizontal = 14.dp, vertical = if (landscape) 10.dp else 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Gauge(
            cents = r?.centsPrecise ?: 0.0,
            inTune = inTune,
            modifier = Modifier.fillMaxWidth().height(if (landscape) 120.dp else 170.dp),
        )

        if (!granted) {
            PermissionCard(denied, askPermission)
            return@Column
        }

        val noteColor = if (inTune) Palette.ok else Palette.fg
        Row(Modifier.pullUp(if (landscape) 14.dp else 26.dp), verticalAlignment = Alignment.Top) {
            Text(
                r?.let { Note.name(it.targetMidi) } ?: "–",
                style = Type.serif(if (landscape) 64.sp else 92.sp),
                color = noteColor,
            )
            if (r != null) {
                Text(
                    "${Note.octave(r.targetMidi)}",
                    style = Type.serif(if (landscape) 22.sp else 30.sp, FontWeight.SemiBold),
                    color = Palette.muted,
                    modifier = Modifier.padding(top = if (landscape) 10.dp else 16.dp, start = 2.dp),
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
            Readout(r?.let { String.format(java.util.Locale.US, "%.1f", it.frequency) } ?: "—", "Hz")
            Readout(r?.let { if (it.cents > 0) "+${it.cents}" else "${it.cents}" } ?: "—", "cents")
        }

        val hint = when {
            r == null -> "Toque uma corda"
            inTune -> "Afinada ✓"
            r.cents < 0 -> "Baixa · aperte a tarraxa"
            else -> "Alta · afrouxe a tarraxa"
        }
        Text(
            hint,
            style = Type.body(15.sp),
            color = if (r == null) Palette.muted else if (inTune) Palette.ok else Palette.off,
            modifier = Modifier.padding(top = if (landscape) 4.dp else 8.dp),
        )
        if (tuner.micError) {
            Text(
                "Não consegui abrir o microfone. Feche outros apps que estejam usando o áudio.",
                style = Type.body(13.sp),
                color = Palette.off,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun PermissionCard(denied: Boolean, askPermission: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(PIcons.mic, contentDescription = null, tint = Palette.brass, modifier = Modifier.size(34.dp))
        Text("O afinador precisa ouvir seu instrumento", style = Type.serif(18.sp, FontWeight.Bold), color = Palette.fg, textAlign = TextAlign.Center)
        Text(
            "O som do microfone é analisado só no seu celular, na hora. Nada é gravado nem enviado.",
            style = Type.body(14.sp),
            color = Palette.muted,
            textAlign = TextAlign.Center,
        )
        Box(
            Modifier
                .padding(top = 4.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.brass)
                .clickable(onClick = askPermission)
                .padding(horizontal = 22.dp, vertical = 12.dp),
        ) {
            Text(
                "Permitir microfone",
                style = Type.body(15.sp, FontWeight.Bold),
                color = Palette.bg,
            )
        }
        if (denied) {
            Text(
                "Se o Android não perguntar de novo, ative em Permissões › Microfone.",
                style = Type.body(12.sp),
                color = Palette.muted,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun Readout(value: String, unit: String) {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Palette.fg)) { append(value) }
            withStyle(SpanStyle(color = Palette.muted)) { append(" $unit") }
        },
        style = Type.mono(14.sp),
    )
}

@Composable
private fun ModeRow(tuner: TunerEngine) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Segmented(
            options = listOf("Automático", "Por corda"),
            selected = if (tuner.autoMode) 0 else 1,
            onSelect = { tuner.changeAutoMode(it == 0) },
            modifier = Modifier.width(230.dp),
        )
        Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
        Text("segure = ouvir", style = Type.mono(11.sp), color = Palette.muted, maxLines = 1)
    }
}

@Composable
private fun Strings(tuner: TunerEngine) {
    val view = LocalView.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        tuner.tuning.midi.forEachIndexed { i, m ->
            val active = if (tuner.autoMode) tuner.reading?.stringIndex == i else tuner.manualIndex == i
            val done = i in tuner.tunedStrings && !active
            Column(
                Modifier
                    .weight(1f)
                    .panel(
                        radius = 14.dp,
                        stroke = if (active) Palette.brass else if (done) Palette.ok else Palette.line,
                        strokeWidth = if (active) 2.dp else 1.dp,
                    )
                    .pointerInput(i) {
                        detectTapGestures(
                            onTap = { tuner.selectString(i) },
                            onLongPress = {
                                view.haptic(strong = true)
                                tuner.playReference(i)
                            },
                        )
                    }
                    .padding(vertical = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(Note.name(m), style = Type.serif(22.sp, FontWeight.Bold), color = Palette.fg)
                Text("${6 - i}ª", style = Type.mono(10.sp), color = if (done) Palette.ok else Palette.muted)
            }
        }
    }
}

@Composable
private fun SettingsRow(tuner: TunerEngine) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Column(
            Modifier.weight(1f).padding(end = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("Afinação", style = Type.body(12.sp), color = Palette.muted)
            TuningMenu(tuner.tuning, tuner::selectTuning)
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Lá central (A4)", style = Type.body(12.sp), color = Palette.muted)
            Row(
                Modifier.panel(radius = 12.dp).padding(3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                StepButton("−") { tuner.changeA4(tuner.a4 - 1) }
                Text("${tuner.a4.toInt()}", style = Type.mono(14.sp), color = Palette.fg)
                StepButton("+") { tuner.changeA4(tuner.a4 + 1) }
            }
        }
    }
}

@Composable
private fun TuningMenu(current: Tuning, onSelect: (Tuning) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .panel(radius = 12.dp)
                .clickable { open = true }
                .padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                current.name,
                style = Type.body(13.sp, FontWeight.SemiBold),
                color = Palette.fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(PIcons.chevronDown, null, tint = Palette.muted, modifier = Modifier.size(14.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Tuning.all.forEach { t ->
                DropdownMenuItem(
                    text = {
                        Text(
                            t.name,
                            style = Type.body(14.sp, if (t == current) FontWeight.Bold else FontWeight.Normal),
                            color = if (t == current) Palette.brass else Palette.fg,
                        )
                    },
                    onClick = {
                        onSelect(t)
                        open = false
                    },
                )
            }
        }
    }
}

/** Mostrador semicircular com o ponteiro de mola (−50…+50 cents). */
@Composable
private fun Gauge(cents: Double, inTune: Boolean, modifier: Modifier = Modifier) {
    val spring = remember { NeedleSpring() }
    val target by rememberUpdatedState(cents.coerceIn(-50.0, 50.0))
    var degrees by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { t -> degrees = (spring.step(target, t) / 50.0 * 60.0).toFloat() }
        }
    }
    val measurer = rememberTextMeasurer()
    val needleColor = if (inTune) Palette.ok else Palette.brass
    Canvas(modifier) {
        val center = Offset(size.width / 2, size.height - 10.dp.toPx())
        val radius = min(size.width / 2 - 24.dp.toPx(), size.height - 30.dp.toPx())
        drawScale(center, radius, measurer)
        drawNeedle(center, radius, degrees, needleColor)
    }
}

private fun point(center: Offset, radius: Float, radians: Double) =
    Offset(center.x + (sin(radians) * radius).toFloat(), center.y - (cos(radians) * radius).toFloat())

private fun DrawScope.drawScale(center: Offset, radius: Float, measurer: TextMeasurer) {
    val zr = radius + 2.dp.toPx()
    drawArc(
        color = Palette.ok.copy(alpha = 0.35f),
        startAngle = -96f,
        sweepAngle = 12f,
        useCenter = false,
        topLeft = Offset(center.x - zr, center.y - zr),
        size = Size(zr * 2, zr * 2),
        style = Stroke(width = 10.dp.toPx()),
    )
    for (c in -50..50 step 5) {
        val major = c % 25 == 0
        val a = c / 50.0 * 60.0 * Math.PI / 180.0
        val inner = radius - (if (major) 16 else 9).dp.toPx()
        drawLine(
            color = if (major) Palette.fg else Palette.muted,
            start = point(center, inner, a),
            end = point(center, radius, a),
            strokeWidth = (if (major) 2 else 1).dp.toPx(),
        )
        if (major) {
            val label = if (c > 0) "+$c" else "$c"
            val layout = measurer.measure(label, Type.mono(11.sp).copy(color = Palette.muted))
            val p = point(center, radius + 14.dp.toPx(), a)
            drawText(layout, topLeft = Offset(p.x - layout.size.width / 2f, p.y - layout.size.height / 2f))
        }
    }
}

private fun DrawScope.drawNeedle(center: Offset, radius: Float, degrees: Float, color: Color) {
    val a = degrees * Math.PI / 180.0
    drawLine(color, center, point(center, radius - 4.dp.toPx(), a), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
    drawCircle(color, radius = 7.dp.toPx(), center = center)
}
