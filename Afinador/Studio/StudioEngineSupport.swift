import Accelerate
import AVFoundation
import Foundation

// MARK: - Erros do Estúdio (mensagens amigáveis em português)

enum StudioEngineError: LocalizedError, Equatable {
    case noProjectOpen
    case microphoneDenied
    case noInput
    case unreadableAudio(String)
    case copyFailed(String)
    case projectChanged
    case nothingToExport
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectOpen:
            return "Abra ou crie um projeto antes de continuar."
        case .microphoneDenied:
            return "O acesso ao microfone está bloqueado. Libere em Ajustes › Privacidade e Segurança › Microfone › Afinador."
        case .noInput:
            return "Nenhuma entrada de áudio disponível. Verifique o microfone ou a interface conectada."
        case .unreadableAudio(let name):
            return "Não foi possível ler o áudio “\(name)”. Use um arquivo de áudio comum (m4a, mp3, wav, aiff ou caf)."
        case .copyFailed(let name):
            return "Não foi possível copiar “\(name)” para o projeto."
        case .projectChanged:
            return "O projeto foi fechado ou trocado durante a importação. Tente de novo."
        case .nothingToExport:
            return "Não há faixas audíveis para exportar (verifique mudo/solo e o volume)."
        case .exportFailed(let detail):
            return "Falha ao exportar a mixagem: \(detail)"
        }
    }
}

// MARK: - Persistência em Documents/Projects/<id>/

enum StudioStorage {
    static var projectsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Projects", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func manifestURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("project.json")
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Lê todos os projetos salvos, mais recente primeiro. Pastas sem project.json válido são ignoradas.
    static func loadAll() -> [StudioProject] {
        let fm = FileManager.default
        let root = projectsRoot
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        let decoder = makeDecoder()
        var result: [StudioProject] = []
        for dir in dirs {
            let manifest = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifest),
                  let project = try? decoder.decode(StudioProject.self, from: data) else { continue }
            result.append(project)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func write(_ project: StudioProject) throws {
        let dir = folder(for: project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try makeEncoder().encode(project)
        try data.write(to: manifestURL(for: project.id), options: .atomic)
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Mixagem" : cleaned
    }
}

// MARK: - Relógio de host (mach_absolute_time) usado para sincronizar players, clique e gravação

enum StudioHostClock {
    static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func ticks(forSeconds seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds / secondsPerTick)
    }

    /// Segundos de `a` até `b` (negativo se b < a).
    static func seconds(from a: UInt64, to b: UInt64) -> Double {
        Double(Int64(bitPattern: b &- a)) * secondsPerTick
    }
}

// MARK: - Regras de mixagem compartilhadas (motor ao vivo e exportação)

enum StudioMix {
    static func isAudible(_ track: StudioTrack, anySolo: Bool) -> Bool {
        !track.isMuted && (!anySolo || track.isSolo)
    }
}

// MARK: - Linha do tempo v2 (operações puras sobre clips; sem áudio, sem MainActor)

extension StudioTrack {
    /// Mantém os campos LEGADO (v1) como espelho dos clips, para código antigo que ainda os lê:
    /// fileName = arquivo do primeiro clip, offset = início do primeiro clip,
    /// duration = end − offset (assim offset + duration == end). Faixa sem clips: "", 0, 0
    /// (importante: senão o decoder recriaria um clip a partir dos campos legados ao reabrir).
    mutating func studioSyncLegacyFields() {
        clips.sort { $0.offset < $1.offset }
        if let first = clips.first {
            fileName = first.fileName
            offset = first.offset
            duration = max(0, end - first.offset)
        } else {
            fileName = ""
            offset = 0
            duration = 0
        }
    }
}

enum StudioTimeline {
    /// Menor pedaço de clip mantido depois de aparar (s).
    static let minClipDuration: TimeInterval = 0.005

    /// Punch-in: o trecho [newClip.offset, newClip.end) substitui o que houver por baixo em `clips`.
    /// Clips sobrepostos são aparados (início/fim) ou divididos em dois; clips totalmente cobertos saem.
    /// Os arquivos nunca são alterados. Devolve `clips` com o novo clip, ordenado por offset.
    static func punchIn(_ newClip: StudioClip, into clips: [StudioClip]) -> [StudioClip] {
        let a = newClip.offset
        let b = newClip.end
        var result: [StudioClip] = []
        for clip in clips {
            if clip.end <= a || clip.offset >= b {
                result.append(clip)                     // fora do trecho
                continue
            }
            // Pedaço antes do trecho.
            if clip.offset < a {
                var left = clip
                left.duration = a - clip.offset
                if left.duration >= minClipDuration { result.append(left) }
            }
            // Pedaço depois do trecho.
            if clip.end > b {
                let cut = b - clip.offset
                var right = clip
                if clip.offset < a { right.id = UUID() }     // dividido: o lado direito é um clip novo
                right.offset = b
                right.fileStart = clip.fileStart + cut
                right.duration = clip.end - b
                if right.duration >= minClipDuration { result.append(right) }
            }
        }
        result.append(newClip)
        result.sort { $0.offset < $1.offset }
        return result
    }

