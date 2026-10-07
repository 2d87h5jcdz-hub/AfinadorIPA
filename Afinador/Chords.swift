import AVFoundation
import Foundation

// MARK: - Dados

struct ChordQuality: Identifiable, Hashable {
    let id: String
    let suffix: String      // como aparece no nome: "m", "7M", "m7(♭5)"…
    let label: String       // nome por extenso
    let intervals: [Int]
    let degrees: [String]

    static let all: [ChordQuality] = [
        ChordQuality(id: "maj", suffix: "", label: "Maior", intervals: [0, 4, 7], degrees: ["1", "3", "5"]),
        ChordQuality(id: "m", suffix: "m", label: "Menor", intervals: [0, 3, 7], degrees: ["1", "♭3", "5"]),
        ChordQuality(id: "7", suffix: "7", label: "Sétima", intervals: [0, 4, 7, 10], degrees: ["1", "3", "5", "♭7"]),
        ChordQuality(id: "m7", suffix: "m7", label: "Menor com sétima", intervals: [0, 3, 7, 10], degrees: ["1", "♭3", "5", "♭7"]),
        ChordQuality(id: "maj7", suffix: "7M", label: "Sétima maior", intervals: [0, 4, 7, 11], degrees: ["1", "3", "5", "7"]),
        ChordQuality(id: "6", suffix: "6", label: "Sexta", intervals: [0, 4, 7, 9], degrees: ["1", "3", "5", "6"]),
        ChordQuality(id: "m6", suffix: "m6", label: "Menor com sexta", intervals: [0, 3, 7, 9], degrees: ["1", "♭3", "5", "6"]),
        ChordQuality(id: "sus2", suffix: "sus2", label: "Suspenso 2", intervals: [0, 2, 7], degrees: ["1", "2", "5"]),
        ChordQuality(id: "sus4", suffix: "sus4", label: "Suspenso 4", intervals: [0, 5, 7], degrees: ["1", "4", "5"]),
        ChordQuality(id: "add9", suffix: "(9)", label: "Com nona", intervals: [0, 4, 7, 2], degrees: ["1", "3", "5", "9"]),
        ChordQuality(id: "dim", suffix: "dim", label: "Diminuto", intervals: [0, 3, 6], degrees: ["1", "♭3", "♭5"]),
        ChordQuality(id: "m7b5", suffix: "m7(♭5)", label: "Meio-diminuto", intervals: [0, 3, 6, 10], degrees: ["1", "♭3", "♭5", "♭7"]),
        ChordQuality(id: "dim7", suffix: "°", label: "Diminuto com sétima", intervals: [0, 3, 6, 9], degrees: ["1", "♭3", "♭5", "𝄫7"]),
    ]
}

struct Voicing: Hashable {
    let frets: [Int]        // 6ª → 1ª corda; -1 = não tocar
    let barre: Int?         // casa da pestana, se houver

    var lowestFret: Int { frets.filter { $0 > 0 }.min() ?? 0 }
    var highestFret: Int { frets.max() ?? 0 }
}

enum ChordBook {
    static let rootNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    static let solfege = ["Dó", "Dó♯", "Ré", "Mi♭", "Mi", "Fá", "Fá♯", "Sol", "Lá♭", "Lá", "Si♭", "Si"]
    static let openMidi = [40, 45, 50, 55, 59, 64]

    // Formas móveis (deslocamento a partir da casa da pestana)
    private static let eShape: [String: [Int]] = [
        "maj": [0, 2, 2, 1, 0, 0], "m": [0, 2, 2, 0, 0, 0], "7": [0, 2, 0, 1, 0, 0],
        "m7": [0, 2, 0, 0, 0, 0], "maj7": [0, -1, 1, 1, 0, -1], "6": [0, 2, 2, 1, 2, 0],
        "sus4": [0, 2, 2, 2, 0, 0],
    ]
    private static let aShape: [String: [Int]] = [
        "maj": [-1, 0, 2, 2, 2, 0], "m": [-1, 0, 2, 2, 1, 0], "7": [-1, 0, 2, 0, 2, 0],
        "m7": [-1, 0, 2, 0, 1, 0], "maj7": [-1, 0, 2, 1, 2, 0], "6": [-1, 0, 2, 2, 2, 2],
        "m6": [-1, 0, 2, 2, 1, 2], "sus2": [-1, 0, 2, 2, 0, 0], "sus4": [-1, 0, 2, 2, 3, 0],
        "add9": [-1, 0, 2, 4, 2, 0], "dim": [-1, 0, 1, 2, 1, -1], "m7b5": [-1, 0, 1, 0, 1, -1],
        "dim7": [-1, 0, 1, 2, 1, 2],
    ]
    // Acordes abertos clássicos (fundamental 0 = C)
    private static let open: [String: [Int]] = [
        "0-maj": [-1, 3, 2, 0, 1, 0], "0-7": [-1, 3, 2, 3, 1, 0], "0-maj7": [-1, 3, 2, 0, 0, 0],
        "0-add9": [-1, 3, 2, 0, 3, 0], "0-sus4": [-1, 3, 3, 0, 1, 1],
        "2-maj": [-1, -1, 0, 2, 3, 2], "2-m": [-1, -1, 0, 2, 3, 1], "2-7": [-1, -1, 0, 2, 1, 2],
        "2-m7": [-1, -1, 0, 2, 1, 1], "2-maj7": [-1, -1, 0, 2, 2, 2], "2-sus2": [-1, -1, 0, 2, 3, 0],
        "2-sus4": [-1, -1, 0, 2, 3, 3], "2-6": [-1, -1, 0, 2, 0, 2], "2-dim": [-1, -1, 0, 1, 3, 1],
        "7-maj": [3, 2, 0, 0, 0, 3], "7-7": [3, 2, 0, 0, 0, 1], "7-maj7": [3, 2, 0, 0, 0, 2],
        "7-6": [3, 2, 0, 0, 0, 0], "7-sus4": [3, 3, 0, 0, 1, 3],
        "5-maj7": [-1, -1, 3, 2, 1, 0], "11-7": [-1, 2, 1, 2, 0, 2],
    ]

