import Accelerate
import AVFoundation
import CoreML
import Foundation

// MARK: - Contrato do modelo (gerado por scripts/convert_demucs.py)
//
// "afinador-demucs-v1" — o mesmo das conversões públicas schism-audio/htdemucs*-coreml.
//
//   Áudio 44 100 Hz estéreo float32. Segmento de L amostras (htdemucs: 343 980 = 7,8 s).
//   STFT fora do modelo: n_fft 4096, hop 1024, Hann periódica, normalização 1/sqrt(n_fft),
//   T = ceil(L / hop) quadros (336).
//
//   Entradas:  "mag"      (1, 4, 2048, T)    [esq_re, esq_im, dir_re, dir_im] × bins 0…2047 × quadros
//              "mix"      (1, 2, L)          forma de onda do segmento
//   Saídas:    "spec_out" (1, S, 4, 2048, T) espectrograma por fonte (mesmo layout de "mag")
//              "time_out" (1, S, 2, L)       ramo temporal por fonte
//   Fonte s = iSTFT(spec_out[s]) + time_out[s]
//
//   Metadados do modelo: sources = "drums,bass,other,vocals[,guitar,piano]".
//
// A música inteira é processada como em demucs (separate.py + apply_model(split, overlap 0.25,
// shifts 0)): normalização global (média/desvio do mono), segmentos com 25 % de sobreposição,
// janela triangular, padding centrado puxando áudio vizinho. O acumulador é rolante, então a
// memória não cresce com a duração da música; cada stem é gravado aos poucos em .m4a (AAC).
// O espelho em numpy deste código está em scripts/convert_demucs.py (host_stft/host_istft/
// host_separate) e é verificado contra o PyTorch no CI.

enum DemucsContract {
    static let magInput = "mag"
    static let mixInput = "mix"
    static let specOutput = "spec_out"
    static let timeOutput = "time_out"
    static let sourcesMetadataKey = "sources"

    static let sampleRate: Double = 44_100
    static let nfft = 4096
    static let hop = 1024
    static let defaultSegment = 343_980
    static let overlap = 0.25

    /// Nomes procurados no bundle (pasta compilada .mlmodelc).
    static let modelNames = ["HTDemucs", "HTDemucs6s", "htdemucs_6s", "htdemucs"]

    static let sources4 = ["drums", "bass", "other", "vocals"]
    static let sources6 = ["drums", "bass", "other", "vocals", "guitar", "piano"]

    static func stemKind(_ name: String) -> StemKind? {
        switch name.lowercased() {
        case "drums": return .drums
        case "bass": return .bass
        case "other": return .other
        case "vocals": return .vocals
        case "guitar": return .guitar
        case "piano": return .piano
        default: return nil
        }
    }
}

enum DemucsError: LocalizedError {
    case modelMissing
    case badModel(String)
    case decode(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Modelo de IA não incluído nesta versão do app."
        case .badModel(let s): return "Modelo de IA incompatível: \(s)"
        case .decode(let s): return "Não consegui ler o áudio: \(s)"
        case .cancelled: return "Separação cancelada."
        }
    }
}

// MARK: - Separador

struct DemucsSeparator: StemSeparating {

