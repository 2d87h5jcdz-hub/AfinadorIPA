import Foundation
import AVFoundation
import Accelerate

// MARK: - Afinação automática (correção sutil de voz, feita DEPOIS de gravar)
//
// Como funciona (validado num protótipo em Python com vozes sintéticas antes de vir para cá):
// 1. Detecta a nota cantada a cada ~5 ms (YIN, numa cópia do áudio reduzida para ~11 kHz).
// 2. Limpa a curva: corrige saltos de oitava, filtro de mediana, descarta trechos curtíssimos.
// 3. Divide a voz em notas (curva suavizada ~180 ms → nota da escala mais próxima, com histerese).
// 4. Para cada nota: desvio = nota-alvo − mediana do que foi cantado. A correção é UM valor por
//    nota (vezes a intensidade), então vibrato, deslizes e expressão ficam intactos — só o
//    "centro" da nota vai para o lugar. Notas já afinadas (< 4 cents) não são tocadas.
// 5. Rampa de ~45 ms entre notas e muda o tom com TD-PSOLA (grãos de 2 períodos, janela Hann,
//    normalizado pela soma das janelas). Sem voz (consoantes, respiração), a razão é 1 e o áudio
//    passa igual. Com intensidade 0 a saída é idêntica à entrada.
//
// O arquivo original nunca é alterado: o resultado vai para "<arquivo>.tune-<assinatura>.caf"
// na pasta do projeto e a reprodução/exportação usam essa cópia quando ela existe.

enum PitchScale: String, Codable, CaseIterable, Identifiable {
    case major, minor, chromatic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .major: return "Maior"
        case .minor: return "Menor"
        case .chromatic: return "Cromática"
        }
    }

    var intervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .chromatic: return Array(0..<12)
        }
    }
}

/// Ajustes da afinação automática de uma faixa.
struct PitchCorrection: Codable, Equatable {
    var enabled: Bool = false
    /// 0…11 = Dó…Si; -1 = automático (detectado pela própria voz).
    var key: Int = -1
    var scale: PitchScale = .major
    /// 0…1: quanto do desvio é corrigido. 0,8 deixa um resíduo pequeno de propósito (soa humano).
    var strength: Float = 0.8
    /// Preenchidos pelo app quando `key == -1`.
    var detectedKey: Int?
    var detectedScale: PitchScale?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, key, scale, strength, detectedKey, detectedScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? -1
        scale = try c.decodeIfPresent(PitchScale.self, forKey: .scale) ?? .major
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? 0.8
        detectedKey = try c.decodeIfPresent(Int.self, forKey: .detectedKey)
        detectedScale = try c.decodeIfPresent(PitchScale.self, forKey: .detectedScale)
    }

    var isAuto: Bool { key < 0 }
    var resolvedKey: Int? { key >= 0 ? key : detectedKey }
    var resolvedScale: PitchScale { key >= 0 ? scale : (detectedScale ?? .major) }

    /// Identifica o resultado (vai no nome do arquivo corrigido). nil = desligado ou tom ainda desconhecido.
    var signature: String? {
        guard enabled, let k = resolvedKey else { return nil }
        let pct: Int = Int((min(max(strength, 0), 1) * 100).rounded())
        return "\(k)\(resolvedScale.rawValue.prefix(3))\(pct)"
    }

    static let noteNames: [String] = ["Dó", "Dó♯", "Ré", "Mi♭", "Mi", "Fá", "Fá♯", "Sol", "Lá♭", "Lá", "Si♭", "Si"]

    static func keyTitle(_ key: Int, _ scale: PitchScale) -> String {
        let name: String = noteNames[((key % 12) + 12) % 12]
        switch scale {
        case .major: return "\(name) maior"
        case .minor: return "\(name) menor"
        case .chromatic: return "cromática"
        }
    }
}

// MARK: - Arquivos corrigidos

enum StudioPitchFiles {
    static func tunedName(source: String, signature: String) -> String {
        "\(source).tune-\(signature).caf"
    }

    static func tunedPrefix(source: String) -> String { "\(source).tune-" }

