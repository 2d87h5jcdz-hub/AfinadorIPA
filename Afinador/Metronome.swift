import AVFoundation
import SwiftUI
import UIKit

final class Metronome: ObservableObject {
    @Published var bpm: Double {
        didSet { UserDefaults.standard.set(bpm, forKey: "bpm"); syncParams() }
    }
    @Published var beatsPerBar: Int {
        didSet { UserDefaults.standard.set(beatsPerBar, forKey: "beats"); syncParams() }
    }
    @Published var playing = false
    @Published var currentBeat = -1

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let lock = NSLock()
    private var sampleRate: Double = 44100

    // estado do áudio (protegido pelo lock)
    private var samplesPerBeat: Double = 22050
    private var beats = 4
    private var countdown: Double = 0
    private var beatIndex = 0
    private var clickPos = Int.max
    private var clickFreq: Double = 1000
    private var clickAmp: Double = 1
    private var active = false

    private var taps: [Date] = []

    struct Signature: Hashable {
        let label: String
        let beats: Int
    }
    static let signatures: [Signature] = [
        Signature(label: "2/4", beats: 2), Signature(label: "3/4", beats: 3),
        Signature(label: "4/4", beats: 4), Signature(label: "6/8", beats: 6),
    ]

    init() {
        let d = UserDefaults.standard
        let savedBpm = d.double(forKey: "bpm")
        bpm = savedBpm >= 30 ? savedBpm : 90
        let savedBeats = d.integer(forKey: "beats")
        beatsPerBar = savedBeats > 0 ? savedBeats : 4
    }

    var tempoName: String {
        switch bpm {
        case ..<60: return "Largo"
        case ..<76: return "Adagio"
        case ..<108: return "Andante"
        case ..<120: return "Moderato"
        case ..<168: return "Allegro"
        default: return "Presto"
        }
    }

    private func syncParams() {
        lock.lock()
        samplesPerBeat = sampleRate * 60.0 / bpm * (beatsPerBar == 6 ? 0.5 : 1.0)
        beats = beatsPerBar
        lock.unlock()
    }

    private func setup() {
        guard node == nil else { return }
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = outRate > 0 ? outRate : 44100
        let n = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self = self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let sr = self.sampleRate
            let clickLength = Int(sr * 0.035)
            self.lock.lock()
            for frame in 0..<Int(frameCount) {
                if self.active {
                    if self.countdown <= 0 {
                        let b = self.beatIndex
                        let accent: Bool = b == 0
                        let medium: Bool = self.beats == 6 && b == 3
                        self.clickFreq = accent ? 2000 : (medium ? 1500 : 1100)
                        self.clickAmp = accent ? 1.0 : (medium ? 0.75 : 0.55)
                        self.clickPos = 0
                        self.countdown += self.samplesPerBeat
                        self.beatIndex = (b + 1) % max(1, self.beats)
                        DispatchQueue.main.async { self.currentBeat = b }
                    }
                    self.countdown -= 1
                }
                var value: Float = 0
                if self.clickPos < clickLength {
                    let t = Double(self.clickPos) / sr
                    let env = exp(-t * 140.0)
                    value = Float(sin(2 * Double.pi * self.clickFreq * t) * env * self.clickAmp * 0.8)
                    self.clickPos += 1
                }
                for b in buffers {
                    b.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            self.lock.unlock()
            return noErr
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        node = n
    }

    func toggle() {
        playing ? stop() : start()
    }

    func start() {
        AudioSession.activate()
        setup()
        syncParams()
        lock.lock()
        countdown = 0
        beatIndex = 0
        active = true
        lock.unlock()
        if !engine.isRunning { try? engine.start() }
        playing = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        playing = false
        currentBeat = -1
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
        taps.append(now)
        if taps.count > 5 { taps.removeFirst() }
        guard taps.count >= 2 else { return }
        let total = now.timeIntervalSince(taps[0])
        let avg = total / Double(taps.count - 1)
        bpm = min(250, max(30, (60 / avg).rounded()))
    }
}

struct MetronomeView: View {
    @ObservedObject var metronome: Metronome

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 22) {
                HStack {
                    Text("Metrônomo")
                        .font(.system(size: 24, weight: .heavy, design: .serif))
                    Spacer()
                }

                beatDots

                VStack(spacing: 0) {
                    Text("\(Int(metronome.bpm))")
                        .font(.system(size: 110, weight: .heavy, design: .serif))
                        .monospacedDigit()
                    Text("BPM · \(metronome.tempoName)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.muted)
                }

                HStack(spacing: 14) {
                    roundButton("−5") { metronome.bpm = max(30, metronome.bpm - 5) }
                    roundButton("−1") { metronome.bpm = max(30, metronome.bpm - 1) }
                    Slider(value: $metronome.bpm, in: 30...250, step: 1)
                        .tint(Color.brass)
                    roundButton("+1") { metronome.bpm = min(250, metronome.bpm + 1) }
                    roundButton("+5") { metronome.bpm = min(250, metronome.bpm + 5) }
                }

                Picker("Compasso", selection: $metronome.beatsPerBar) {
                    ForEach(Metronome.signatures, id: \.beats) { s in
                        Text(s.label).tag(s.beats)
                    }
                }
                .pickerStyle(.segmented)

                Spacer(minLength: 0)

                HStack(spacing: 14) {
                    Button { metronome.tap() } label: {
                        Text("Tap")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 96)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(Color.panel))
                            .overlay(Capsule().stroke(Color.line))
                            .foregroundColor(.fg)
                    }
                    Button { metronome.toggle() } label: {
                        Label(metronome.playing ? "Parar" : "Iniciar",
                              systemImage: metronome.playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(metronome.playing ? Color.off : Color.brass))
                            .foregroundColor(.bg)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .foregroundColor(.fg)
    }

    private var beatDots: some View {
        HStack(spacing: 12) {
            ForEach(0..<metronome.beatsPerBar, id: \.self) { i in
                let on = metronome.currentBeat == i
                let accent = i == 0 || (metronome.beatsPerBar == 6 && i == 3)
                let fill: Color = on ? (i == 0 ? Color.ok : Color.brass) : Color.panel
                Circle()
                    .fill(fill)
                    .overlay(Circle().stroke(accent ? Color.brass : Color.line, lineWidth: accent ? 2 : 1))
                    .frame(width: accent ? 30 : 24, height: accent ? 30 : 24)
                    .scaleEffect(on ? 1.15 : 1)
                    .animation(.easeOut(duration: 0.08), value: on)
            }
        }
        .frame(height: 40)
        .padding(.top, 8)
    }

    private func roundButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.panel))
                .overlay(Circle().stroke(Color.line))
                .foregroundColor(.fg)
        }
    }
}
