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

struct ContentView: View {
    @StateObject private var tuner = TunerEngine()
    @StateObject private var metronome = Metronome()
    @State private var tab = 0

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
                .tabItem { Label("Afinador", systemImage: "tuningfork") }
                .tag(0)
            ChordsView(a4: tuner.a4)
                .tabItem { Label("Acordes", systemImage: "guitars") }
                .tag(1)
            MetronomeView(metronome: metronome)
                .tabItem { Label("Metrônomo", systemImage: "metronome") }
                .tag(2)
        }
        .tint(Color.brass)
    }
}
