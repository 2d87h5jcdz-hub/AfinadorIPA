package com.pestana.estudio.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/** Ícones desenhados para o app (sem depender da biblioteca de ícones do Material). */
object PIcons {
    private fun icon(name: String, block: ImageVector.Builder.() -> Unit): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply(block).build()

    private fun ImageVector.Builder.stroke(width: Float = 1.9f, pathBuilder: PathBuilder.() -> Unit) =
        path(
            fill = null,
            stroke = SolidColor(Color.Black),
            strokeLineWidth = width,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
            pathBuilder = pathBuilder,
        )

    private fun ImageVector.Builder.fill(pathBuilder: PathBuilder.() -> Unit) =
        path(fill = SolidColor(Color.Black), pathBuilder = pathBuilder)

    private fun PathBuilder.circle(cx: Float, cy: Float, r: Float) {
        moveTo(cx - r, cy)
        arcTo(r, r, 0f, false, true, cx + r, cy)
        arcTo(r, r, 0f, false, true, cx - r, cy)
        close()
    }

    val tuningFork = icon("diapasao") {
        stroke {
            moveTo(8f, 2.5f); lineTo(8f, 10f)
            curveTo(8f, 13f, 9.8f, 14.8f, 12f, 14.8f)
            curveTo(14.2f, 14.8f, 16f, 13f, 16f, 10f)
            lineTo(16f, 2.5f)
            moveTo(12f, 14.8f); lineTo(12f, 21.5f)
        }
    }

    val chordGrid = icon("acordes") {
        stroke(2.4f) { moveTo(5f, 4f); lineTo(19f, 4f) }
        stroke(1.4f) {
            for (x in listOf(5f, 9.67f, 14.33f, 19f)) { moveTo(x, 4f); lineTo(x, 20f) }
            for (y in listOf(9.3f, 14.6f, 20f)) { moveTo(5f, y); lineTo(19f, y) }
        }
        fill { circle(9.67f, 11.95f, 2.2f); circle(14.33f, 17.3f, 2.2f) }
    }

    val metronome = icon("metronomo") {
        stroke {
            moveTo(9.5f, 3f); lineTo(14.5f, 3f); lineTo(19f, 21f); lineTo(5f, 21f); close()
            moveTo(12f, 16.5f); lineTo(17.5f, 6f)
            moveTo(7f, 16.5f); lineTo(17f, 16.5f)
        }
    }

    val waveform = icon("estudio") {
        stroke(2f) {
            val bars = listOf(4f to 4f, 7f to 9f, 10f to 14f, 13f to 7f, 16f to 11f, 19f to 5f)
            for ((x, h) in bars) { moveTo(x, 12f - h / 2); lineTo(x, 12f + h / 2) }
        }
    }

    val practice = icon("treino") {
        stroke {
            moveTo(3f, 6f); lineTo(13f, 6f)
            moveTo(3f, 11f); lineTo(13f, 11f)
            moveTo(3f, 16f); lineTo(9f, 16f)
            moveTo(17f, 17.5f); lineTo(17f, 4f); lineTo(21f, 5.5f)
        }
        fill { circle(15f, 17.5f, 2.5f) }
    }

    val play = icon("tocar") {
        fill { moveTo(7f, 4.5f); lineTo(19.5f, 12f); lineTo(7f, 19.5f); close() }
    }

    val stop = icon("parar") {
        fill { moveTo(6f, 6f); lineTo(18f, 6f); lineTo(18f, 18f); lineTo(6f, 18f); close() }
    }

    val chevronLeft = icon("anterior") {
        stroke(2.2f) { moveTo(15f, 5f); lineTo(8f, 12f); lineTo(15f, 19f) }
    }

    val chevronRight = icon("proxima") {
        stroke(2.2f) { moveTo(9f, 5f); lineTo(16f, 12f); lineTo(9f, 19f) }
    }

    val chevronDown = icon("abrir") {
        stroke(2f) { moveTo(6f, 9f); lineTo(12f, 15f); lineTo(18f, 9f) }
    }

    val speaker = icon("som") {
        fill { moveTo(3f, 9f); lineTo(7f, 9f); lineTo(12f, 4.5f); lineTo(12f, 19.5f); lineTo(7f, 15f); lineTo(3f, 15f); close() }
        stroke(1.9f) {
            moveTo(15.5f, 8.5f); curveTo(17f, 10.5f, 17f, 13.5f, 15.5f, 15.5f)
            moveTo(18.2f, 5.8f); curveTo(21.2f, 9.5f, 21.2f, 14.5f, 18.2f, 18.2f)
        }
    }