    /// Todos os arquivos usados por clips do projeto (inclui o legado fileName por segurança).
    static func referencedFiles(in project: StudioProject) -> Set<String> {
        var names = Set<String>()
        for track in project.tracks {
            for clip in track.clips { names.insert(clip.fileName) }
            if !track.fileName.isEmpty { names.insert(track.fileName) }
        }
        return names
    }

    /// Apaga de `folder` os arquivos de `candidates` que o projeto não usa mais (e seus caches de forma de onda).
    static func deleteUnreferenced(_ candidates: Set<String>, project: StudioProject, folder: URL) {
        let used = referencedFiles(in: project)
        let fm = FileManager.default
        for name in candidates where !name.isEmpty && !used.contains(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
            try? fm.removeItem(at: folder.appendingPathComponent(StudioWaveforms.cacheFileName(for: name)))
            StudioWaveforms.forget(folder.appendingPathComponent(name))
        }
    }
}

// MARK: - Forma de onda (picos por arquivo, cache em disco "<arquivo>.peaks" na pasta do projeto)
//
// Formato do cache (little-endian): "PKS1" | UInt32 framesPorPico | Float64 sampleRate |
// Int64 comprimento do arquivo em frames | UInt32 nº de picos | nº × UInt16 (pico linear 0…1 × 65535).
// ~200 picos/s → 5 min ≈ 60 000 picos ≈ 120 KB. Todo o trabalho roda numa fila serial própria.

final class StudioPeaks: @unchecked Sendable {
    let framesPerPeak: Int
    let sampleRate: Double
    let fileLength: Int64
    let values: [UInt16]

    init(framesPerPeak: Int, sampleRate: Double, fileLength: Int64, values: [UInt16]) {
        self.framesPerPeak = framesPerPeak
        self.sampleRate = sampleRate
        self.fileLength = fileLength
        self.values = values
    }

    var peaksPerSecond: Double { sampleRate / Double(max(1, framesPerPeak)) }
}

/// Cache LRU simples de picos em memória.
final class StudioPeaksMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var items: [String: StudioPeaks] = [:]
    private var order: [String] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func get(_ key: String) -> StudioPeaks? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func put(_ key: String, _ value: StudioPeaks) {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let old = order.removeFirst()
            items[old] = nil
        }
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
        order.removeAll { $0 == key }
    }
}

enum StudioWaveforms {
    static let peaksPerSecond: Double = 200
    static let chunkFrames: Int = 65_536

    private static let queue = DispatchQueue(label: "studio.waveforms", qos: .userInitiated)
    /// Cache em memória (acessado só dentro de `queue`; o lock é só uma garantia extra).
    private static let memory = StudioPeaksMemoryCache(limit: 32)

    static func cacheFileName(for fileName: String) -> String { fileName + ".peaks" }

    /// Esquece o cache em memória de um arquivo (ex.: arquivo apagado).
    static func forget(_ url: URL) {
        let key = url.standardizedFileURL.path
        StudioWaveforms.queue.async { StudioWaveforms.memory.remove(key) }
    }

