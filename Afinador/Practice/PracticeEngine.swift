import AVFoundation
import Foundation

// MARK: - Biblioteca

/// Uma música importada para treinar. Persistida em Documents/Practice/library.json;
/// arquivos em Documents/Practice/<id>/ (song.<ext> e stems/<stem>.m4a).
/// Caminhos são guardados relativos à pasta da música (o caminho absoluto do container muda
/// entre instalações).
struct PracticeSong: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var duration: TimeInterval
    var addedAt: Date = Date()
    /// StemKind.rawValue → nome do arquivo em stems/.
    var stemFiles: [String: String] = [:]
    var semitones: Int = 0
    var speed: Double = 1
    /// Tom original informado pelo usuário (0 = C … 11 = B), para mostrar a troca de tom.
    var originalKey: Int?

    var hasStems: Bool { !stemFiles.isEmpty }
}

struct StemMixState: Equatable {
    var volume: Float = 1
    var isMuted = false
    var isSolo = false
}

// MARK: - Motor

@MainActor
final class PracticeEngine: ObservableObject {

    // Biblioteca
    @Published private(set) var library: [PracticeSong] = []
    @Published private(set) var current: PracticeSong?

    // Transporte
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    // Tom e velocidade
    @Published private(set) var semitones: Int = 0
    @Published private(set) var speed: Double = 1

    // Loop A-B
    @Published private(set) var loopA: TimeInterval?
    @Published private(set) var loopB: TimeInterval?
    var loopActive: Bool { loopA != nil && loopB != nil }

    // Stems
    @Published private(set) var useStems = false
    @Published private(set) var stemMix: [StemKind: StemMixState] = [:]
    var availableStems: [StemKind] {
        guard let song = current else { return [] }
        return StemKind.allCases.filter { song.stemFiles[$0.rawValue] != nil }
    }

    // Separação (IA)
    let separator: StemSeparating
    /// Calculados uma vez (o modelo está ou não no bundle).
    let separatorAvailable: Bool
    let separatorStems: [StemKind]
    @Published private(set) var isSeparating = false
    @Published private(set) var separationProgress: Double = 0
    @Published private(set) var isImporting = false

    @Published var lastError: String?

    static let semitoneRange = -6...6
    static let speedRange = 0.5...1.25
    static let minLoopLength: TimeInterval = 0.5

    // Áudio
    private let engine = AVAudioEngine()
    private let submix = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var players: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []
    private var playerKinds: [StemKind?] = []      // nil = música completa

    /// Trechos agendados desde o último play (em segundos do arquivo), na ordem de reprodução.
    private var scheduled: [(start: TimeInterval, length: TimeInterval)] = []
    private var generation = 0
    private var ticker: Timer?
    private var separationTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isActive = false

    init() {
        let sep = DemucsSeparator()
        separator = sep
        separatorAvailable = sep.isAvailable
        separatorStems = sep.supportedStems
        engine.attach(submix)
        engine.attach(timePitch)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        engine.connect(submix, to: timePitch, format: fmt)
        engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
        loadLibrary()
        observeSession()
    }

    // MARK: Ciclo de vida (aba)