    val mic = icon("microfone") {
        stroke(1.9f) {
            moveTo(9f, 6f); curveTo(9f, 3f, 15f, 3f, 15f, 6f); lineTo(15f, 11f)
            curveTo(15f, 14f, 9f, 14f, 9f, 11f); close()
            moveTo(5.5f, 11f); curveTo(5.5f, 19f, 18.5f, 19f, 18.5f, 11f)
            moveTo(12f, 17f); lineTo(12f, 21f)
        }
    }

    val pause = icon("pausar") {
        fill {
            moveTo(6.5f, 5f); lineTo(10f, 5f); lineTo(10f, 19f); lineTo(6.5f, 19f); close()
            moveTo(14f, 5f); lineTo(17.5f, 5f); lineTo(17.5f, 19f); lineTo(14f, 19f); close()
        }
    }

    val importFile = icon("importar") {
        stroke {
            moveTo(12f, 3.5f); lineTo(12f, 14.5f)
            moveTo(7.5f, 10f); lineTo(12f, 14.5f); lineTo(16.5f, 10f)
            moveTo(4.5f, 15.5f); lineTo(4.5f, 19.5f); lineTo(19.5f, 19.5f); lineTo(19.5f, 15.5f)
        }
    }

    val sparkle = icon("ia") {
        fill {
            moveTo(10f, 3f); lineTo(11.6f, 8.4f); lineTo(17f, 10f); lineTo(11.6f, 11.6f)
            lineTo(10f, 17f); lineTo(8.4f, 11.6f); lineTo(3f, 10f); lineTo(8.4f, 8.4f); close()
            moveTo(18f, 14f); lineTo(18.8f, 16.2f); lineTo(21f, 17f); lineTo(18.8f, 17.8f)
            lineTo(18f, 20f); lineTo(17.2f, 17.8f); lineTo(15f, 17f); lineTo(17.2f, 16.2f); close()
        }
    }

    val note = icon("musica") {
        stroke { moveTo(10f, 17.5f); lineTo(10f, 4.5f); lineTo(19f, 3f); lineTo(19f, 15.5f) }
        fill { circle(7.5f, 17.5f, 2.6f); circle(16.5f, 15.5f, 2.6f) }
    }

    val trash = icon("apagar") {
        stroke {
            moveTo(4.5f, 6.5f); lineTo(19.5f, 6.5f)
            moveTo(9.5f, 6.5f); lineTo(9.5f, 4f); lineTo(14.5f, 4f); lineTo(14.5f, 6.5f)
            moveTo(6.5f, 6.5f); lineTo(7.5f, 20f); lineTo(16.5f, 20f); lineTo(17.5f, 6.5f)
        }
    }

    val back5 = icon("voltar5") {
        stroke {
            moveTo(5.5f, 12f); curveTo(5.5f, 7.5f, 9f, 4.5f, 12.5f, 4.5f)
            curveTo(16.6f, 4.5f, 19.5f, 7.8f, 19.5f, 12f)
            curveTo(19.5f, 16.2f, 16.6f, 19.5f, 12.5f, 19.5f)
            moveTo(3f, 9.5f); lineTo(5.5f, 12.5f); lineTo(8.5f, 10f)
        }
    }

    val forward5 = icon("avancar5") {
        stroke {
            moveTo(18.5f, 12f); curveTo(18.5f, 7.5f, 15f, 4.5f, 11.5f, 4.5f)
            curveTo(7.4f, 4.5f, 4.5f, 7.8f, 4.5f, 12f)
            curveTo(4.5f, 16.2f, 7.4f, 19.5f, 11.5f, 19.5f)
            moveTo(21f, 9.5f); lineTo(18.5f, 12.5f); lineTo(15.5f, 10f)
        }
    }

    val loopBack = icon("voltar-a") {
        stroke {
            moveTo(9f, 5f); lineTo(5f, 9f); lineTo(9f, 13f)
            moveTo(5f, 9f); lineTo(14f, 9f); curveTo(17f, 9f, 19f, 11f, 19f, 14f)
            curveTo(19f, 17f, 17f, 19f, 14f, 19f); lineTo(10f, 19f)
        }
    }

    val plus = icon("mais") { stroke(2.2f) { moveTo(12f, 5f); lineTo(12f, 19f); moveTo(5f, 12f); lineTo(19f, 12f) } }
    val minus = icon("menos") { stroke(2.2f) { moveTo(5f, 12f); lineTo(19f, 12f) } }
}