    static func name(root: Int, quality: ChordQuality) -> String {
        rootNames[root] + quality.suffix
    }

    static func notes(root: Int, quality: ChordQuality) -> [String] {
        quality.intervals.map { rootNames[(root + $0) % 12] }
    }

    static func voicings(root: Int, quality: ChordQuality) -> [Voicing] {
        var list: [Voicing] = []
        if let o = open["\(root)-\(quality.id)"] {
            list.append(Voicing(frets: o, barre: nil))
        }
        if let s = eShape[quality.id] {
            list.append(shift(s, by: (root - 4 + 12) % 12))
        }
        if let s = aShape[quality.id] {
            list.append(shift(s, by: (root - 9 + 12) % 12))
        }
        var seen = Set<[Int]>()
        let unique = list.filter { seen.insert($0.frets).inserted }
        return unique.sorted { a, b in
            let aOpen = a.barre == nil ? 0 : 1
            let bOpen = b.barre == nil ? 0 : 1
            if aOpen != bOpen { return aOpen < bOpen }
            return a.lowestFret < b.lowestFret
        }
    }

    private static func shift(_ shape: [Int], by f: Int) -> Voicing {
        let frets = shape.map { $0 < 0 ? -1 : $0 + f }
        return Voicing(frets: frets, barre: f > 0 ? f : nil)
    }

    static func midiNotes(_ v: Voicing) -> [Int] {
        var out: [Int] = []
        for (i, f) in v.frets.enumerated() where f >= 0 {
            out.append(openMidi[i] + f)
        }
        return out
    }
}

// MARK: - Som de violão (Karplus-Strong)

final class ChordPlayer {
    private struct Voice {
        var buffer: [Float]
        var index: Int
        var delay: Int
    }

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var voices: [Voice] = []
    private let lock = NSLock()
    private var sampleRate: Double = 44100

    private func setup() {
        guard node == nil else { return }
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = outRate > 0 ? outRate : 44100
        let n = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self = self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            self.lock.lock()
            for frame in 0..<Int(frameCount) {
                var s: Float = 0
                for v in 0..<self.voices.count {
                    if self.voices[v].delay > 0 {
                        self.voices[v].delay -= 1
                        continue
                    }
                    let count = self.voices[v].buffer.count
                    let i = self.voices[v].index
                    let next = (i + 1) % count
                    let out = self.voices[v].buffer[i]
                    self.voices[v].buffer[i] = 0.4985 * (out + self.voices[v].buffer[next])
                    self.voices[v].index = next
                    s += out
                }
                let value = s * 0.22
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

    func play(midis: [Int], a4: Double) {
        AudioSession.activate()
        setup()
        if !engine.isRunning { try? engine.start() }
        var newVoices: [Voice] = []
        for (k, m) in midis.enumerated() {
            let f = a4 * pow(2, Double(m - 69) / 12)
            let length = max(2, Int(sampleRate / f))
            var buf = [Float](repeating: 0, count: length)
            for j in 0..<length { buf[j] = Float.random(in: -1...1) }
            // suaviza o ruído inicial para um ataque menos áspero
            for j in 1..<length { buf[j] = 0.5 * (buf[j] + buf[j - 1]) }
            newVoices.append(Voice(buffer: buf, index: 0, delay: Int(Double(k) * 0.03 * sampleRate)))
        }
        lock.lock()
        voices = newVoices
        lock.unlock()
    }
}