    func activate() {
        isActive = true
        let s = AVAudioSession.sharedInstance()
        do {
            if s.category != .playAndRecord || !s.categoryOptions.contains(.defaultToSpeaker) {
                try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try s.setActive(true)
        } catch {
            lastError = "Não consegui abrir o áudio: \(error.localizedDescription)"
        }
        startEngineIfNeeded()
    }

    /// Para tudo e desliga o motor. A sessão de áudio fica ativa (outras abas usam a mesma).
    func deactivate() {
        isActive = false
        pause()
        engine.stop()
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { lastError = "Não consegui iniciar o áudio: \(error.localizedDescription)" }
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            Task { @MainActor in
                guard let self else { return }
                if type == .began { self.pause() } else if self.isActive { self.startEngineIfNeeded() }
            }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // O motor parou sozinho (troca de fone/saída). Guarda a posição e religa.
                let wasPlaying = self.isPlaying
                self.pause()
                if self.isActive { self.startEngineIfNeeded() }
                if wasPlaying { self.play() }
            }
        })
    }

    // MARK: Biblioteca

    nonisolated static var rootFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Practice", isDirectory: true)
    }
    nonisolated private static var libraryURL: URL { rootFolder.appendingPathComponent("library.json") }

    func folder(for song: PracticeSong) -> URL {
        Self.rootFolder.appendingPathComponent(song.id.uuidString, isDirectory: true)
    }
    func songURL(_ song: PracticeSong) -> URL { folder(for: song).appendingPathComponent(song.fileName) }
    func stemsFolder(_ song: PracticeSong) -> URL { folder(for: song).appendingPathComponent("stems", isDirectory: true) }

    func separatedSong(_ song: PracticeSong) -> SeparatedSong? {
        guard song.hasStems else { return nil }
        var stems: [StemKind: URL] = [:]
        for (key, file) in song.stemFiles {
            if let kind = StemKind(rawValue: key) { stems[kind] = stemsFolder(song).appendingPathComponent(file) }
        }
        return SeparatedSong(sourceName: song.title, stems: stems)
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: Self.libraryURL),
              let list = try? JSONDecoder().decode([PracticeSong].self, from: data) else { return }
        let fm = FileManager.default
        library = list.filter { fm.fileExists(atPath: songURL($0).path) }
    }

    private func saveLibrary() {
        do {
            try FileManager.default.createDirectory(at: Self.rootFolder, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(library).write(to: Self.libraryURL, options: .atomic)
        } catch {
            lastError = "Não consegui salvar a biblioteca: \(error.localizedDescription)"
        }
    }

    private func update(_ song: PracticeSong) {
        if let i = library.firstIndex(where: { $0.id == song.id }) { library[i] = song }
        if current?.id == song.id { current = song }
        saveLibrary()
    }

    /// Copia o arquivo escolhido no app Arquivos (URL com escopo de segurança) para a biblioteca.
    func importSong(from url: URL) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let song = try await Task.detached(priority: .userInitiated) {
                    try PracticeEngine.copyIntoLibrary(url)
                }.value
                library.insert(song, at: 0)
                saveLibrary()
                open(song)
            } catch {
                lastError = "Não consegui importar: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func copyIntoLibrary(_ url: URL) throws -> PracticeSong {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let folder = rootFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let dest = folder.appendingPathComponent("song.\(ext)")
        do {
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { src in
                do { try fm.copyItem(at: src, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
            let file = try AVAudioFile(forReading: dest)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > 0.5 else { throw PracticeError.tooShort }
            let title = url.deletingPathExtension().lastPathComponent
            return PracticeSong(id: id, title: title, fileName: dest.lastPathComponent, duration: duration)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    func delete(_ song: PracticeSong) {
        if current?.id == song.id { close() }
        try? FileManager.default.removeItem(at: folder(for: song))
        library.removeAll { $0.id == song.id }
        saveLibrary()
    }

    func rename(_ song: PracticeSong, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var s = song
        s.title = t
        update(s)
    }

    func setOriginalKey(_ key: Int?) {
        guard var s = current else { return }
        s.originalKey = key
        update(s)
    }

    // MARK: Abrir / fechar

    func open(_ song: PracticeSong) {
        pause()
        current = song
        position = 0
        duration = song.duration
        loopA = nil
        loopB = nil
        semitones = song.semitones
        speed = song.speed
        applyPitchAndSpeed()
        stemMix = [:]
        for kind in StemKind.allCases where song.stemFiles[kind.rawValue] != nil { stemMix[kind] = StemMixState() }
        useStems = song.hasStems
        rebuildGraph()
    }

    func close() {
        pause()
        detachPlayers()
        current = nil
        position = 0
        duration = 0
        loopA = nil
        loopB = nil
    }

    private func detachPlayers() {
        for p in players {
            p.stop()
            engine.detach(p)
        }
        players = []
        files = []
        playerKinds = []
    }

    /// Recria os players (música completa ou um por stem) ligados ao submix.
    private func rebuildGraph() {
        detachPlayers()
        guard let song = current else { return }
        var entries: [(StemKind?, URL)] = []
        if useStems, let sep = separatedSong(song) {
            for kind in StemKind.allCases { if let url = sep.stems[kind] { entries.append((kind, url)) } }
        }
        if entries.isEmpty {
            useStems = false
            entries = [(nil, songURL(song))]
        }
        for (kind, url) in entries {
            do {
                let file = try AVAudioFile(forReading: url)
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: submix, format: file.processingFormat)
                players.append(player)
                files.append(file)
                playerKinds.append(kind)
            } catch {
                lastError = "Não consegui abrir \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let f = files.first {
            let d = Double(f.length) / f.processingFormat.sampleRate
            if d > 0 { duration = d }
        }
        applyMix()
    }

    // MARK: Transporte

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard current != nil, !players.isEmpty else { return }
        if !isActive { activate() }
        startEngineIfNeeded()
        guard engine.isRunning else { return }
        stopPlayers()
        generation += 1
        scheduled = []

        var start = position
        if start >= duration - 0.05 { start = 0 }
        if let a = loopA, let b = loopB {
            if start < a || start >= b - 0.05 { start = a }
            schedule(start: start, length: b - start, loop: true)
            schedule(start: a, length: b - a, loop: true)
            schedule(start: a, length: b - a, loop: true)
        } else {
            schedule(start: start, length: duration - start, loop: false)
        }
        position = start

        // Todos os players começam na mesma hora do relógio de áudio (stems em sincronia).
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.06))
        for p in players { p.play(at: when) }
        isPlaying = true
        startTicker()
    }

    func pause() {
        if isPlaying { position = currentPosition() }
        generation += 1
        stopPlayers()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        let t = min(max(0, time), max(0, duration - 0.01))
        if isPlaying {
            pause()
            position = t
            play()
        } else {
            position = t
        }
    }

    func skip(_ delta: TimeInterval) { seek(to: (isPlaying ? currentPosition() : position) + delta) }

    private func stopPlayers() {
        for p in players { p.stop() }
    }

    private func schedule(start: TimeInterval, length: TimeInterval, loop: Bool) {
        guard length > 0.01, let first = files.first else { return }
        let sr0 = first.processingFormat.sampleRate
        let frames0 = AVAudioFrameCount(max(1, (length * sr0).rounded()))
        scheduled.append((start, Double(frames0) / sr0))
        let gen = generation
        for (i, (p, f)) in zip(players, files).enumerated() {
            let sr = f.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition((start * sr).rounded())
            guard startFrame < f.length else { continue }
            let frames = AVAudioFrameCount(min(Double(f.length - startFrame), (length * sr).rounded()))
            guard frames > 0 else { continue }
            if i == 0 {
                p.scheduleSegment(f, startingFrame: startFrame, frameCount: frames, at: nil,
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.segmentFinished(generation: gen, loop: loop) }
                }
            } else {
                p.scheduleSegment(f, startingFrame: startFrame, frameCount: frames, at: nil, completionHandler: nil)
            }
        }
    }

    private func segmentFinished(generation gen: Int, loop: Bool) {
        guard gen == generation, isPlaying else { return }
        if loop, let a = loopA, let b = loopB {
            schedule(start: a, length: b - a, loop: true)
        } else if !loop {
            // Fim da música
            generation += 1
            stopPlayers()
            isPlaying = false
            stopTicker()
            position = 0
        }
    }

    /// Posição atual no arquivo, a partir do relógio do primeiro player e da fila de trechos.
    func currentPosition() -> TimeInterval {
        guard isPlaying, let p = players.first,
              let nodeTime = p.lastRenderTime, nodeTime.isSampleTimeValid,
              let pt = p.playerTime(forNodeTime: nodeTime), pt.sampleRate > 0 else { return position }
        var elapsed = max(0, Double(pt.sampleTime) / pt.sampleRate)
        for seg in scheduled {
            if elapsed < seg.length { return seg.start + elapsed }
            elapsed -= seg.length
        }
        if let last = scheduled.last { return min(duration, last.start + last.length) }
        return position
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying else { return }
        position = currentPosition()
    }

    // MARK: Tom e velocidade

    func setSemitones(_ value: Int) {
        semitones = min(max(value, Self.semitoneRange.lowerBound), Self.semitoneRange.upperBound)
        applyPitchAndSpeed()
        persistSettings()
    }

    func setSpeed(_ value: Double) {
        let v = (min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound) * 100).rounded() / 100
        speed = v
        applyPitchAndSpeed()
        persistSettings()
    }

    private func applyPitchAndSpeed() {
        timePitch.pitch = Float(semitones * 100)
        timePitch.rate = Float(speed)
    }

    private var persistWork: DispatchWorkItem?
    private func persistSettings() {
        guard var s = current else { return }
        s.semitones = semitones
        s.speed = speed
        current = s
        if let i = library.firstIndex(where: { $0.id == s.id }) { library[i] = s }
        // Evita gravar o JSON a cada passo do slider.
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveLibrary() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: Loop A-B

    func setLoopA() {
        let t = isPlaying ? currentPosition() : position
        loopA = t
        if let b = loopB, b - t < Self.minLoopLength { loopB = nil }
        restartIfPlaying()
    }

    func setLoopB() {
        let t = isPlaying ? currentPosition() : position
        guard let a = loopA else {
            lastError = "Marque o ponto A primeiro."
            return
        }
        guard t - a >= Self.minLoopLength else {
            lastError = "O ponto B precisa estar pelo menos meio segundo depois do A."
            return
        }
        loopB = t
        restartIfPlaying()
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
        restartIfPlaying()
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        let t = currentPosition()
        pause()
        position = t
        play()
    }

    // MARK: Stems

    func setUseStems(_ on: Bool) {
        guard current?.hasStems == true, on != useStems else { return }
        let wasPlaying = isPlaying
        pause()
        useStems = on
        rebuildGraph()
        if wasPlaying { play() }
    }

    func setStemVolume(_ kind: StemKind, _ v: Float) {
        stemMix[kind, default: StemMixState()].volume = min(max(v, 0), 1.5)
        applyMix()
    }

    func toggleMute(_ kind: StemKind) {
        stemMix[kind, default: StemMixState()].isMuted.toggle()
        applyMix()
    }

    func toggleSolo(_ kind: StemKind) {
        stemMix[kind, default: StemMixState()].isSolo.toggle()
        applyMix()
    }

    /// Atalho: tira um instrumento (ex.: violão para tocar junto, voz para karaokê).
    func removeOnly(_ kind: StemKind) {
        for k in stemMix.keys {
            stemMix[k]?.isSolo = false
            stemMix[k]?.isMuted = (k == kind)
        }
        applyMix()
    }

    func resetMix() {
        for k in stemMix.keys { stemMix[k] = StemMixState() }
        applyMix()
    }

    func isAudible(_ kind: StemKind) -> Bool {
        guard let st = stemMix[kind] else { return false }
        let anySolo = stemMix.values.contains { $0.isSolo }
        if st.isMuted { return false }
        if anySolo && !st.isSolo { return false }
        return st.volume > 0
    }

    private func applyMix() {
        for (p, kind) in zip(players, playerKinds) {
            if let kind {
                p.volume = isAudible(kind) ? (stemMix[kind]?.volume ?? 1) : 0
            } else {
                p.volume = 1
            }
        }
    }

    // MARK: Separação (IA)

    func separateCurrent() {
        guard let song = current, !isSeparating else { return }
        guard separatorAvailable else {
            lastError = "Modelo de IA não incluído nesta versão do app."
            return
        }
        pause()
        isSeparating = true
        separationProgress = 0
        let sep = separator
        let src = songURL(song)
        let dest = stemsFolder(song)
        separationTask = Task {
            do {
                let result = try await sep.separate(src, into: dest) { [weak self] p in
                    Task { @MainActor in self?.separationProgress = p }
                }
                finishSeparation(songID: song.id, result: result)
            } catch is CancellationError {
                isSeparating = false
            } catch DemucsError.cancelled {
                isSeparating = false
            } catch {
                isSeparating = false
                lastError = "A separação falhou: \(error.localizedDescription)"
            }
        }
    }

    func cancelSeparation() {
        separationTask?.cancel()
        separationTask = nil
        isSeparating = false
    }

    private func finishSeparation(songID: UUID, result: SeparatedSong) {
        isSeparating = false
        separationProgress = 1
        guard var song = library.first(where: { $0.id == songID }) else { return }
        var map: [String: String] = [:]
        for (kind, url) in result.stems { map[kind.rawValue] = url.lastPathComponent }
        song.stemFiles = map
        update(song)
        if current?.id == songID {
            let wasPlaying = isPlaying
            pause()
            stemMix = [:]
            for kind in StemKind.allCases where map[kind.rawValue] != nil { stemMix[kind] = StemMixState() }
            useStems = true
            rebuildGraph()
            if wasPlaying { play() }
        }
    }

    func deleteStems() {
        guard var song = current else { return }
        pause()
        try? FileManager.default.removeItem(at: stemsFolder(song))
        song.stemFiles = [:]
        update(song)
        stemMix = [:]
        useStems = false
        rebuildGraph()
    }

    // MARK: Estúdio

    /// Arquivos para levar ao Estúdio: stems audíveis (modo stems) ou a música completa.
    func filesForStudio() -> [(name: String, url: URL)] {
        guard let song = current else { return [] }
        if useStems, let sep = separatedSong(song) {
            let list = StemKind.allCases.compactMap { kind -> (name: String, url: URL)? in
                guard let url = sep.stems[kind], isAudible(kind) else { return nil }
                return (kind.title, url)
            }
            if !list.isEmpty { return list }
        }
        return [(song.title, songURL(song))]
    }
}

enum PracticeError: LocalizedError {
    case tooShort
    var errorDescription: String? {
        switch self {
        case .tooShort: return "O arquivo é curto demais ou não tem áudio."
        }
    }
}

// MARK: - Notas (troca de tom)

enum PracticeNotes {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func name(_ pc: Int) -> String { names[((pc % 12) + 12) % 12] }

    static func transposed(_ key: Int, by semitones: Int) -> String { name(key + semitones) }

    static func intervalText(_ semitones: Int) -> String {
        switch semitones {
        case 0: return "Tom original"
        case 1, -1: return semitones > 0 ? "+1 semitom" : "−1 semitom"
        default: return semitones > 0 ? "+\(semitones) semitons" : "−\(-semitones) semitons"
        }
    }
}