    static func modelURL() -> URL? {
        for name in DemucsContract.modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        }
        let all = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        return all.first { $0.lastPathComponent.lowercased().contains("demucs") }
    }

    var isAvailable: Bool { Self.modelURL() != nil }

    /// Lido do metadata.json do modelo compilado (sem carregar o modelo). Sem isso, supõe 4 stems.
    var supportedStems: [StemKind] {
        guard let url = Self.modelURL() else { return [] }
        let names = Self.sourcesFromCompiledMetadata(url) ?? DemucsContract.sources4
        return names.compactMap { DemucsContract.stemKind($0) }
    }

    func separate(_ songURL: URL, into folder: URL, progress: @escaping (Double) -> Void) async throws -> SeparatedSong {
        guard let modelURL = Self.modelURL() else { throw DemucsError.modelMissing }
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SeparatedSong, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let runner = DemucsRunner(modelURL: modelURL, cancel: flag, progress: progress)
                        let result = try runner.run(song: songURL, folder: folder)
                        cont.resume(returning: result)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// O .mlmodelc traz um metadata.json com userDefinedMetadata; procura "sources" em qualquer nível.
    static func sourcesFromCompiledMetadata(_ modelURL: URL) -> [String]? {
        let url = modelURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findSources(json)
    }

    private static func findSources(_ obj: Any) -> [String]? {
        if let dict = obj as? [String: Any] {
            if let s = dict[DemucsContract.sourcesMetadataKey] as? String { return parseSources(s) }
            for value in dict.values { if let r = findSources(value) { return r } }
        } else if let arr = obj as? [Any] {
            for value in arr { if let r = findSources(value) { return r } }
        }
        return nil
    }

    static func parseSources(_ s: String) -> [String]? {
        let names = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Execução (fora da main thread)

private final class DemucsRunner {
    let modelURL: URL
    let cancel: CancelFlag
    let progress: (Double) -> Void

    init(modelURL: URL, cancel: CancelFlag, progress: @escaping (Double) -> Void) {
        self.modelURL = modelURL
        self.cancel = cancel
        self.progress = progress
    }

    private func checkCancel() throws { if cancel.isCancelled { throw DemucsError.cancelled } }

    func run(song: URL, folder: URL) throws -> SeparatedSong {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        progress(0.01)

        // 1. Modelo
        var model = try loadModel(units: .cpuAndNeuralEngine)
        let desc = model.modelDescription
        guard let mixShape = desc.inputDescriptionsByName[DemucsContract.mixInput]?.multiArrayConstraint?.shape.map({ $0.intValue }),
              let magShape = desc.inputDescriptionsByName[DemucsContract.magInput]?.multiArrayConstraint?.shape.map({ $0.intValue }),
              mixShape.count == 3, magShape.count == 4 else {
            throw DemucsError.badModel("entradas \(DemucsContract.magInput)/\(DemucsContract.mixInput) ausentes")
        }
        let segment = mixShape[2]
        let frames = magShape[3]
        let bins = magShape[2]
        guard mixShape[1] == 2, magShape[1] == 4, bins == DemucsContract.nfft / 2,
              frames == (segment + DemucsContract.hop - 1) / DemucsContract.hop else {
            throw DemucsError.badModel("formas mag=\(magShape) mix=\(mixShape)")
        }
        let metaSources: [String]? = {
            let meta = desc.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
            return meta?[DemucsContract.sourcesMetadataKey].flatMap { DemucsSeparator.parseSources($0) }
        }()
        progress(0.03)

        // 2. Decodifica para 44,1 kHz estéreo float (arquivo temporário) + estatísticas globais
        let tempURL = folder.appendingPathComponent("mix-44k-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: tempURL) }
        let stats = try AudioPrep.decode(song, to: tempURL, cancel: cancel) { p in self.progress(0.03 + 0.04 * p) }
        try checkCancel()
        let total = stats.frames
        guard total > 0 else { throw DemucsError.decode("arquivo vazio") }
        let reader = try AVAudioFile(forReading: tempURL, commonFormat: .pcmFormatFloat32, interleaved: false)

        // 3. Laço de segmentos
        let dsp = DemucsDSP(segment: segment, frames: frames)
        let stride = Int((1 - DemucsContract.overlap) * Double(segment))
        let chunkCount = (total + stride - 1) / stride
        let weight = DemucsDSP.triangleWeight(segment)
        let chunkBuffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(segment))!

        var sources: [String] = []
        var writers: [AVAudioFile] = []
        var stemURLs: [StemKind: URL] = [:]
        var acc: [Float] = []
        var wacc = [Float](repeating: 0, count: segment)
        var written = 0
        var usedFallbackUnits = false

        for k in 0..<chunkCount {
            try checkCancel()
            try autoreleasepool {
                let offset = k * stride
                let chunkLen = min(segment, total - offset)
                let delta = segment - chunkLen
                let start = offset - delta / 2

                // Segmento normalizado, com zeros fora da música
                var left = [Float](repeating: 0, count: segment)
                var right = [Float](repeating: 0, count: segment)
                let a = max(0, start), b = min(total, start + segment)
                if b > a {
                    reader.framePosition = AVAudioFramePosition(a)
                    try reader.read(into: chunkBuffer, frameCount: AVAudioFrameCount(b - a))
                    let n = Int(chunkBuffer.frameLength)
                    if let ch = chunkBuffer.floatChannelData, n > 0 {
                        let dst = a - start
                        var scale = 1 / stats.std
                        var shift = -stats.mean / stats.std
                        left.withUnsafeMutableBufferPointer { p in
                            vDSP_vsmsa(ch[0], 1, &scale, &shift, p.baseAddress! + dst, 1, vDSP_Length(n))
                        }
                        right.withUnsafeMutableBufferPointer { p in
                            vDSP_vsmsa(ch[1], 1, &scale, &shift, p.baseAddress! + dst, 1, vDSP_Length(n))
                        }
                    }
                }

                // Entradas
                let magArr = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
                let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: segment)], dataType: .float32)
                let magPtr = magArr.dataPointer.bindMemory(to: Float.self, capacity: 4 * bins * frames)
                dsp.stft(left, into: magPtr)
                dsp.stft(right, into: magPtr + 2 * bins * frames)
                let mixPtr = mixArr.dataPointer.bindMemory(to: Float.self, capacity: 2 * segment)
                left.withUnsafeBufferPointer { mixPtr.update(from: $0.baseAddress!, count: segment) }
                right.withUnsafeBufferPointer { (mixPtr + segment).update(from: $0.baseAddress!, count: segment) }
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    DemucsContract.magInput: MLFeatureValue(multiArray: magArr),
                    DemucsContract.mixInput: MLFeatureValue(multiArray: mixArr),
                ])

                // Inferência (se o Neural Engine falhar, tenta CPU+GPU uma vez)
                let output: MLFeatureProvider
                do {
                    output = try model.prediction(from: input)
                } catch {
                    if usedFallbackUnits { throw error }
                    usedFallbackUnits = true
                    model = try loadModel(units: .cpuAndGPU)
                    output = try model.prediction(from: input)
                }
                try checkCancel()
                guard let specArr = output.featureValue(for: DemucsContract.specOutput)?.multiArrayValue,
                      let timeArr = output.featureValue(for: DemucsContract.timeOutput)?.multiArrayValue else {
                    throw DemucsError.badModel("saídas \(DemucsContract.specOutput)/\(DemucsContract.timeOutput) ausentes")
                }
                let S = specArr.shape.count == 5 ? specArr.shape[1].intValue : 0
                guard S > 0, specArr.count == S * 4 * bins * frames, timeArr.count == S * 2 * segment else {
                    throw DemucsError.badModel("formas spec_out=\(specArr.shape) time_out=\(timeArr.shape)")
                }

                // Na primeira volta: nomes das fontes, arquivos de saída, acumulador
                if writers.isEmpty {
                    if let m = metaSources, m.count == S { sources = m }
                    else if S == 4 { sources = DemucsContract.sources4 }
                    else if S == 6 { sources = DemucsContract.sources6 }
                    else { throw DemucsError.badModel("\(S) fontes sem nomes nos metadados") }
                    for name in sources {
                        let kind = DemucsContract.stemKind(name) ?? .other
                        let url = folder.appendingPathComponent("\(kind.rawValue).m4a")
                        try? fm.removeItem(at: url)
                        writers.append(try AudioPrep.makeWriter(url))
                        stemURLs[kind] = url
                    }
                    acc = [Float](repeating: 0, count: S * 2 * segment)
                }

                let spec = MultiArrayReader.floats(specArr)
                let time = MultiArrayReader.floats(timeArr)

                // iSTFT + ramo temporal, ponderado e acumulado
                let lo = delta / 2
                var est = [Float](repeating: 0, count: segment)
                for s in 0..<S {
                    for c in 0..<2 {
                        let reBase = ((s * 4) + 2 * c) * bins * frames
                        let imBase = reBase + bins * frames
                        spec.withUnsafeBufferPointer { sp in
                            dsp.istft(re: sp.baseAddress! + reBase, im: sp.baseAddress! + imBase, into: &est)
                        }
                        let row = (s * 2 + c)
                        time.withUnsafeBufferPointer { tp in
                            est.withUnsafeMutableBufferPointer { ep in
                                vDSP_vadd(ep.baseAddress!, 1, tp.baseAddress! + row * segment, 1, ep.baseAddress!, 1, vDSP_Length(segment))
                            }
                        }
                        acc.withUnsafeMutableBufferPointer { ap in
                            est.withUnsafeBufferPointer { ep in
                                weight.withUnsafeBufferPointer { wp in
                                    let dst = ap.baseAddress! + row * segment
                                    vDSP_vma(ep.baseAddress! + lo, 1, wp.baseAddress!, 1, dst, 1, dst, 1, vDSP_Length(chunkLen))
                                }
                            }
                        }
                    }
                }
                wacc.withUnsafeMutableBufferPointer { wa in
                    weight.withUnsafeBufferPointer { wp in
                        vDSP_vadd(wa.baseAddress!, 1, wp.baseAddress!, 1, wa.baseAddress!, 1, vDSP_Length(chunkLen))
                    }
                }

                // Amostras que nenhum segmento futuro alcança: grava
                let isLast = offset + stride >= total
                let ready = isLast ? chunkLen : stride
                try writeFinal(count: ready, sourcesCount: S, segment: segment, acc: acc, wacc: wacc,
                               mean: stats.mean, std: stats.std, writers: writers)
                written += ready

                // Rola o acumulador
                let keep = segment - stride
                acc.withUnsafeMutableBufferPointer { ap in
                    for row in 0..<(S * 2) {
                        let base = ap.baseAddress! + row * segment
                        memmove(base, base + stride, keep * MemoryLayout<Float>.size)
                        vDSP_vclr(base + keep, 1, vDSP_Length(stride))
                    }
                }
                wacc.withUnsafeMutableBufferPointer { wa in
                    let base = wa.baseAddress!
                    memmove(base, base + stride, keep * MemoryLayout<Float>.size)
                    vDSP_vclr(base + keep, 1, vDSP_Length(stride))
                }

                progress(0.07 + 0.92 * Double(k + 1) / Double(chunkCount))
            }
        }
        writers.removeAll() // fecha os arquivos (AVAudioFile finaliza no deinit)
        progress(1)
        return SeparatedSong(sourceName: song.lastPathComponent, stems: stemURLs)
    }

    private func loadModel(units: MLComputeUnits) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: modelURL, configuration: cfg)
    }

    private func writeFinal(count: Int, sourcesCount S: Int, segment: Int, acc: [Float], wacc: [Float],
                            mean: Float, std: Float, writers: [AVAudioFile]) throws {
        guard count > 0 else { return }
        let format = AudioPrep.workFormat
        var inv = [Float](repeating: 0, count: count)
        wacc.withUnsafeBufferPointer { wp in
            inv.withUnsafeMutableBufferPointer { ip in
                var one: Float = 1
                vDSP_svdiv(&one, wp.baseAddress!, 1, ip.baseAddress!, 1, vDSP_Length(count))
            }
        }
        for s in 0..<S {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let ch = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(count)
            for c in 0..<2 {
                let row = s * 2 + c
                acc.withUnsafeBufferPointer { ap in
                    inv.withUnsafeBufferPointer { ip in
                        vDSP_vmul(ap.baseAddress! + row * segment, 1, ip.baseAddress!, 1, ch[c], 1, vDSP_Length(count))
                    }
                }
                var scale = std
                var shift = mean
                vDSP_vsmsa(ch[c], 1, &scale, &shift, ch[c], 1, vDSP_Length(count))
            }
            try writers[s].write(from: buf)
        }
    }
}

