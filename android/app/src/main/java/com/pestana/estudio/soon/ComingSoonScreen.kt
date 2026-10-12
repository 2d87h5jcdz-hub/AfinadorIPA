package com.pestana.estudio.soon

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pestana.estudio.ui.PIcons
import com.pestana.estudio.ui.Palette
import com.pestana.estudio.ui.Type
import com.pestana.estudio.ui.panel

/** Tela de recurso que ainda vai chegar no Android, com a identidade visual do app. */
@Composable
fun ComingSoonScreen(
    title: String,
    icon: ImageVector,
    tagline: String,
    features: List<String>,
) {
    Box(
        Modifier.fillMaxSize().background(Palette.bg).verticalScroll(rememberScrollState()),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(title, style = Type.serif(26.sp), color = Palette.fg)
            Column(
                Modifier.fillMaxWidth().panel().padding(22.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(
                    Modifier.size(76.dp).panel(shape = CircleShape, fill = Palette.bg, stroke = Palette.brass, strokeWidth = 2.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(icon, null, tint = Palette.brass, modifier = Modifier.size(36.dp))
                }
                Text(
                    "EM BREVE NO ANDROID",
                    style = Type.mono(11.sp, FontWeight.Medium),
                    color = Palette.brass,
                    modifier = Modifier.panel(shape = RoundedCornerShape(50), fill = Palette.bg).padding(horizontal = 12.dp, vertical = 5.dp),
                )
                Text(tagline, style = Type.serif(20.sp, FontWeight.Bold), color = Palette.fg, textAlign = TextAlign.Center)
            }
            Column(
                Modifier.fillMaxWidth().panel().padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("O que vem aí", style = Type.body(13.sp, FontWeight.SemiBold), color = Palette.muted)
                features.forEach { f ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(
                            Modifier.padding(top = 7.dp, end = 12.dp).size(7.dp).panel(shape = CircleShape, fill = Palette.brass, stroke = Palette.brass),
                        )
                        Text(f, style = Type.body(15.sp), color = Palette.fg)
                    }
                }
            }
            Text(
                "Enquanto isso, o afinador, os acordes, o metrônomo e o treino já funcionam por completo.",
                style = Type.body(13.sp),
                color = Palette.muted,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
fun StudioSoonScreen() = ComingSoonScreen(
    title = "Estúdio",
    icon = PIcons.waveform,
    tagline = "Grave em camadas, direto no celular",
    features = listOf(
        "Gravação multipista com metrônomo e contagem",
        "Volume, pan, mudo e solo por faixa",
        "Efeitos de guitarra e amplificador",
        "Exportar a mixagem para compartilhar",
    ),
)
