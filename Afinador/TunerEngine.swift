import AVFoundation
import Foundation
import UIKit

struct Tuning: Identifiable, Hashable {
    let name: String
    let midi: [Int]   // 6ª corda → 1ª corda
    var id: String { name }

    static let all: [Tuning] = [
        Tuning(name: "Padrão (E A D G B E)", midi: [40, 45, 50, 55, 59, 64]),
        Tuning(name: "Drop D (D A D G B E)", midi: [38, 45, 50, 55, 59, 64]),
        Tuning(name: "Meio tom abaixo (E♭)", midi: [39, 44, 49, 54, 58, 63]),
        Tuning(name: "Um tom abaixo (D G C F A D)", midi: [38, 43, 48, 53, 57, 62]),
        Tuning(name: "Open G (D G D G B D)", midi: [38, 43, 50, 55, 59, 62]),
        Tuning(name: "DADGAD", midi: [38, 45, 50, 55, 57, 62]),
    ]
}

enum Note {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func name(_ m: Int) -> String { names[((m % 12) + 12) % 12] }
    static func octave(_ m: Int) -> Int { Int(floor(Double(m) / 12.0)) - 1 }
}

final class TunerEngine: ObservableObject {
    // Estado publicado para a interface
    @Published var running = false
    @Published var permissionDenied = false
    @Published var frequency: Double? = nil
    @Published var targetMidi: Int? = nil
    @Published var cents: Int = 0
    @Published var stringIndex: Int? = nil
    @Published var tunedStrings = Set<Int>()

