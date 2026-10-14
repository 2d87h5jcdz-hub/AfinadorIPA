import AVFoundation
import SwiftUI
import UIKit

enum AudioSession {
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try? s.setActive(true)
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var tuner = TunerEngine()
    @StateObject private var metronome = Metronome()
    @StateObject private var studio = StudioEngine()
    @StateObject private var looper = LooperEngine()
    @State private var tab = 0
    /// Aviso de boas-vindas (gratuito / doação) só na primeira abertura.
    @AppStorage("about.welcomeShown") private var welcomeShown = false

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.086, green: 0.071, blue: 0.059, alpha: 1)
        appearance.shadowColor = UIColor(red: 0.227, green: 0.188, blue: 0.161, alpha: 1)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $tab) {
            TunerView(tuner: tuner)
                .statusBarCover()
                .tabItem { Label("Afinador", systemImage: "tuningfork") }
                .tag(0)
            ChordsView(a4: tuner.a4)
                .statusBarCover()
                .tabItem { Label("Acordes", systemImage: "guitars") }
                .tag(1)
            MetronomeView(metronome: metronome)
                .statusBarCover()
                .tabItem { Label("Metrônomo", systemImage: "metronome") }
                .tag(2)
            StudioView(studio: studio)
                .statusBarCover()
                .tabItem { Label("Estúdio", systemImage: "waveform") }
                .tag(3)
            PracticeView(studio: studio, openStudio: { tab = 3 })
                .statusBarCover()
                .tabItem { Label("Treino", systemImage: "music.note.list") }
                .tag(4)
            LoopView(looper: looper)
                .statusBarCover()
                .tabItem { Label("Loop", systemImage: "repeat.circle") }
                .tag(5)
        }
        .sheet(isPresented: Binding(get: { !welcomeShown }, set: { if !$0 { welcomeShown = true } })) {
            AboutView(isWelcome: true)
        }
        .tint(Color.brass)
        .onChange(of: tab) { newTab in
            // O metrônomo da aba própria vazaria nas gravações e brigaria com o clique do Estúdio/Treino.
            if newTab >= 3 && metronome.playing { metronome.stop() }
        }
    }
}

/// Faixa da cor do fundo atrás da barra de status: o conteúdo que rola não passa por baixo
/// do relógio e da bateria (na horizontal a altura é zero e nada aparece).
struct StatusBarCover: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            // O leitor ocupa a tela toda; safeAreaInsets.top é a altura da barra de status.
            GeometryReader { geo in
                Color.bg
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.safeAreaInsets.top)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func statusBarCover() -> some View { modifier(StatusBarCover()) }
}