    /// Picos 0…1 (pico linear absoluto, máximo entre canais) do trecho [fileStart, fileStart+duration)
    /// do arquivo, em `buckets` colunas. [] em caso de erro.
    static func waveform(fileURL: URL, fileStart: TimeInterval, duration: TimeInterval,
                         buckets: Int) async -> [Float] {
        guard buckets > 0, duration > 0 else { return [] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            StudioWaveforms.queue.async {
                let result: [Float]
                if let peaks = StudioWaveforms.loadPeaks(fileURL) {
                    result = StudioWaveforms.slice(peaks, fileStart: fileStart, duration: duration,
                                                   buckets: buckets)
                } else {
                    result = []
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: Internos (rodam dentro de `queue`)

    private static func loadPeaks(_ url: URL) -> StudioPeaks? {
        let key = url.standardizedFileURL.path
        if let cached = memory.get(key) { return cached }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        let cacheURL = url.deletingLastPathComponent()
            .appendingPathComponent(cacheFileName(for: url.lastPathComponent))

        var peaks = readCache(cacheURL)
        if let p = peaks, p.fileLength != file.length || p.sampleRate != sr {
            peaks = nil                                  // arquivo mudou: recalcula
        }
        if peaks == nil {
            guard let computed = compute(file) else { return nil }
            writeCache(computed, to: cacheURL)
            peaks = computed
        }
        guard let result = peaks else { return nil }
        memory.put(key, result)
        return result
    }

    private static func compute(_ file: AVAudioFile) -> StudioPeaks? {
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        guard channels > 0, format.commonFormat == .pcmFormatFloat32 else { return nil }
        let window = max(1, Int((sr / peaksPerSecond).rounded()))
        let chunk = max(window, (chunkFrames / window) * window)    // múltiplo da janela
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            return nil
        }
        let total = file.length
        var values: [UInt16] = []
        values.reserveCapacity(Int(total / Int64(window)) + 1)
        file.framePosition = 0
        var readSoFar: Int64 = 0
        while readSoFar < total {
            let want = AVAudioFrameCount(min(Int64(chunk), total - readSoFar))
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                return nil
            }
            let got = Int(buffer.frameLength)
            if got <= 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            let interleaved = format.isInterleaved
            var start = 0
            while start < got {
                let n = min(window, got - start)
                var peak: Float = 0
                if interleaved {
                    var m: Float = 0
                    vDSP_maxmgv(data[0].advanced(by: start * channels), 1, &m, vDSP_Length(n * channels))
                    peak = m
                } else {
                    for c in 0..<channels {
                        var m: Float = 0
                        vDSP_maxmgv(data[c].advanced(by: start), 1, &m, vDSP_Length(n))
                        peak = max(peak, m)
                    }
                }
                let clamped = min(1, max(0, peak.isFinite ? peak : 0))
                values.append(UInt16((clamped * 65_535).rounded()))
                start += n
            }
            readSoFar += Int64(got)
        }
        return StudioPeaks(framesPerPeak: window, sampleRate: sr, fileLength: total, values: values)
    }

    private static func slice(_ peaks: StudioPeaks, fileStart: TimeInterval, duration: TimeInterval,
                              buckets: Int) -> [Float] {
        let values = peaks.values
        guard !values.isEmpty else { return [Float](repeating: 0, count: buckets) }
        let rate = peaks.peaksPerSecond
        let p0 = max(0, fileStart) * rate
        let span = duration * rate
        let step = span / Double(buckets)
        var out = [Float](repeating: 0, count: buckets)
        for i in 0..<buckets {
            let lo = Int((p0 + Double(i) * step).rounded(.down))
            var hi = Int((p0 + Double(i + 1) * step).rounded(.up))
            if hi <= lo { hi = lo + 1 }
            let a = max(0, lo)
            let b = min(values.count, hi)
            guard a < b else { continue }
            var m: UInt16 = 0
            for j in a..<b where values[j] > m { m = values[j] }
            out[i] = Float(m) / 65_535
        }
        return out
    }

    private static func readCache(_ url: URL) -> StudioPeaks? {
        guard let data = try? Data(contentsOf: url), data.count >= 28 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x53, bytes[3] == 0x31 else { return nil }
        func u64(_ at: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(bytes[at + k]) << (8 * UInt64(k)) }
            return v
        }
        func u32(_ at: Int) -> UInt32 {
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(bytes[at + k]) << (8 * UInt32(k)) }
            return v
        }
        let window = Int(u32(4))
        let sr = Double(bitPattern: u64(8))
        let length = Int64(bitPattern: u64(16))
        let count = Int(u32(24))
        guard window > 0, sr > 0, bytes.count == 28 + count * 2 else { return nil }
        var values = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            let at = 28 + i * 2
            values[i] = UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
        }
        return StudioPeaks(framesPerPeak: window, sampleRate: sr, fileLength: length, values: values)
    }

    private static func writeCache(_ peaks: StudioPeaks, to url: URL) {
        var bytes: [UInt8] = [0x50, 0x4B, 0x53, 0x31]      // "PKS1"
        bytes.reserveCapacity(28 + peaks.values.count * 2)
        func put64(_ v: UInt64) { for k in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) } }
        func put32(_ v: UInt32) { for k in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(k)))) } }
        put32(UInt32(clamping: peaks.framesPerPeak))
        put64(peaks.sampleRate.bitPattern)
        put64(UInt64(bitPattern: peaks.fileLength))
        put32(UInt32(clamping: peaks.values.count))
        for v in peaks.values {
            bytes.append(UInt8(truncatingIfNeeded: v))
            bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        try? Data(bytes).write(to: url, options: .atomic)
    }
}
