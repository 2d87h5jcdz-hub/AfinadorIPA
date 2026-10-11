import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - StudioEngine
//
// Motor do Estúdio (gravação em camadas). API pública conforme o contrato em StudioModels.swift.
//
// Grafo ao vivo (um AVAudioEngine recriado sempre que o conjunto de faixas ou a rota muda):
//
//   por faixa:  player → conversor(mixer) → gate → EQ → compressor → drive → delay → reverb → mixer da faixa ─┐
//                                                                                     (volume/pan, tap de nível)│
//   master:     ┌──────────────────────────────────────────────────────────────────────────────────────────────┘
//               └→ masterMixer → limitador → mainMixer → saída
//   clique:     AVAudioSourceNode (mono) → mainMixer
//   monitor:    inputNode → mixer → [cadeia de efeitos com monitorEffects] → mixer (0 ou 1) → mainMixer
//   entrada:    tap no inputNode → medidor + gravação (áudio SECO em .caf PCM float32)
//
// Sessão de áudio: .playAndRecord, modo .default, [.defaultToSpeaker, .allowBluetoothA2DP], buffer ~5 ms.
// Escolhemos .default (e não .measurement) porque é o mesmo modo que AudioSession.activate() usa nas
// outras abas — trocar de modo ao gravar reconfigura a rota (corte/estalo) e muda o ganho do microfone
// entre o monitoramento e a tomada. Em .playAndRecord/.default não há processamento de voz (só no .voiceChat).
//
// Sincronia: players, clique e gravação usam o mesmo instante de host (mach_absolute_time) como origem.
// Compensação de latência: o gravador descarta as amostras capturadas antes do instante em que a
// música chega à posição inicial (pelo hostTime do tap, o que já cobre o atraso do buffer de I/O);
// o atraso restante — ida até o alto-falante/fone (outputLatency) e volta pelo conversor de entrada
// (inputLatency) — vira offset negativo da faixa nova: offset = posiçãoInicial − (inputLatency + outputLatency).

@MainActor
final class StudioEngine: ObservableObject {

    // MARK: Estado publicado (contrato)

    @Published private(set) var projects: [StudioProject] = []
    @Published var project: StudioProject? = nil {
        didSet { projectDidChange(from: oldValue) }
    }
    @Published private(set) var transport: TransportState = .stopped
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var trackLevels: [UUID: Float] = [:]
    @Published var clickEnabled: Bool = true {
        didSet {
            click?.setClickOn(clickEnabled)
            UserDefaults.standard.set(clickEnabled, forKey: Keys.click)
        }
    }
    @Published var countInBars: Int = 1 {
        didSet {
            let clamped = min(2, max(0, countInBars))
            if clamped != countInBars { countInBars = clamped }
            UserDefaults.standard.set(clamped, forKey: Keys.countIn)
        }
    }
    @Published var monitorEnabled: Bool = false {
        didSet { monitorDidChange() }
    }
    @Published var monitorEffects: EffectSettings = .preset(.none) {
        didSet { monitorChain?.apply(monitorEffects) }
    }
    @Published private(set) var inputName: String = "Microfone do iPhone"
    @Published private(set) var isHeadphoneConnected: Bool = false
    @Published private(set) var lastError: String?

    /// Maior faixa do projeto (fim da faixa = offset + duração).
    var duration: TimeInterval {
        guard let project else { return 0 }
        var longest: TimeInterval = 0
        for track in project.tracks {
            longest = max(longest, track.offset + track.duration)
        }
        return max(0, longest)
    }

    // MARK: Extras (além do contrato)

    /// true enquanto exportMix está renderizando.
    @Published private(set) var isExporting = false

    /// Latência que será compensada na próxima gravação (s).
    var latencyCompensation: TimeInterval {
        let s = AVAudioSession.sharedInstance()
        return s.inputLatency + s.outputLatency
    }

    /// URL do arquivo de áudio de uma faixa do projeto aberto (útil para forma de onda).
    func fileURL(for track: StudioTrack) -> URL? {
        guard let project else { return nil }
        return StudioStorage.folder(for: project.id).appendingPathComponent(track.fileName)
    }