    /// Clips como devem TOCAR: com a afinação ligada e o arquivo corrigido pronto, aponta para ele.
    static func playbackClips(for track: StudioTrack, folder: URL) -> [StudioClip] {
        guard let signature = track.pitch.signature else { return track.clips }
        let fm = FileManager.default
        return track.clips.map { clip in
            let tuned: String = tunedName(source: clip.fileName, signature: signature)
            guard fm.fileExists(atPath: folder.appendingPathComponent(tuned).path) else { return clip }
            var copy = clip
            copy.fileName = tuned
            return copy
        }
    }

    /// Todos os arquivos já corrigidos existem?
    static func isReady(track: StudioTrack, folder: URL) -> Bool {
        guard let signature = track.pitch.signature else { return false }
        let fm = FileManager.default
        let sources: Set<String> = Set(track.clips.map(\.fileName))
        return sources.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent(tunedName(source: $0, signature: signature)).path) }
    }

    /// Apaga versões corrigidas antigas de `source` (outra assinatura).
    static func removeStale(source: String, keeping signature: String, folder: URL) {
        let fm = FileManager.default
        let prefix: String = tunedPrefix(source: source)
        let keep: String = tunedName(source: source, signature: signature)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && name != keep {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

// MARK: - Trabalho completo de uma faixa (roda fora da thread principal)

enum StudioPitchJob {
    struct Outcome {
        var detectedKey: Int?
        var detectedScale: PitchScale?
        var completed: Bool = false
        var noVoice: Bool = false
    }

    /// Analisa (se precisar descobrir o tom) e gera as cópias corrigidas que faltam.
    static func run(folder: URL, sources: [String], settings: PitchCorrection,
                    progress: (Double) -> Void, isCancelled: () -> Bool) -> Outcome {
        var outcome = Outcome()
        var cache: [String: StudioPitchDSP.Analysis] = [:]
        var key: Int? = settings.resolvedKey
        var scale: PitchScale = settings.resolvedScale

        if key == nil {
            // Descobre o tom pela voz de todos os trechos da faixa.
            var all: [Float] = []
            for (i, source) in sources.enumerated() {
                if isCancelled() { return outcome }
                guard let audio = StudioPitchDSP.load(folder.appendingPathComponent(source)) else { continue }
                let analysis = StudioPitchDSP.analyze(mono: audio.mono, sampleRate: audio.sampleRate)
                cache[source] = analysis
                all.append(contentsOf: analysis.midi)
                progress(0.4 * Double(i + 1) / Double(max(sources.count, 1)))
            }
            guard let found = StudioPitchDSP.detectKey(all) else {
                outcome.noVoice = true
                return outcome
            }
            key = found.key
            scale = found.scale
            outcome.detectedKey = found.key
            outcome.detectedScale = found.scale
        }
        guard let resolvedKey = key else { return outcome }

        var resolved = settings
        resolved.key = resolvedKey
        resolved.scale = scale
        guard let signature = resolved.signature else { return outcome }

        let base: Double = settings.resolvedKey == nil ? 0.4 : 0
        for (i, source) in sources.enumerated() {
            if isCancelled() { return outcome }
            let dest: URL = folder.appendingPathComponent(StudioPitchFiles.tunedName(source: source, signature: signature))
            if !FileManager.default.fileExists(atPath: dest.path) {
                StudioPitchDSP.process(source: folder.appendingPathComponent(source), destination: dest,
                                       key: resolvedKey, scale: scale, strength: settings.strength,
                                       analysis: cache[source], isCancelled: isCancelled)
            }
            StudioPitchFiles.removeStale(source: source, keeping: signature, folder: folder)
            progress(base + (1 - base) * Double(i + 1) / Double(max(sources.count, 1)))
        }
        outcome.completed = !isCancelled()
        return outcome
    }
}

// MARK: - Processamento de sinal

enum StudioPitchDSP {
    struct Analysis {
        /// Nota MIDI (fracionária) por quadro; NaN = sem voz.
        var midi: [Float]
        /// Passo entre quadros, em amostras do arquivo original.
        var hop: Int
        /// Atraso do centro da janela de análise, em amostras originais.
        var center: Int
    }

    struct Audio {
        var channels: [[Float]]
        var mono: [Float]
        var sampleRate: Double
        var format: AVAudioFormat
    }

    // MARK: Leitura / escrita

    static func load(_ url: URL) -> Audio? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format: AVAudioFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let data = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard count > 0, channelCount > 0 else { return nil }
        var channels: [[Float]] = []
        var mono = [Float](repeating: 0, count: count)
        let scale: Float = 1 / Float(channelCount)
        for ch in 0..<channelCount {
            let samples = Array(UnsafeBufferPointer(start: data[ch], count: count))
            channels.append(samples)
            for i in 0..<count { mono[i] += samples[i] * scale }
        }
        return Audio(channels: channels, mono: mono, sampleRate: format.sampleRate, format: format)
    }

    /// Gera a cópia corrigida. Escreve num arquivo temporário e renomeia no fim (nunca deixa meio arquivo).
    @discardableResult
    static func process(source: URL, destination: URL, key: Int, scale: PitchScale, strength: Float,
                        analysis cached: Analysis?, isCancelled: () -> Bool) -> Bool {
        guard let audio = load(source) else { return false }
        let analysis: Analysis = cached ?? analyze(mono: audio.mono, sampleRate: audio.sampleRate)
        if isCancelled() { return false }
        let curve: [Float] = correction(analysis.midi, key: key, scale: scale, strength: strength)
        var ratio = [Float](repeating: 1, count: curve.count)
        for i in 0..<curve.count { ratio[i] = powf(2, curve[i] / 12) }
        if isCancelled() { return false }
        let output: [[Float]] = psola(channels: audio.channels, sampleRate: audio.sampleRate,
                                      analysis: analysis, ratio: ratio)
        if isCancelled() { return false }
        return write(output, format: audio.format, to: destination)
    }

    private static func write(_ channels: [[Float]], format: AVAudioFormat, to url: URL) -> Bool {
        guard let first = channels.first, !first.isEmpty else { return false }
        let count = first.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { return false }
        buffer.frameLength = AVAudioFrameCount(count)
        for (ch, samples) in channels.enumerated() where ch < Int(format.channelCount) {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                data[ch].update(from: base, count: count)
            }
        }
        let temp: URL = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: temp, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        do {
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    // MARK: Detecção de nota (YIN)

    /// Filtro passa-baixa FIR (sinc janelado Hamming), corte relativo a Nyquist (como scipy.firwin).
    private static func lowpass(taps: Int, cutoff: Float) -> [Float] {
        var h = [Float](repeating: 0, count: taps)
        let mid = Float(taps - 1) / 2
        var sum: Float = 0
        for n in 0..<taps {
            let x = Float(n) - mid
            let sinc: Float = x == 0 ? 1 : sinf(Float.pi * cutoff * x) / (Float.pi * cutoff * x)
            let window: Float = 0.54 - 0.46 * cosf(2 * Float.pi * Float(n) / Float(taps - 1))
            h[n] = cutoff * sinc * window
            sum += h[n]
        }
        if sum != 0 {
            for n in 0..<taps { h[n] /= sum }
        }
        return h
    }

    static func analyze(mono: [Float], sampleRate: Double) -> Analysis {
        let factor: Int = max(1, Int((sampleRate / 11025).rounded()))
        let taps: Int = 63
        var y: [Float]
        if factor > 1 {
            let n: Int = (mono.count - taps) / factor
            guard n > 0 else { return Analysis(midi: [], hop: 1, center: 0) }
            let h: [Float] = lowpass(taps: taps, cutoff: 0.8 / Float(factor))
            y = [Float](repeating: 0, count: n)
            vDSP_desamp(mono, vDSP_Stride(factor), h, &y, vDSP_Length(n), vDSP_Length(taps))
        } else {
            y = mono
        }
        let asr: Double = sampleRate / Double(factor)
        let window: Int = max(16, Int(asr * 0.027))
        let tauMax: Int = Int(asr / 70) + 1
        let tauMin: Int = max(2, Int(asr / 1000))
        let hop: Int = max(1, Int((asr * 0.005).rounded()))
        let center: Int = (window / 2) * factor + (factor > 1 ? (taps - 1) / 2 : 0)
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(mono.count))
        let gate: Float = max(peak, 1e-9) * 0.02

        guard y.count > window + tauMax + 1 else {
            return Analysis(midi: [], hop: hop * factor, center: center)
        }
        // Somas acumuladas dos quadrados (Double para não perder precisão em arquivos longos).
        var cs = [Double](repeating: 0, count: y.count + 1)
        for i in 0..<y.count { cs[i + 1] = cs[i] + Double(y[i] * y[i]) }

        var midi: [Float] = []
        midi.reserveCapacity(y.count / hop + 1)
        var d = [Float](repeating: 0, count: tauMax + 2)
        var cm = [Float](repeating: 1, count: tauMax + 2)
        y.withUnsafeBufferPointer { yp in
            guard let base = yp.baseAddress else { return }
            var i: Int = 0
            while i + window + tauMax <= y.count {
                let frame = base + i
                let e0: Float = Float(cs[i + window] - cs[i])
                let rms: Float = sqrtf(max(e0, 0) / Float(window))
                if rms <= gate {
                    midi.append(Float.nan)
                    i += hop
                    continue
                }
                for tau in 1...tauMax {
                    let et: Float = Float(cs[i + tau + window] - cs[i + tau])
                    var r: Float = 0
                    vDSP_dotpr(frame, 1, frame + tau, 1, &r, vDSP_Length(window))
                    d[tau] = e0 + et - 2 * r
                }
                var running: Float = 0
                cm[0] = 1
                for tau in 1...tauMax {
                    running += d[tau]
                    cm[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
                }
                var best: Int = -1
                var tau: Int = tauMin
                while tau <= tauMax {
                    if cm[tau] < 0.15 {
                        while tau + 1 <= tauMax && cm[tau + 1] < cm[tau] { tau += 1 }
                        best = tau
                        break
                    }
                    tau += 1
                }
                if best < 0 {
                    var minValue: Float = .greatestFiniteMagnitude
                    for t in tauMin...tauMax where cm[t] < minValue {
                        minValue = cm[t]
                        best = t
                    }
                }
                let aperiodicity: Float = cm[best]
                var period: Float = Float(best)
                if best >= 1 && best < tauMax {
                    let s0: Float = cm[best - 1], s1: Float = cm[best], s2: Float = cm[best + 1]
                    let den: Float = s0 - 2 * s1 + s2
                    if abs(den) > 1e-12 { period = Float(best) + 0.5 * (s0 - s2) / den }
                }
                let f0: Float = Float(asr) / max(period, 1)
                if aperiodicity < 0.25 && f0 >= 70 && f0 <= 1000 {
                    midi.append(69 + 12 * log2f(f0 / 440))
                } else {
                    midi.append(Float.nan)
                }
                i += hop
            }
        }
        return Analysis(midi: clean(midi), hop: hop * factor, center: center)
    }

    /// Saltos de oitava, mediana de 5 e remoção de trechos com voz curtos demais (< 7 quadros).
    static func clean(_ input: [Float]) -> [Float] {
        var m = input
        let n = m.count
        guard n > 0 else { return m }
        for i in 0..<n where !m[i].isNaN {
            let lo = max(0, i - 20), hi = min(n, i + 21)
            var window: [Float] = []
            for j in lo..<hi where !input[j].isNaN { window.append(input[j]) }
            guard window.count >= 5 else { continue }
            let med = median(&window)
            while m[i] - med > 9 { m[i] -= 12 }
            while med - m[i] > 9 { m[i] += 12 }
        }
        var out = m
        for i in 0..<n where !m[i].isNaN {
            var window: [Float] = []
            for j in max(0, i - 2)..<min(n, i + 3) where !m[j].isNaN { window.append(m[j]) }
            out[i] = median(&window)
        }
        var i = 0
        while i < n {
            if out[i].isNaN { i += 1; continue }
            var j = i
            while j < n && !out[j].isNaN { j += 1 }
            if j - i < 7 {
                for k in i..<j { out[k] = Float.nan }
            }
            i = j
        }
        return out
    }

    private static func median(_ values: inout [Float]) -> Float {
        guard !values.isEmpty else { return Float.nan }
        values.sort()
        let c = values.count
        return c % 2 == 1 ? values[c / 2] : 0.5 * (values[c / 2 - 1] + values[c / 2])
    }

    // MARK: Tom da música (Krumhansl-Schmuckler)

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detectKey(_ midi: [Float]) -> (key: Int, scale: PitchScale)? {
        var histogram = [Float](repeating: 0, count: 12)
        var voiced = 0
        for v in midi where !v.isNaN {
            let pc = ((Int(v.rounded()) % 12) + 12) % 12
            histogram[pc] += 1
            voiced += 1
        }
        guard voiced >= 40 else { return nil }      // < ~0,2 s de voz: não dá para saber
        var best: (score: Float, key: Int, scale: PitchScale)?
        for key in 0..<12 {
            for (profile, scale) in [(majorProfile, PitchScale.major), (minorProfile, PitchScale.minor)] {
                var rotated = [Float](repeating: 0, count: 12)
                for i in 0..<12 { rotated[(i + key) % 12] = profile[i] }
                let score = correlation(histogram, rotated)
                if best == nil || score > best!.score { best = (score, key, scale) }
            }
        }
        guard let found = best else { return nil }
        return (found.key, found.scale)
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = sqrtf(da * db)
        return den > 0 ? num / den : 0
    }

    // MARK: Curva de correção

    /// Nota da escala mais próxima de `v` (MIDI fracionário).
    static func quantize(_ v: Float, key: Int, scale: PitchScale) -> Float {
        let classes: Set<Int> = Set(scale.intervals.map { (key + $0) % 12 })
        let base: Float = v.rounded(.down)
        var best: (distance: Float, note: Float)?
        for o in -2...2 {
            let candidate: Float = base + Float(o)
            let pc = ((Int(candidate) % 12) + 12) % 12
            guard classes.contains(pc) else { continue }
            let distance = abs(candidate - v)
            if best == nil || distance < best!.distance { best = (distance, candidate) }
        }
        return best?.note ?? v.rounded()
    }

    /// Correção em semitons por quadro (0 sem voz), já suavizada nas trocas de nota.
    static func correction(_ m: [Float], key: Int, scale: PitchScale, strength: Float) -> [Float] {
        let n = m.count
        var c = [Float](repeating: 0, count: n)
        let amount: Float = min(max(strength, 0), 1)
        var i = 0
        while i < n {
            if m[i].isNaN { i += 1; continue }
            var j = i
            while j < n && !m[j].isNaN { j += 1 }
            let length = j - i
            // Média móvel de ±18 quadros (~180 ms): tira o vibrato para achar a nota pretendida.
            var prefix = [Float](repeating: 0, count: length + 1)
            for t in 0..<length { prefix[t + 1] = prefix[t] + m[i + t] }
            var notes = [Float](repeating: 0, count: length)
            for t in 0..<length {
                let lo = max(0, t - 18), hi = min(length, t + 19)
                let smooth = (prefix[hi] - prefix[lo]) / Float(hi - lo)
                notes[t] = quantize(smooth, key: key, scale: scale)
            }
            // Segmentos de mesma nota; troca só vale se durar >= 12 quadros (~60 ms).
            var segments: [(start: Int, end: Int)] = []
            var start = 0
            for t in 1...length {
                if t == length || notes[t] != notes[start] {
                    segments.append((start, t))
                    start = t
                }
            }
            var merged: [(start: Int, end: Int)] = []
            for seg in segments {
                if !merged.isEmpty && seg.end - seg.start < 12 {
                    merged[merged.count - 1].end = seg.end
                } else {
                    merged.append(seg)
                }
            }
            if merged.count > 1 && merged[0].end - merged[0].start < 12 {
                merged[1].start = merged[0].start
                merged.removeFirst()
            }
            for seg in merged {
                var values: [Float] = Array(m[(i + seg.start)..<(i + seg.end)])
                let center = median(&values)
                let target = quantize(center, key: key, scale: scale)
                var offset = target - center
                if abs(offset) < 0.04 { offset = 0 }
                for t in seg.start..<seg.end { c[i + t] = offset * amount }
            }
            i = j
        }
        // Rampa de ±4 quadros (~45 ms) entre valores.
        var prefix = [Float](repeating: 0, count: n + 1)
        for t in 0..<n { prefix[t + 1] = prefix[t] + c[t] }
        var smooth = [Float](repeating: 0, count: n)
        for t in 0..<n {
            let lo = max(0, t - 4), hi = min(n, t + 5)
            smooth[t] = (prefix[hi] - prefix[lo]) / Float(hi - lo)
        }
        return smooth
    }

    // MARK: Mudança de tom (TD-PSOLA)

    static func psola(channels: [[Float]], sampleRate: Double, analysis: Analysis, ratio: [Float]) -> [[Float]] {
        guard let first = channels.first else { return channels }
        let length = first.count
        let frames = analysis.midi.count
        guard length > 0, frames > 0 else { return channels }
        let hop = Double(max(analysis.hop, 1))
        let center = Double(analysis.center)

        func frameIndex(_ position: Double) -> Int {
            let f = Int(((position - center) / hop).rounded(.down))
            return min(max(f, 0), frames - 1)
        }
        let unvoicedPeriod: Double = sampleRate * 0.006
        func period(at position: Double) -> Double {
            let m = analysis.midi[frameIndex(position)]
            if m.isNaN { return unvoicedPeriod }
            let f0 = 440 * pow(2, Double(m - 69) / 12)
            return min(max(sampleRate / f0, 8), sampleRate * 0.02)
        }
        func ratioAt(_ position: Double) -> Double {
            let r = Double(ratio[frameIndex(position)])
            return r.isFinite && r > 0.5 && r < 2 ? r : 1
        }

        // Marcas de análise: espaçadas pelo período local.
        var marks: [Double] = []
        marks.reserveCapacity(Int(Double(length) / 100))
        var p: Double = 0
        while p < Double(length) {
            marks.append(p)
            p += period(at: p)
        }

        let channelCount = channels.count
        var output = [[Float]](repeating: [Float](repeating: 0, count: length), count: channelCount)
        var weights = [Float](repeating: 0, count: length)
        var ts: Double = 0
        var k = 0
        var window: [Float] = []
        while ts < Double(length) {
            while k + 1 < marks.count && abs(marks[k + 1] - ts) < abs(marks[k] - ts) { k += 1 }
            let a = marks[k]
            let T = period(at: a)
            let r = ratioAt(ts)
            let half = Int(T.rounded(.down))
            let count = 2 * half + 1
            if window.count != count {
                window = [Float](repeating: 0, count: count)
            }
            for idx in 0..<count {
                let x = Double(idx - half)
                window[idx] = Float(0.5 * (1 + cos(Double.pi * x / T)))
            }
            let srcBase = Int(a.rounded()) - half
            let dstBase = Int(ts.rounded()) - half
            let lo = max(0, max(-srcBase, -dstBase))
            let hi = min(count, min(length - srcBase, length - dstBase))
            if lo < hi {
                for idx in lo..<hi {
                    weights[dstBase + idx] += window[idx]
                }
                for ch in 0..<channelCount {
                    channels[ch].withUnsafeBufferPointer { src in
                        output[ch].withUnsafeMutableBufferPointer { dst in
                            for idx in lo..<hi {
                                dst[dstBase + idx] += src[srcBase + idx] * window[idx]
                            }
                        }
                    }
                }
            }
            ts += T / r
        }
        for ch in 0..<channelCount {
            output[ch].withUnsafeMutableBufferPointer { dst in
                for i in 0..<length {
                    let w = weights[i]
                    if w > 1e-3 { dst[i] /= w }
                }
            }
        }
        return output
    }
}
