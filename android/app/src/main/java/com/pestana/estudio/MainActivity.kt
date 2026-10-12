package com.pestana.estudio

import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.pestana.estudio.ui.PestanaTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bg = Color.rgb(0x16, 0x12, 0x0F)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(bg),
            navigationBarStyle = SystemBarStyle.dark(bg),
        )
        handle(intent)
        setContent {
            PestanaTheme {
                PestanaApp()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Áudio aberto/compartilhado de outro app → importa no Treino. */
    private fun handle(intent: Intent?) {
        val uri: Uri? = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri != null) IncomingAudio.uri.value = uri
    }
}

/** Ponte entre o Intent recebido e a interface (consumida pelo PestanaApp). */
object IncomingAudio {
    val uri = androidx.compose.runtime.mutableStateOf<Uri?>(null)
}