    func clearError() { lastError = nil }

    // MARK: Estado interno

    private enum Keys {
        static let click = "studio.clickEnabled"
        static let countIn = "studio.countInBars"
    }

    private static let feedbackWarning =
        "Sem fone de ouvido: ouvir a entrada pelo alto-falante pode causar microfonia. Use fone para monitorar."

    private struct PendingTake {
        let id: UUID
        let fileName: String
        let url: URL
        let startPosition: TimeInterval
        let latency: TimeInterval
        let sampleRate: Double
    }

    private var engine: AVAudioEngine?
    private var chains: [UUID: StudioTrackChain] = [:]
    private var masterMixer: AVAudioMixerNode?
    private var monitorChain: StudioEffectChain?
    private var monitorOut: AVAudioMixerNode?
    private var click: StudioClickGenerator?
    private var inputTapInstalled = false

    private let meters = StudioLevelMeters()
    private let recorder = StudioTakeRecorder()

    private var isActive = false
    private var micGranted = false
    private var recordAfterPermission = false
    private var previousIOBuffer: TimeInterval?

    private var playStartHost: UInt64 = 0
    private var playStartPosition: TimeInterval = 0
    private var leadIn: TimeInterval = 0
    private var take: PendingTake?
    private var needsRebuild = false

    private var suppressObservation = false
    private var saveTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var timerCancellable: AnyCancellable?
    private var engineConfigCancellable: AnyCancellable?
    private var sessionCancellables = Set<AnyCancellable>()

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.click) != nil {
            clickEnabled = defaults.bool(forKey: Keys.click)
        }
        if defaults.object(forKey: Keys.countIn) != nil {
            countInBars = min(2, max(0, defaults.integer(forKey: Keys.countIn)))
        }
        projects = StudioStorage.loadAll()
        observeSession()
        updateRouteInfo()
    }

    // MARK: - Projetos

    func newProject(name: String) -> StudioProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = StudioProject(name: trimmed.isEmpty ? "Música \(projects.count + 1)" : trimmed)
        stopForProjectSwitch()
        writeProject(project)
        self.project = project      // didSet: troca de projeto → reconstrói o grafo
        return project
    }

    func open(_ id: UUID) {
        guard project?.id != id else { return }
        guard let target = projects.first(where: { $0.id == id }) else {
            lastError = "Projeto não encontrado."
            return
        }
        stopForProjectSwitch()
        project = target
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if project?.id == id {
            project?.name = trimmed     // didSet salva
            return
        }
        guard var target = projects.first(where: { $0.id == id }) else { return }
        target.name = trimmed
        target.updatedAt = Date()
        writeProject(target)
    }

    func deleteProject(_ id: UUID) {
        if project?.id == id {
            if transport != .stopped { stop() }
            saveTask?.cancel()
            saveTask = nil
            project = nil
        }
        let folder = StudioStorage.folder(for: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            do { try fm.removeItem(at: folder) } catch {
                lastError = "Não foi possível apagar os arquivos do projeto."
            }
        }
        projects.removeAll { $0.id == id }
    }

    func closeProject() {
        guard project != nil else { return }
        stopForProjectSwitch()
        project = nil
    }

    // MARK: - Transporte

    func play(from start: TimeInterval? = nil) {
        switch transport {
        case .countIn, .recording: return
        default: break
        }
        guard project != nil else { fail(.noProjectOpen); return }
        if !isActive { activate() }
        guard ensureEngineRunning() else { return }
        if transport == .playing { stopAudio() }

        let total = duration
        var from = max(0, start ?? position)
        if total > 0 && from >= total - 0.05 { from = 0 }   // no fim: recomeça do início

        guard startTransport(from: from, leadIn: 0, recordFile: nil) else {
            transport = .stopped
            return
        }
        position = from
        transport = .playing
    }

    /// Para a reprodução/gravação. Depois de gravar, a cabeça volta ao ponto onde a tomada começou
    /// (para gravar a próxima camada no mesmo trecho). Parar de novo, já parado, volta ao início.
    func stop() {
        switch transport {
        case .stopped:
            position = 0
        case .playing:
            stopAudio()
            transport = .stopped
            trackLevels = [:]
        case .countIn, .recording:
            let reachedRecording = transport == .recording
            stopAudio()
            transport = .stopped
            trackLevels = [:]
            position = take?.startPosition ?? playStartPosition
            finishTake(reportEmpty: reachedRecording)
            if needsRebuild { rebuildEngineIfActive() }
        }
    }

    func record() {
        switch transport {
        case .countIn, .recording: return
        default: break
        }
        guard let current = project else { fail(.noProjectOpen); return }
        if !isActive { activate() }

        let session = AVAudioSession.sharedInstance()
        let permission = session.recordPermission
        if permission == .denied {
            micGranted = false
            fail(.microphoneDenied)
            return
        }
        if permission == .undetermined {
            recordAfterPermission = true
            requestMicPermission()
            return
        }
        if !micGranted {
            micGranted = true
            rebuildEngine()
        }
        guard ensureEngineRunning(), let engine, inputTapInstalled else { fail(.noInput); return }

        let startPosition = max(0, position)
        if transport == .playing {
            stopAudio()
            transport = .stopped
        }

        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { fail(.noInput); return }

        // Arquivo da tomada: PCM float32 em .caf (o tap entrega float32 não intercalado).
        let id = UUID()
        let fileName = "track-\(id.uuidString).caf"
        let folder = StudioStorage.folder(for: current.id)
        let url = folder.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inFormat.sampleRate,
            AVNumberOfChannelsKey: inFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file: AVAudioFile
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            lastError = "Não foi possível criar o arquivo da gravação."
            return
        }

        let beat = 60.0 / max(20, current.bpm)
        let lead = Double(max(0, countInBars) * max(1, current.beatsPerBar)) * beat
        take = PendingTake(id: id, fileName: fileName, url: url, startPosition: startPosition,
                           latency: session.inputLatency + session.outputLatency,
                           sampleRate: inFormat.sampleRate)

        guard startTransport(from: startPosition, leadIn: lead, recordFile: file) else {
            take = nil
            _ = recorder.finish()
            try? FileManager.default.removeItem(at: url)
            return
        }
        position = startPosition
        transport = lead > 0 ? .countIn(beat: 1) : .recording
    }

    func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration)
        switch transport {
        case .stopped:
            position = target
        case .playing:
            stopAudio()
            if startTransport(from: target, leadIn: 0, recordFile: nil) {
                position = target
            } else {
                transport = .stopped
            }
        case .countIn, .recording:
            break   // não dá para mover a cabeça durante a gravação
        }
    }

    // MARK: - Faixas

    func updateTrack(_ track: StudioTrack) {
        guard let index = project?.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        guard project?.tracks[index] != track else { return }
        project?.tracks[index] = track      // didSet aplica ao vivo e salva
    }

    func deleteTrack(_ id: UUID) {
        guard let current = project, let track = current.tracks.first(where: { $0.id == id }) else { return }
        if transport != .stopped { stop() }
        let url = StudioStorage.folder(for: current.id).appendingPathComponent(track.fileName)
        project?.tracks.removeAll { $0.id == id }   // didSet reconstrói o grafo e salva
        try? FileManager.default.removeItem(at: url)
    }

    func importAudio(from url: URL, name: String) async throws -> StudioTrack {
        guard let current = project else { throw fail(.noProjectOpen) }
        let projectID = current.id
        let folder = StudioStorage.folder(for: projectID)
        let trackID = UUID()

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let result: StudioImportResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try StudioFileOps.importCopy(from: url, into: folder, trackID: trackID)
            }.value
        } catch let error as StudioEngineError {
            throw fail(error)
        } catch {
            throw fail(.copyFailed(url.lastPathComponent))
        }

        guard project?.id == projectID else {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(result.fileName))
            throw fail(.projectChanged)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var track = StudioTrack(name: trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed,
                                fileName: result.fileName)
        track.id = trackID
        track.isImported = true
        track.duration = result.duration
        project?.tracks.append(track)       // didSet reconstrói o grafo e salva
        return track
    }

    // MARK: - Exportação

    func exportMix(format: ExportFormat) async throws -> URL {
        guard project != nil else { throw fail(.noProjectOpen) }
        flushSave()
        guard let snapshot = project else { throw fail(.noProjectOpen) }
        let folder = StudioStorage.folder(for: snapshot.id)
        let baseName = StudioStorage.sanitizedFileName(snapshot.name)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName).\(format.rawValue)")

        isExporting = true
        defer { isExporting = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try StudioOfflineRenderer.render(project: snapshot, folder: folder, format: format,
                                                 to: destination)
            }.value
        } catch let error as StudioEngineError {
            throw fail(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw fail(.exportFailed(error.localizedDescription))
        }
        return destination
    }

    // MARK: - Ciclo de vida

    func activate() {
        if isActive {
            if engine == nil || engine?.isRunning == false { rebuildEngine() }
            return
        }
        isActive = true
        configureSession()
        updateRouteInfo()

        let permission = AVAudioSession.sharedInstance().recordPermission
        if permission == .granted {
            micGranted = true
        } else {
            micGranted = false
            if permission == .undetermined { requestMicPermission() }
        }
        rebuildEngine()
        startTimer()
    }

    func deactivate() {
        guard isActive else { return }
        // Marca inativo antes de parar: assim a tomada finalizada não reconstrói o grafo à toa.
        isActive = false
        if transport != .stopped { stop() }
        flushSave()
        rebuildTask?.cancel()
        rebuildTask = nil
        teardownEngine()
        timerCancellable = nil
        inputLevel = 0
        trackLevels = [:]
        recordAfterPermission = false
        restoreIOBuffer()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Sessão de áudio

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        if previousIOBuffer == nil { previousIOBuffer = session.preferredIOBufferDuration }
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            lastError = "Não foi possível configurar o áudio do aparelho. Feche outros apps de áudio e tente de novo."
        }
    }

    private func restoreIOBuffer() {
        guard let previous = previousIOBuffer else { return }
        previousIOBuffer = nil
        // 0 = nunca definido; volta a um valor padrão razoável para as outras abas.
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(previous > 0 ? previous : 0.023)
    }

    private func requestMicPermission() {
        Self.requestRecordPermission { granted in
            Task { @MainActor [weak self] in
                self?.micPermissionResolved(granted)
            }
        }
    }

    /// Fora do MainActor de propósito: o callback do sistema chega numa thread qualquer.
    nonisolated private static func requestRecordPermission(_ done: @escaping @Sendable (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            done(granted)
        }
    }

    private func micPermissionResolved(_ granted: Bool) {
        micGranted = granted
        if granted && isActive { rebuildEngine() }
        if recordAfterPermission {
            recordAfterPermission = false
            if granted { record() } else { fail(.microphoneDenied) }
        }
        if !granted && monitorEnabled { fail(.microphoneDenied) }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleRouteChange(note) }
            .store(in: &sessionCancellables)
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &sessionCancellables)
        center.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleMediaServicesReset() }
            .store(in: &sessionCancellables)
    }

    private func updateRouteInfo() {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let input = route.inputs.first {
            inputName = input.portType == .builtInMic ? "Microfone do iPhone" : input.portName
        } else {
            inputName = "Sem entrada"
        }
        let safePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .lineOut,
        ]
        isHeadphoneConnected = route.outputs.contains { safePorts.contains($0.portType) }
    }

    private func handleRouteChange(_ note: Notification) {
        updateRouteInfo()
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        // Fone desconectado durante a reprodução: para (comportamento padrão do iOS).
        if reason == .oldDeviceUnavailable && transport == .playing { stop() }
        if monitorEnabled && !isHeadphoneConnected { lastError = Self.feedbackWarning }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Ligação, alarme, Siri…: encerra a tomada (o que já foi gravado é salvo).
            if transport != .stopped { stop() }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if isActive && options.contains(.shouldResume) {
                configureSession()
                rebuildEngine()
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard isActive else { return }
        if transport != .stopped { stop() }
        teardownEngine()
        configureSession()
        rebuildEngine()
    }

    private func handleEngineConfigurationChange() {
        // A engine se desliga sozinha quando a rota/formato muda (fone, interface USB…).
        // Se ela continua rodando, a notificação é espúria: ignoramos (evita laço de reconstrução).
        if let engine, engine.isRunning { return }
        if transport != .stopped {
            stop()
            lastError = "A saída ou entrada de áudio mudou. A reprodução foi parada."
        }
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.updateRouteInfo()
            self.rebuildEngine()
        }
    }

    // MARK: - Grafo de áudio

    private func rebuildEngineIfActive() {
        if isActive { rebuildEngine() } else { needsRebuild = false }
    }

    private func rebuildEngine() {
        teardownEngine()
        needsRebuild = false
        guard isActive else { return }

        let newEngine = AVAudioEngine()
        let outFormat = newEngine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            lastError = "Formato de áudio do aparelho não suportado."
            return
        }
        engine = newEngine

        let master = AVAudioMixerNode()
        let limiter = StudioAudioUnits.makeLimiter()
        newEngine.attach(master)
        newEngine.attach(limiter)
        newEngine.connect(master, to: limiter, format: format)
        newEngine.connect(limiter, to: newEngine.mainMixerNode, format: format)
        masterMixer = master

        buildTrackChains(in: newEngine, destination: master, format: format)
        buildClick(in: newEngine, sampleRate: sampleRate)
        if micGranted { wireInput(in: newEngine, format: format) }

        engineConfigCancellable = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: newEngine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleEngineConfigurationChange() }

        updateRouteInfo()
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            lastError = "Não foi possível iniciar o áudio do Estúdio. Feche outros apps de áudio e tente de novo."
        }
    }

    private func buildTrackChains(in engine: AVAudioEngine, destination: AVAudioNode, format: AVAudioFormat) {
        guard let project else { return }
        let folder = StudioStorage.folder(for: project.id)
        var missing: [String] = []
        for track in project.tracks {
            let url = folder.appendingPathComponent(track.fileName)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
                missing.append(track.name)
                continue
            }
            let chain = StudioTrackChain(trackID: track.id, file: file)
            chain.install(in: engine, destination: destination, format: format)
            chain.output.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                    block: StudioTaps.trackTap(id: track.id, meters: meters))
            chains[track.id] = chain
        }
        applyMixToChains()
        if !missing.isEmpty {
            lastError = "Áudio não encontrado para: \(missing.joined(separator: ", "))."
        }
    }

    private func buildClick(in engine: AVAudioEngine, sampleRate: Double) {
        guard let generator = StudioClickGenerator(sampleRate: sampleRate) else { return }
        let node = generator.makeNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: generator.format)
        generator.setClickOn(clickEnabled)
        click = generator
    }

    private func wireInput(in engine: AVAudioEngine, format: AVAudioFormat) {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { return }

        let monitorIn = AVAudioMixerNode()
        let effects = StudioEffectChain()
        let out = AVAudioMixerNode()
        engine.attach(monitorIn)
        engine.attach(out)
        engine.connect(input, to: monitorIn, format: inFormat)
        effects.install(in: engine, from: monitorIn, to: out, format: format)
        engine.connect(out, to: engine.mainMixerNode, format: format)
        effects.apply(monitorEffects)
        out.outputVolume = monitorEnabled ? 1 : 0

        input.installTap(onBus: 0, bufferSize: 1024, format: nil,
                         block: StudioTaps.inputTap(meters: meters, recorder: recorder))
        inputTapInstalled = true
        monitorChain = effects
        monitorOut = out
    }

    private func teardownEngine() {
        engineConfigCancellable = nil
        guard let old = engine else { return }
        if inputTapInstalled {
            old.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        for chain in chains.values {
            chain.output.removeTap(onBus: 0)
            chain.player.stop()
        }
        click?.stop()
        old.stop()
        chains = [:]
        masterMixer = nil
        monitorChain = nil
        monitorOut = nil
        click = nil
        engine = nil
    }

    private func ensureEngineRunning() -> Bool {
        if engine == nil && isActive { rebuildEngine() }
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            lastError = "Não foi possível iniciar o áudio do Estúdio. Feche outros apps de áudio e tente de novo."
            return false
        }
    }

    private func applyMixToChains() {
        guard let project else { return }
        let anySolo = project.tracks.contains { $0.isSolo }
        for track in project.tracks {
            chains[track.id]?.apply(track, anySolo: anySolo)
        }
    }

    private func monitorDidChange() {
        monitorOut?.outputVolume = monitorEnabled ? 1 : 0
        guard monitorEnabled else { return }
        if !isHeadphoneConnected { lastError = Self.feedbackWarning }
        if isActive && !micGranted {
            let permission = AVAudioSession.sharedInstance().recordPermission
            if permission == .undetermined {
                requestMicPermission()
            } else if permission == .denied {
                fail(.microphoneDenied)
            } else {
                micGranted = true
                if transport == .stopped { rebuildEngine() }
            }
        }
    }

    // MARK: - Agendamento

    /// Agenda todas as faixas, o clique e (opcional) a gravação a partir do mesmo instante de host.
    /// `leadIn` = duração da contagem: a posição `from` da música soa leadIn segundos após o início.
    private func startTransport(from: TimeInterval, leadIn: TimeInterval, recordFile: AVAudioFile?) -> Bool {
        guard let engine, engine.isRunning, let project else {
            lastError = "O áudio do Estúdio não está pronto. Tente de novo."
            return false
        }
        let startHost = StudioHostClock.now() &+ StudioHostClock.ticks(forSeconds: 0.08)
        let startTime = AVAudioTime(hostTime: startHost)

        for track in project.tracks {
            guard let chain = chains[track.id] else { continue }
            if chain.schedule(songPosition: from, offset: track.offset, leadIn: leadIn) {
                chain.player.play(at: startTime)
            }
        }
        if let recordFile {
            recorder.arm(file: recordFile, startHost: startHost &+ StudioHostClock.ticks(forSeconds: leadIn))
        }
        click?.start(startHost: startHost,
                     songTimeAtStart: from - leadIn,
                     countInEnd: recordFile != nil ? from : -Double.infinity,
                     bpm: project.bpm,
                     beatsPerBar: project.beatsPerBar,
                     clickOn: clickEnabled)

        playStartHost = startHost
        playStartPosition = from
        self.leadIn = leadIn
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    private func stopAudio() {
        for chain in chains.values { chain.player.stop() }
        click?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Tomada

    private func finishTake(reportEmpty: Bool) {
        guard let pending = take else {
            _ = recorder.finish()
            return
        }
        take = nil
        let result = recorder.finish()     // fecha o arquivo
        let seconds = pending.sampleRate > 0 ? Double(result.frames) / pending.sampleRate : 0

        if let failure = result.failure {
            try? FileManager.default.removeItem(at: pending.url)
            lastError = "Erro ao gravar: \(failure)."
            return
        }
        guard seconds >= 0.2 else {
            try? FileManager.default.removeItem(at: pending.url)
            if reportEmpty { lastError = "A gravação ficou curta demais e não foi salva." }
            return
        }
        guard project != nil else {
            try? FileManager.default.removeItem(at: pending.url)
            return
        }

        var track = StudioTrack(name: nextTrackName(), fileName: pending.fileName)
        track.id = pending.id
        track.offset = pending.startPosition - pending.latency
        track.effects = monitorEffects
        track.isImported = false
        track.duration = seconds
        project?.tracks.append(track)       // didSet (transporte já parado) reconstrói o grafo e salva
    }

    /// Descarta a tomada em andamento (usado quando o projeto é trocado por fora no meio da gravação).
    private func abortTransport() {
        stopAudio()
        transport = .stopped
        trackLevels = [:]
        if let pending = take {
            take = nil
            _ = recorder.finish()
            try? FileManager.default.removeItem(at: pending.url)
        }
    }

    private func nextTrackName() -> String {
        let names = Set(project?.tracks.map { $0.name } ?? [])
        var n = (project?.tracks.count ?? 0) + 1
        while names.contains("Faixa \(n)") { n += 1 }
        return "Faixa \(n)"
    }

    // MARK: - Timer (~20 Hz): posição, contagem e medidores

    private func startTimer() {
        guard timerCancellable == nil else { return }
        timerCancellable = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let levels = meters.take()
        let smoothedInput = max(levels.input, inputLevel * 0.82)
        let newInput: Float = smoothedInput < 0.01 ? 0 : smoothedInput
        if abs(newInput - inputLevel) > 0.002 { inputLevel = newInput }

        guard transport != .stopped else { return }
        let elapsed = max(0, StudioHostClock.seconds(from: playStartHost, to: StudioHostClock.now()))
        let songTime = playStartPosition - leadIn + elapsed

        switch transport {
        case .countIn:
            if songTime >= playStartPosition {
                transport = .recording
            } else {
                let beat = countInBeat(at: songTime)
                if transport != .countIn(beat: beat) { transport = .countIn(beat: beat) }
            }
            position = playStartPosition
        case .recording:
            position = max(playStartPosition, songTime)
        case .playing:
            position = max(0, songTime)
            let total = duration
            if total > 0 && position >= total + 0.1 {
                stop()
                position = 0
                return
            }
        case .stopped:
            break
        }

        var newLevels: [UUID: Float] = [:]
        for id in chains.keys {
            let previous = trackLevels[id] ?? 0
            let value = max(levels.tracks[id] ?? 0, previous * 0.82)
            newLevels[id] = value < 0.01 ? 0 : value
        }
        if newLevels != trackLevels { trackLevels = newLevels }
    }

    /// Tempo do compasso (1…beatsPerBar) na grade da música — o mesmo usado pelo clique.
    private func countInBeat(at songTime: TimeInterval) -> Int {
        let bpm = max(20, project?.bpm ?? 90)
        let bpb = max(1, project?.beatsPerBar ?? 4)
        let index = Int((songTime / (60.0 / bpm)).rounded(.down))
        return ((index % bpb) + bpb) % bpb + 1
    }

    // MARK: - Persistência

    private func projectDidChange(from old: StudioProject?) {
        guard !suppressObservation else { return }
        let new = project

        if old?.id != new?.id {
            // Troca de projeto (open/new/close, ou a UI atribuiu outro projeto direto).
            if saveTask != nil, let old {
                saveTask?.cancel()
                saveTask = nil
                var stamped = old
                stamped.updatedAt = Date()
                writeProject(stamped)
            }
            if transport != .stopped { abortTransport() }
            position = 0
            if let new { upsertInList(new) }
            rebuildEngineIfActive()
            return
        }

        guard let new, let old, new != old else { return }
        let oldIDs = old.tracks.map { $0.id }
        let newIDs = new.tracks.map { $0.id }
        if oldIDs != newIDs {
            if transport == .playing { stop() }
            if transport == .stopped { rebuildEngineIfActive() } else { needsRebuild = true }
            saveNow()       // mudança estrutural: salva já
        } else {
            applyMixToChains()
            upsertInList(new)
            scheduleSave()  // ajustes de volume/pan/efeito: salva com debounce
        }
        if old.bpm != new.bpm || old.beatsPerBar != new.beatsPerBar {
            click?.setTempo(bpm: new.bpm, beatsPerBar: new.beatsPerBar)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func flushSave() {
        if saveTask != nil { saveNow() }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard var current = project else { return }
        current.updatedAt = Date()
        suppressObservation = true
        project = current
        suppressObservation = false
        writeProject(current)
    }

    private func writeProject(_ p: StudioProject) {
        do {
            try StudioStorage.write(p)
        } catch {
            lastError = "Não foi possível salvar o projeto “\(p.name)”."
        }
        upsertInList(p)
    }

    private func upsertInList(_ p: StudioProject) {
        var list = projects
        if let index = list.firstIndex(where: { $0.id == p.id }) {
            list[index] = p
        } else {
            list.append(p)
        }
        list.sort { $0.updatedAt > $1.updatedAt }
        projects = list
    }

    private func stopForProjectSwitch() {
        if transport != .stopped { stop() }
        flushSave()
    }

    @discardableResult
    private func fail(_ error: StudioEngineError) -> StudioEngineError {
        lastError = error.errorDescription
        return error
    }
}
