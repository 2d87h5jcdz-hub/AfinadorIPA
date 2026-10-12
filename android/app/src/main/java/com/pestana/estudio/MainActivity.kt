package com.pestana.estudio

import android.graphics.Color
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
        setContent {
            PestanaTheme {
                PestanaApp()
            }
        }
    }
}