    @Published var tuning: Tuning {
        didSet { UserDefaults.standard.set(tuning.name, forKey: "tuning"); tunedStrings.removeAll() }
    }
    @Published var a4: Double {
        didSet { UserDefaults.standard.set(a4, forKey: "a4") }
    }
    @Published var autoMode: Bool {
        didSet { UserDefaults.standard.set(autoMode, forKey: "auto") }
    }
    @Published var manualIndex = 0

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "afinador.analysis")
    private var samples: [Float] = []
    private let window = 4096
    private let hop = 2048
    private var sampleRate: Double = 48000
    private var history: [Double] = []
    private var silentFrames = 0
    private var inTuneSince: Date? = nil

    // Tom de referência
    private var toneNode: AVAudioSourceNode?
    private var tonePhase: Double = 0
    private var toneFreq: Double = 0
    private var toneGain: Double = 0
    private let toneLock = NSLock()

    init() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "tuning")
        tuning = Tuning.all.first { $0.name == saved } ?? Tuning.all[0]
        let savedA4 = d.double(forKey: "a4")
        a4 = savedA4 > 0 ? savedA4 : 440
        autoMode = d.object(forKey: "auto") as? Bool ?? true
    }

    func hz(_ midi: Int) -> Double { a4 * pow(2, Double(midi - 69) / 12) }
    func midiValue(_ f: Double) -> Double { 69 + 12 * log2(f / a4) }

    // MARK: - Início

    func start() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { self.startEngine() } else { self.permissionDenied = true }
            }
        }
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do {
            AudioSession.activate()

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            sampleRate = format.sampleRate

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self = self, let ch = buffer.floatChannelData?[0] else { return }
                let n = Int(buffer.frameLength)
                let chunk = Array(UnsafeBufferPointer(start: ch, count: n))
                self.analysisQueue.async { self.ingest(chunk) }
            }

            if toneNode == nil {
                attachToneNode(sampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate)
            }
            engine.prepare()
            try engine.start()
            running = true
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        analysisQueue.async { self.samples.removeAll() }
        history.removeAll()
        clearReading()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Análise

    private func ingest(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        while samples.count >= window {
            let frame = Array(samples[0..<window])
            samples.removeFirst(hop)
            let f = Self.yin(frame, sampleRate: sampleRate)
            DispatchQueue.main.async { self.handle(f) }
        }
    }

    private func handle(_ f: Double?) {
        guard let f = f, f > 60, f < 1200 else {
            silentFrames += 1
            if silentFrames > 6 { history.removeAll(); clearReading() }
            return
        }
        silentFrames = 0
        history.append(f)
        if history.count > 5 { history.removeFirst() }
        let median = history.sorted()[history.count / 2]
        show(median)
    }

    private func show(_ f: Double) {
        let notes = tuning.midi
        let m = midiValue(f)
        var target: Int
        var idx: Int?

        if autoMode {
            var best = Double.infinity
            var bestIdx = 0
            for (i, n) in notes.enumerated() {
                let d = abs(m - Double(n))
                if d < best { best = d; bestIdx = i }
            }
            if best <= 2.5 { target = notes[bestIdx]; idx = bestIdx }
            else { target = Int(m.rounded()); idx = nil }
        } else {
            idx = manualIndex
            target = notes[manualIndex]
            while m - Double(target) > 6 { target += 12 }
            while Double(target) - m > 6 { target -= 12 }
        }

        let c = Int(((m - Double(target)) * 100).rounded())
        frequency = f
        targetMidi = target
        cents = c
        stringIndex = idx

        if abs(c) <= 5 {
            if let since = inTuneSince {
                if let i = idx, Date().timeIntervalSince(since) > 0.7, !tunedStrings.contains(i) {
                    tunedStrings.insert(i)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } else { inTuneSince = Date() }
        } else {
            inTuneSince = nil
        }
    }

    private func clearReading() {
        frequency = nil
        targetMidi = nil
        cents = 0
        stringIndex = nil
        inTuneSince = nil
    }

    /// Detector de frequência fundamental YIN
    static func yin(_ x: [Float], sampleRate sr: Double) -> Double? {
        var rms: Float = 0
        for v in x { rms += v * v }
        rms = sqrt(rms / Float(x.count))
        if rms < 0.006 { return nil }

        let w = x.count / 2
        let minTau = Int(sr / 1000)
        let maxTau = min(Int(sr / 60), w - 1)
        var d = [Float](repeating: 0, count: maxTau + 2)

        x.withUnsafeBufferPointer { p in
            for tau in 1...maxTau {
                var s: Float = 0
                for i in 0..<w {
                    let v = p[i] - p[i + tau]
                    s += v * v
                }
                d[tau] = s
            }
        }
        d[0] = 1
        var running: Float = 0
        for t in 1...maxTau {
            running += d[t]
            d[t] = running > 0 ? d[t] * Float(t) / running : 1
        }

        var tau = -1
        var t = minTau
        while t <= maxTau {
            if d[t] < 0.12 {
                while t + 1 <= maxTau && d[t + 1] < d[t] { t += 1 }
                tau = t
                break
            }
            t += 1
        }
        guard tau > 1, tau < maxTau else { return nil }

        let a = Double(d[tau - 1]), b = Double(d[tau]), c = Double(d[tau + 1])
        let denom = a - 2 * b + c
        let shift = denom != 0 ? (a - c) / (2 * denom) : 0
        return sr / (Double(tau) + (shift.isFinite ? shift : 0))
    }

    // MARK: - Tom de referência

    private func attachToneNode(sampleRate: Double) {
        let sr = sampleRate > 0 ? sampleRate : 48000
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self = self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            self.toneLock.lock()
            var phase = self.tonePhase
            var gain = self.toneGain
            let freq = self.toneFreq
            self.toneLock.unlock()

            let decay = pow(0.001, 1.0 / (2.2 * sr))
            for frame in 0..<Int(frameCount) {
                let v1 = sin(phase)
                let v2 = 0.25 * sin(2 * phase)
                let value = Float((v1 + v2) * gain * 0.35)
                phase += 2 * .pi * freq / sr
                if phase > 2 * .pi { phase -= 2 * .pi }
                gain *= decay
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            self.toneLock.lock()
            self.tonePhase = phase
            self.toneGain = gain
            self.toneLock.unlock()
            return noErr
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        toneNode = node
    }

    func playReference(_ index: Int) {
        if !engine.isRunning { start() }
        toneLock.lock()
        toneFreq = hz(tuning.midi[index])
        toneGain = 1
        tonePhase = 0
        toneLock.unlock()
    }
}