// MARK: - STFT / iSTFT (Accelerate), equivalente a HTDemucs._spec / _ispec

final class DemucsDSP {
    let segment: Int
    let frames: Int
    let n = DemucsContract.nfft
    let hop = DemucsContract.hop
    let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    /// 1 / envelope (soma das janelas²) para as posições de saída 0..<segment.
    private let invEnvelope: [Float]

    init(segment: Int, frames: Int) {
        self.segment = segment
        self.frames = frames
        bins = n / 2
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n { w[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        window = w
        // torch.istft: envelope com todos os T+4 quadros (2 de zeros em cada lado)
        let total = frames + 4
        var env = [Float](repeating: 0, count: (total - 1) * hop + n)
        for f in 0..<total {
            for i in 0..<n { env[f * hop + i] += w[i] * w[i] }
        }
        let start = n / 2 + hop / 2 * 3
        var inv = [Float](repeating: 0, count: segment)
        for k in 0..<segment {
            let e = env[start + k]
            inv[k] = e > 1e-11 ? 1 / e : 0
        }
        invEnvelope = inv
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    static func triangleWeight(_ L: Int) -> [Float] {
        let maxW = Float(max(L / 2, L - L / 2))
        return (0..<L).map { i in Float(i < L / 2 ? i + 1 : L - i) / maxW }
    }

    /// x (segment amostras) → re em dst[f*frames + t], im em dst[bins*frames + f*frames + t].
    func stft(_ x: [Float], into dst: UnsafeMutablePointer<Float>) {
        let pad = hop / 2 * 3
        let right = pad + frames * hop - segment
        let padded = Self.reflectPad(x, left: pad, right: right)
        let half = n / 2
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        let scale: Float = 1 / (2 * Float(n).squareRoot()) // zrip = 2·DFT; normalized = 1/sqrt(n)
        let imBase = bins * frames
        padded.withUnsafeBufferPointer { pp in
            for t in 0..<frames {
                frame.withUnsafeMutableBufferPointer { fp in
                    vDSP_vmul(pp.baseAddress! + t * hop, 1, window, 1, fp.baseAddress!, 1, vDSP_Length(n))
                }
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        // Bin 0: DC em realp[0]; imagp[0] é Nyquist (descartado, como no demucs)
                        dst[t] = rp[0] * scale
                        dst[imBase + t] = 0
                        for f in 1..<half {
                            dst[f * frames + t] = rp[f] * scale
                            dst[imBase + f * frames + t] = ip[f] * scale
                        }
                    }
                }
            }
        }
    }

    /// re/im em layout [f*frames + t] → out (segment amostras).
    func istft(re: UnsafePointer<Float>, im: UnsafePointer<Float>, into out: inout [Float]) {
        let half = n / 2
        let total = frames + 4
        var buf = [Float](repeating: 0, count: (total - 1) * hop + n)
        var rbuf = [Float](repeating: 0, count: half)
        var ibuf = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        let scale: Float = 1 / Float(n).squareRoot() // inverso zrip = n·irfft; normalized ×sqrt(n)
        for t in 0..<frames {
            rbuf[0] = re[t]
            ibuf[0] = 0 // Nyquist (zerado no _ispec); parte imaginária do DC é ignorada pelo irfft
            for f in 1..<half {
                rbuf[f] = re[f * frames + t]
                ibuf[f] = im[f * frames + t]
            }
            rbuf.withUnsafeMutableBufferPointer { rp in
                ibuf.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            var s = scale
            frame.withUnsafeMutableBufferPointer { fp in
                vDSP_vsmul(fp.baseAddress!, 1, &s, fp.baseAddress!, 1, vDSP_Length(n))
                vDSP_vmul(fp.baseAddress!, 1, window, 1, fp.baseAddress!, 1, vDSP_Length(n))
                buf.withUnsafeMutableBufferPointer { bp in
                    let dst = bp.baseAddress! + (t + 2) * hop
                    vDSP_vadd(dst, 1, fp.baseAddress!, 1, dst, 1, vDSP_Length(n))
                }
            }
        }
        let start = n / 2 + hop / 2 * 3
        if out.count != segment { out = [Float](repeating: 0, count: segment) }
        buf.withUnsafeBufferPointer { bp in
            out.withUnsafeMutableBufferPointer { op in
                vDSP_vmul(bp.baseAddress! + start, 1, invEnvelope, 1, op.baseAddress!, 1, vDSP_Length(segment))
            }
        }
    }

    /// Igual a numpy/torch "reflect" (sem repetir a borda). Requer left, right < x.count.
    static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        let L = x.count
        var out = [Float](repeating: 0, count: left + L + right)
        for i in 0..<left { out[left - 1 - i] = x[min(L - 1, i + 1)] }
        out.withUnsafeMutableBufferPointer { op in
            x.withUnsafeBufferPointer { xp in
                (op.baseAddress! + left).update(from: xp.baseAddress!, count: L)
            }
        }
        for i in 0..<right { out[left + L + i] = x[max(0, L - 2 - i)] }
        return out
    }
}

// MARK: - Leitura de MLMultiArray (respeita strides e float16/float32/double)

enum MultiArrayReader {
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        guard count > 0, let inner = shape.last, let innerStride = strides.last else { return out }
        let rows = count / inner
        let type = a.dataType
        a.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { op in
                for r in 0..<rows {
                    var rem = r
                    var offset = 0
                    var d = shape.count - 2
                    while d >= 0 {
                        offset += (rem % shape[d]) * strides[d]
                        rem /= shape[d]
                        d -= 1
                    }
                    let dst = op.baseAddress! + r * inner
                    switch type {
                    case .float32:
                        let src = base.assumingMemoryBound(to: Float.self) + offset
                        if innerStride == 1 { dst.update(from: src, count: inner) }
                        else { for i in 0..<inner { dst[i] = src[i * innerStride] } }
                    case .double:
                        let src = base.assumingMemoryBound(to: Double.self) + offset
                        for i in 0..<inner { dst[i] = Float(src[i * innerStride]) }
                    case .float16:
                        let src = base.assumingMemoryBound(to: UInt16.self) + offset
                        Self.halfToFloat(src, stride: innerStride, count: inner, dst: dst)
                    default: // int32
                        let src = base.assumingMemoryBound(to: Int32.self) + offset
                        for i in 0..<inner { dst[i] = Float(src[i * innerStride]) }
                    }
                }
            }
        }
        return out
    }

    private static func halfToFloat(_ src: UnsafePointer<UInt16>, stride: Int, count: Int, dst: UnsafeMutablePointer<Float>) {
        var tmp = [UInt16](repeating: 0, count: count)
        for i in 0..<count { tmp[i] = src[i * stride] }
        tmp.withUnsafeMutableBufferPointer { tp in
            var s = vImage_Buffer(data: tp.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            var d = vImage_Buffer(data: dst, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
        }
    }
}

// MARK: - Decodificação / escrita de áudio

enum AudioPrep {
    static let workFormat = AVAudioFormat(standardFormatWithSampleRate: DemucsContract.sampleRate, channels: 2)!

    struct Stats { var frames: Int; var mean: Float; var std: Float }

    /// Converte qualquer arquivo legível pelo AVAudioFile para CAF float 44,1 kHz estéreo.
    /// Mono é duplicado nos dois canais; mais de 2 canais é mixado para estéreo.
    /// Calcula média e desvio (com correção de Bessel) do mono (E+D)/2, como demucs/separate.py.
    static func decode(_ url: URL, to dest: URL, cancel: CancelFlag, progress: (Double) -> Void) throws -> Stats {
        let src: AVAudioFile
        do { src = try AVAudioFile(forReading: url) } catch { throw DemucsError.decode(error.localizedDescription) }
        let inFormat = src.processingFormat
        let srcChannels = inFormat.channelCount
        guard let mid = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DemucsContract.sampleRate,
                                      channels: srcChannels == 1 ? 1 : 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: mid) else {
            throw DemucsError.decode("formato não suportado")
        }
        if srcChannels > 2 { converter.downmix = true }

        var writer: AVAudioFile? = try AVAudioFile(forWriting: dest, settings: workFormat.settings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let inCap: AVAudioFrameCount = 32_768
        let outCap = AVAudioFrameCount(Double(inCap) * DemucsContract.sampleRate / inFormat.sampleRate) + 1024
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: outCap),
              let stereo = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: outCap) else {
            throw DemucsError.decode("sem memória")
        }
        var sum: Double = 0
        var sumSq: Double = 0
        var count = 0
        var reachedEnd = false
        var readError: Error?
        let totalIn = max(1, src.length)

        while true {
            if cancel.isCancelled { throw DemucsError.cancelled }
            outBuf.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if reachedEnd || src.framePosition >= src.length {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try src.read(into: inBuf, frameCount: inCap)
                } catch {
                    readError = error
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw DemucsError.decode(err?.localizedDescription ?? "conversão") }
            if let e = readError { throw DemucsError.decode(e.localizedDescription) }
            let n = Int(outBuf.frameLength)
            if n > 0, let ch = outBuf.floatChannelData, let st = stereo.floatChannelData {
                stereo.frameLength = AVAudioFrameCount(n)
                let l = ch[0]
                let r = mid.channelCount == 1 ? ch[0] : ch[1]
                st[0].update(from: l, count: n)
                st[1].update(from: r, count: n)
                for i in 0..<n {
                    let m = Double(l[i] + r[i]) * 0.5
                    sum += m
                    sumSq += m * m
                }
                count += n
                try writer?.write(from: stereo)
            }
            progress(min(1, Double(src.framePosition) / Double(totalIn)))
            if status == .endOfStream || (status == .inputRanDry && reachedEnd) { break }
        }
        writer = nil // fecha o arquivo
        let mean = count > 0 ? sum / Double(count) : 0
        var variance = count > 1 ? (sumSq - Double(count) * mean * mean) / Double(count - 1) : 1
        if variance < 1e-16 { variance = 1 }
        return Stats(frames: count, mean: Float(mean), std: Float(variance.squareRoot()))
    }

    /// AAC 192 kb/s em .m4a, recebendo float 44,1 kHz estéreo.
    static func makeWriter(_ url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: DemucsContract.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
