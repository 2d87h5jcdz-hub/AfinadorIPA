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
// (inputLatency) — vira offset negativo do clip novo: offset = posiçãoInicial − (inputLatency + outputLatency).
// Se isso der < 0 (gravação a partir do 0), o começo é aparado: offset = 0 e fileStart = −offset.
//
// v2 (linha do tempo com clips): cada faixa tem `clips`. Reprodução/exportação agendam todos os clips
// (StudioTrackChain/StudioClipLane); a gravação entra na faixa ARMADA a partir da cabeça de reprodução
// e substitui o que houver por baixo (punch-in, StudioTimeline.punchIn). Os campos legados da faixa
// (fileName/offset/duration) são mantidos como espelho dos clips (studioSyncLegacyFields).

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
    /// Entradas disponíveis agora (microfone do iPhone, microfone do fone, interface USB…).
    @Published private(set) var availableInputs: [StudioInputOption] = []
    /// uid da entrada em uso.
    @Published private(set) var selectedInputID: String?
    /// Ganho digital da entrada, em dB (0…+24). Vale para o monitoramento, o medidor e a gravação.
    @Published var inputGainDB: Float = 0 {
        didSet {
            let clamped = min(24, max(0, inputGainDB))
            if clamped != inputGainDB { inputGainDB = clamped; return }
            inputGain.setDecibels(clamped)
            inputBoost?.globalGain = clamped
            UserDefaults.standard.set(clamped, forKey: Keys.inputGain)
        }
    }
    @Published private(set) var lastError: String?

    /// Maior faixa do projeto (fim do último clip).
    var duration: TimeInterval {
        guard let project else { return 0 }
        var longest: TimeInterval = 0
        for track in project.tracks {
            longest = max(longest, track.end)
        }
        return max(0, longest)
    }

    // MARK: v2: linha do tempo / clips (contrato)

    /// Faixa que recebe a próxima gravação. nil = record() cria uma faixa nova e a arma.
    /// Só em memória: zera ao trocar/fechar o projeto e quando a faixa armada é apagada.
    @Published var armedTrackID: UUID? = nil {
        didSet {
            guard armedTrackID != oldValue, let id = armedTrackID else { return }
            if project?.tracks.contains(where: { $0.id == id }) != true { armedTrackID = nil }
        }
    }
    /// Começo da gravação em andamento na linha do tempo (s) = cabeça de reprodução quando record()
    /// começou (sem a compensação de latência). Não-nil desde record() (inclui a contagem) até o fim
    /// da tomada; o fim do clip "ao vivo" é `position`.
    @Published private(set) var recordingStart: TimeInterval? = nil

    // MARK: Extras (além do contrato)

    /// true enquanto exportMix está renderizando.
    @Published private(set) var isExporting = false
    /// Afinação automática em andamento: faixa → progresso 0…1.
    @Published private(set) var pitchProgress: [UUID: Double] = [:]

    /// Latência que será compensada na próxima gravação (s).
    var latencyCompensation: TimeInterval {
        let s = AVAudioSession.sharedInstance()
        return s.inputLatency + s.outputLatency
    }

    /// URL do arquivo de áudio de uma faixa do projeto aberto (v2: o do primeiro clip).
    func fileURL(for track: StudioTrack) -> URL? {
        guard let project else { return nil }
        let name = track.clips.first?.fileName ?? track.fileName
        guard !name.isEmpty else { return nil }
        return StudioStorage.folder(for: project.id).appendingPathComponent(name)
    }

    /// URL do arquivo de áudio de um clip do projeto aberto.
    func fileURL(for clip: StudioClip) -> URL? {
        guard let project, !clip.fileName.isEmpty else { return nil }
        return StudioStorage.folder(for: project.id).appendingPathComponent(clip.fileName)
    }

    func clearError() { lastError = nil }

    // MARK: Estado interno

    private enum Keys {
        static let click = "studio.clickEnabled"
        static let countIn = "studio.countInBars"
        static let preferredInputType = "studio.preferredInputType"
        static let inputGain = "studio.inputGainDB"
    }

    private static let feedbackWarning =
        "Sem fone de ouvido: ouvir a entrada pelo alto-falante pode causar microfonia. Use fone para monitorar."

    private struct PendingTake {
        let fileName: String
        let url: URL
        let startPosition: TimeInterval
        let latency: TimeInterval
        let sampleRate: Double
        /// Faixa que recebe a tomada.
        let trackID: UUID
        /// true se record() criou a faixa (sem nada armado): sai se a tomada não for salva.
        let createdTrack: Bool
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
    private let inputGain = StudioInputGain()
    private var inputBoost: AVAudioUnitEQ?

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
    /// Trabalhos de afinação por faixa (chave = o que está sendo gerado, para não repetir).
    private var pitchTasks: [UUID: (key: String, task: Task<Void, Never>)] = [:]
    private var pitchRefreshTask: Task<Void, Never>?
    /// Trabalhos que falharam (sem voz para achar o tom): não repete até mudar algo.
    private var pitchFailed: Set<String> = []
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
        // No init os didSet não rodam: aplica o ganho salvo à mão.
        let savedGain = min(24, max(0, defaults.float(forKey: Keys.inputGain)))
        inputGainDB = savedGain
        inputGain.setDecibels(savedGain)
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

        guard startTransport(from: from, leadIn: 0, recordFile: nil, silencing: nil) else {
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
            if needsRebuild { rebuildEngineIfActive() }
        case .countIn, .recording:
            let reachedRecording = transport == .recording
            stopAudio()
            transport = .stopped
            trackLevels = [:]
            position = take?.startPosition ?? playStartPosition
            recordingStart = nil
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
        let fileName = "take-\(UUID().uuidString).caf"
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

        // Faixa de destino: a armada; sem nada armado, cria uma faixa vazia e a arma (v1: faixa nova).
        // Adicionar faixa vazia não reconstrói o grafo (não muda o que toca), só salva.
        let targetID: UUID
        let created: Bool
        if let armed = armedTrackID, current.tracks.contains(where: { $0.id == armed }) {
            targetID = armed
            created = false
        } else {
            var track = StudioTrack(name: nextTrackName())
            track.effects = monitorEffects
            project?.tracks.append(track)       // didSet: só salva (faixa sem clips)
            armedTrackID = track.id
            targetID = track.id
            created = true
        }

        let beat = 60.0 / max(20, current.bpm)
        let lead = Double(max(0, countInBars) * max(1, current.beatsPerBar)) * beat
        take = PendingTake(fileName: fileName, url: url, startPosition: startPosition,
                           latency: session.inputLatency + session.outputLatency,
                           sampleRate: inFormat.sampleRate, trackID: targetID, createdTrack: created)

        // A faixa armada não toca durante a gravação: o trecho a partir daqui será substituído.
        guard startTransport(from: startPosition, leadIn: lead, recordFile: file, silencing: targetID) else {
            take = nil
            _ = recorder.finish()
            try? FileManager.default.removeItem(at: url)
            if created { removeEmptyTrack(targetID) }
            return
        }
        position = startPosition
        recordingStart = startPosition
        transport = lead > 0 ? .countIn(beat: 1) : .recording
    }

    /// Quanto a cabeça pode passar do fim da música (para gravar mais adiante numa faixa vazia/armada).
    static let seekBeyondEnd: TimeInterval = 600

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        let total = duration
        let limit = max(total, position) + Self.seekBeyondEnd
        let target = min(max(0, time), limit)
        switch transport {
        case .stopped:
            position = target
        case .playing:
            stopAudio()
            if total > 0 && target >= total - 0.05 {
                // Depois do fim não há o que tocar: para e deixa a cabeça ali (pronta para gravar).
                transport = .stopped
                trackLevels = [:]
                position = target
                if needsRebuild { rebuildEngineIfActive() }
                return
            }
            if startTransport(from: target, leadIn: 0, recordFile: nil, silencing: nil) {
                position = target
            } else {
                transport = .stopped
            }
        case .countIn, .recording:
            break   // não dá para mover a cabeça durante a gravação
        }
    }

    /// Leva a cabeça de reprodução ao fim da faixa ("continuar de onde parou").
    func seekToEnd(of trackID: UUID) {
        guard let track = project?.tracks.first(where: { $0.id == trackID }) else { return }
        seek(to: track.end)
    }

    // MARK: - Faixas

    /// Atualiza nome/volume/pan/mudo/solo/efeitos. Os clips (e campos legados) da faixa NÃO vêm do
    /// parâmetro: são preservados do projeto atual, para uma cópia antiga da faixa na UI não desfazer
    /// uma gravação/edição de clips. Para mexer em clips use moveClip/deleteClip/record.
    func updateTrack(_ track: StudioTrack) {
        guard let index = project?.tracks.firstIndex(where: { $0.id == track.id }),
              let existing = project?.tracks[index] else { return }
        var merged = track
        merged.clips = existing.clips
        merged.fileName = existing.fileName
        merged.offset = existing.offset
        merged.duration = existing.duration
        guard existing != merged else { return }
        project?.tracks[index] = merged     // didSet aplica ao vivo e salva
    }

    /// Apaga a faixa e os arquivos de áudio dela que nenhuma outra faixa usa.
    func deleteTrack(_ id: UUID) {
        guard let current = project, let track = current.tracks.first(where: { $0.id == id }) else { return }
        if transport != .stopped { stop() }
        var files = Set(track.clips.map { $0.fileName })
        if !track.fileName.isEmpty { files.insert(track.fileName) }
        // stop() pode ter acabado de gravar nesta faixa: relê os clips atuais.
        if let fresh = project?.tracks.first(where: { $0.id == id }) {
            for clip in fresh.clips { files.insert(clip.fileName) }
        }
        if armedTrackID == id { armedTrackID = nil }
        project?.tracks.removeAll { $0.id == id }   // didSet reconstrói o grafo e salva
        if let updated = project {
            StudioTimeline.deleteUnreferenced(files, project: updated,
                                              folder: StudioStorage.folder(for: current.id))
        }
    }

    /// Cria uma faixa vazia ("Faixa N" se name for nil/vazio), salva e a deixa armada
    /// (o armar é ignorado durante contagem/gravação). Não reconstrói o grafo.
    @discardableResult
    func addEmptyTrack(name: String? = nil) -> StudioTrack {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var track = StudioTrack(name: trimmed.isEmpty ? nextTrackName() : trimmed)
        track.effects = .preset(.none)
        guard project != nil else {
            fail(.noProjectOpen)
            return track
        }
        project?.tracks.append(track)       // didSet salva (faixa sem clips: grafo intacto)
        switch transport {
        case .stopped, .playing: armedTrackID = track.id
        case .countIn, .recording: break
        }
        return track
    }

    /// Arma (ou desarma com nil) a faixa da próxima gravação. Ignorado se o transporte não estiver
    /// parado ou se a faixa não existir no projeto aberto.
    func arm(_ trackID: UUID?) {
        guard transport == .stopped else { return }
        guard let trackID else { armedTrackID = nil; return }
        guard project?.tracks.contains(where: { $0.id == trackID }) == true else { return }
        armedTrackID = trackID
    }

    /// Move um clip na linha do tempo (offset >= 0). Só com o transporte parado.
    func moveClip(_ clipID: UUID, in trackID: UUID, to offset: TimeInterval) {
        guard transport == .stopped, offset.isFinite,
              let t = project?.tracks.firstIndex(where: { $0.id == trackID }),
              var track = project?.tracks[t],
              let c = track.clips.firstIndex(where: { $0.id == clipID }) else { return }
        let target = max(0, offset)
        guard abs(track.clips[c].offset - target) > 0.000_1 else { return }
        track.clips[c].offset = target
        track.studioSyncLegacyFields()      // reordena por offset
        project?.tracks[t] = track          // didSet reconstrói o grafo e salva
    }

    /// Remove um clip (apaga o arquivo se nenhum outro clip do projeto o usa). Só parado.
    func deleteClip(_ clipID: UUID, in trackID: UUID) {
        guard transport == .stopped, let current = project,
              let t = current.tracks.firstIndex(where: { $0.id == trackID }),
              let clip = current.tracks[t].clips.first(where: { $0.id == clipID }) else { return }
        var track = current.tracks[t]
        track.clips.removeAll { $0.id == clipID }
        track.studioSyncLegacyFields()
        project?.tracks[t] = track          // didSet reconstrói o grafo e salva
        if let updated = project {
            StudioTimeline.deleteUnreferenced([clip.fileName], project: updated,
                                              folder: StudioStorage.folder(for: current.id))
        }
    }

    /// Forma de onda do trecho tocado do clip (fileStart…fileStart+duration): `buckets` picos lineares
    /// 0…1 (máximo absoluto entre canais; não normalizado pelo clip). Calcula fora da main thread e
    /// guarda "<arquivo>.peaks" na pasta do projeto; chamadas seguintes só fatiam. [] em erro.
    func waveform(for clip: StudioClip, buckets: Int) async -> [Float] {
        guard buckets > 0, let url = fileURL(for: clip) else { return [] }
        return await StudioWaveforms.waveform(fileURL: url, fileStart: clip.fileStart,
                                              duration: clip.duration, buckets: buckets)
    }

    /// Tira uma faixa criada por record() que ficou sem nenhum clip.
    private func removeEmptyTrack(_ id: UUID) {
        guard let track = project?.tracks.first(where: { $0.id == id }), track.clips.isEmpty else { return }
        if armedTrackID == id { armedTrackID = nil }
        project?.tracks.removeAll { $0.id == id }
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
        var track = StudioTrack(name: trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed)
        track.id = trackID
        track.isImported = true
        track.clips = [StudioClip(fileName: result.fileName, offset: 0, fileStart: 0, duration: result.duration)]
        track.studioSyncLegacyFields()
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
            applyPreferredInput()
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
        // Não reconstrói o grafo no meio da reprodução (mataria o som sem atualizar o transporte).
        if granted && isActive {
            if transport == .stopped { rebuildEngine() } else { needsRebuild = true }
        }
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

    // MARK: - Escolha da entrada

    /// Nome amigável de uma porta de entrada.
    private static func inputTitle(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic: return "Microfone do iPhone"
        case .headsetMic: return "Microfone do fone"
        case .bluetoothHFP: return "\(port.portName) (Bluetooth)"
        default: return port.portName
        }
    }

    /// Ao plugar um fone com microfone, o iOS troca a entrada para o microfone do fone (longe do
    /// violão, capta baixo). Aqui vale a escolha do usuário; sem escolha salva: interface USB se
    /// houver, senão o microfone do iPhone.
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        guard !inputs.isEmpty else { return }
        let saved = UserDefaults.standard.string(forKey: Keys.preferredInputType)
        let target = inputs.first { $0.portType.rawValue == saved }
            ?? inputs.first { $0.portType == .usbAudio }
            ?? inputs.first { $0.portType == .builtInMic }
        guard let target else { return }
        if session.currentRoute.inputs.first?.uid == target.uid { return }
        do {
            try session.setPreferredInput(target)
        } catch {
            lastError = "Não foi possível usar \(Self.inputTitle(target)) como entrada."
        }
    }

    /// Troca a entrada (só com o transporte parado). A escolha fica salva pelo tipo de entrada.
    func selectInput(_ id: String) {
        guard transport == .stopped else { return }
        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == id }) else { return }
        UserDefaults.standard.set(port.portType.rawValue, forKey: Keys.preferredInputType)
        do {
            try session.setPreferredInput(port)
        } catch {
            lastError = "Não foi possível usar \(Self.inputTitle(port)) como entrada."
        }
        updateRouteInfo()
    }

    private func updateRouteInfo() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        availableInputs = (session.availableInputs ?? []).map {
            StudioInputOption(id: $0.uid, name: Self.inputTitle($0), portType: $0.portType.rawValue)
        }
        selectedInputID = route.inputs.first?.uid
        if let input = route.inputs.first {
            inputName = Self.inputTitle(input)
        } else {
            inputName = "Sem entrada"
        }
        let safePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .lineOut,
        ]
        isHeadphoneConnected = route.outputs.contains { safePorts.contains($0.portType) }
    }

    private func handleRouteChange(_ note: Notification) {
        if isActive && transport == .stopped { applyPreferredInput() }
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
        for track in project.tracks where !track.clips.isEmpty {
            let clips: [StudioClip] = StudioPitchFiles.playbackClips(for: track, folder: folder)
            let chain = StudioTrackChain(trackID: track.id, clips: clips, folder: folder)
            if chain.missingClips > 0 { missing.append(track.name) }
            guard chain.isPlayable else { continue }
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

        // Ganho da entrada no monitoramento (a gravação recebe o mesmo ganho no tap).
        let boost = AVAudioUnitEQ(numberOfBands: 1)
        boost.bands[0].bypass = true
        boost.globalGain = inputGainDB
        let monitorIn = AVAudioMixerNode()
        let effects = StudioEffectChain()
        let out = AVAudioMixerNode()
        engine.attach(boost)
        engine.attach(monitorIn)
        engine.attach(out)
        engine.connect(input, to: boost, format: inFormat)
        engine.connect(boost, to: monitorIn, format: inFormat)
        inputBoost = boost
        effects.install(in: engine, from: monitorIn, to: out, format: format)
        engine.connect(out, to: engine.mainMixerNode, format: format)
        effects.apply(monitorEffects)
        out.outputVolume = monitorEnabled ? 1 : 0

        input.installTap(onBus: 0, bufferSize: 1024, format: nil,
                         block: StudioTaps.inputTap(meters: meters, recorder: recorder, gain: inputGain))
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
            chain.stop()
        }
        click?.stop()
        old.stop()
        chains = [:]
        masterMixer = nil
        monitorChain = nil
        monitorOut = nil
        inputBoost = nil
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
    /// `silencing` = faixa que não toca (a faixa armada durante a gravação).
    private func startTransport(from: TimeInterval, leadIn: TimeInterval, recordFile: AVAudioFile?,
                                silencing: UUID?) -> Bool {
        guard let engine, engine.isRunning, let project else {
            lastError = "O áudio do Estúdio não está pronto. Tente de novo."
            return false
        }
        let startHost = StudioHostClock.now() &+ StudioHostClock.ticks(forSeconds: 0.08)
        let startTime = AVAudioTime(hostTime: startHost)

        for track in project.tracks {
            guard let chain = chains[track.id] else { continue }
            if track.id == silencing {
                chain.stop()
                continue
            }
            if chain.schedule(songPosition: from, leadIn: leadIn) {
                chain.play(at: startTime)
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
        for chain in chains.values { chain.stop() }
        click?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Tomada

    private func finishTake(reportEmpty: Bool) {
        recordingStart = nil
        guard let pending = take else {
            _ = recorder.finish()
            return
        }
        take = nil
        let result = recorder.finish()     // fecha o arquivo
        let seconds = pending.sampleRate > 0 ? Double(result.frames) / pending.sampleRate : 0

        func discard() {
            try? FileManager.default.removeItem(at: pending.url)
            if pending.createdTrack { removeEmptyTrack(pending.trackID) }
        }

        if let failure = result.failure {
            discard()
            lastError = "Erro ao gravar: \(failure)."
            return
        }
        guard seconds >= 0.2 else {
            discard()
            if reportEmpty { lastError = "A gravação ficou curta demais e não foi salva." }
            return
        }
        guard let current = project else {
            try? FileManager.default.removeItem(at: pending.url)
            return
        }

        // Clip novo, com a compensação de latência. Começo antes de 0 é aparado (fileStart).
        var clip = StudioClip(fileName: pending.fileName, offset: pending.startPosition - pending.latency,
                              fileStart: 0, duration: seconds)
        if clip.offset < 0 {
            let cut = -clip.offset
            clip.offset = 0
            clip.fileStart = cut
            clip.duration = seconds - cut
        }
        guard clip.duration >= 0.05 else {
            discard()
            if reportEmpty { lastError = "A gravação ficou curta demais e não foi salva." }
            return
        }

        if let index = current.tracks.firstIndex(where: { $0.id == pending.trackID }) {
            var track = current.tracks[index]
            let previousFiles = Set(track.clips.map { $0.fileName })
            // Primeira gravação numa faixa sem efeito: herda o efeito do monitoramento (como na v1).
            if track.clips.isEmpty && track.effects == EffectSettings.preset(.none) {
                track.effects = monitorEffects
            }
            track.clips = StudioTimeline.punchIn(clip, into: track.clips)
            track.studioSyncLegacyFields()
            project?.tracks[index] = track      // didSet (transporte já parado) reconstrói o grafo e salva
            if let updated = project {
                StudioTimeline.deleteUnreferenced(previousFiles, project: updated,
                                                  folder: StudioStorage.folder(for: current.id))
            }
        } else {
            // A faixa sumiu durante a gravação: a tomada vira uma faixa nova (comportamento v1).
            var track = StudioTrack(name: nextTrackName())
            track.effects = monitorEffects
            track.isImported = false
            track.clips = [clip]
            track.studioSyncLegacyFields()
            project?.tracks.append(track)
            armedTrackID = track.id
        }
    }

    /// Descarta a tomada em andamento (usado quando o projeto é trocado por fora no meio da gravação).
    private func abortTransport() {
        stopAudio()
        transport = .stopped
        trackLevels = [:]
        recordingStart = nil
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
            armedTrackID = nil
            if let new { upsertInList(new) }
            rebuildEngineIfActive()
            schedulePitchRefresh()
            return
        }

        guard let new, let old, new != old else { return }
        if let armed = armedTrackID, !new.tracks.contains(where: { $0.id == armed }) {
            armedTrackID = nil      // faixa armada apagada
        }
        let oldIDs = old.tracks.map { $0.id }
        let newIDs = new.tracks.map { $0.id }
        schedulePitchRefresh()
        if Self.playbackLayout(old) != Self.playbackLayout(new) || Self.pitchLayout(old) != Self.pitchLayout(new) {
            // Mudou o que toca (faixa com clips entrou/saiu, clip movido/aparado/apagado).
            if transport == .playing { stop() }
            if transport == .stopped { rebuildEngineIfActive() } else { needsRebuild = true }
            saveNow()       // mudança estrutural: salva já
        } else if oldIDs != newIDs {
            // Só faixas vazias entraram/saíram ou a ordem mudou: o grafo continua válido.
            applyMixToChains()
            saveNow()
        } else {
            applyMixToChains()
            upsertInList(new)
            scheduleSave()  // ajustes de volume/pan/efeito: salva com debounce
        }
        if old.bpm != new.bpm || old.beatsPerBar != new.beatsPerBar {
            click?.setTempo(bpm: new.bpm, beatsPerBar: new.beatsPerBar)
        }
    }

    /// Assinatura da afinação por faixa: se muda, os arquivos tocados mudam (reconstrói o grafo).
    private static func pitchLayout(_ p: StudioProject) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for track in p.tracks where track.pitch.enabled {
            map[track.id] = track.effectsOn ? (track.pitch.signature ?? "") : "fx-off"
        }
        return map
    }

    // MARK: - Afinação automática

    /// Agenda uma verificação (com espera curta: o controle de intensidade muda muitas vezes seguidas).
    private func schedulePitchRefresh() {
        pitchRefreshTask?.cancel()
        pitchRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self?.refreshPitchCorrection()
        }
    }

    /// Começa (ou cancela) os trabalhos de afinação conforme as faixas do projeto aberto.
    private func refreshPitchCorrection() {
        guard let project else {
            for (_, job) in pitchTasks { job.task.cancel() }
            pitchTasks = [:]
            pitchProgress = [:]
            return
        }
        let folder = StudioStorage.folder(for: project.id)
        var wanted: Set<UUID> = []
        for track in project.tracks where track.pitch.enabled && !track.clips.isEmpty {
            let sources: [String] = Array(Set(track.clips.map(\.fileName))).sorted()
            let jobKey: String = (track.pitch.signature ?? "detect|\(track.pitch.strength)") + "|" + sources.joined(separator: ",")
            if track.pitch.signature != nil && StudioPitchFiles.isReady(track: track, folder: folder) {
                continue    // tudo pronto
            }
            if pitchFailed.contains(jobKey) { continue }
            wanted.insert(track.id)
            if let running = pitchTasks[track.id], running.key == jobKey { continue }
            pitchTasks[track.id]?.task.cancel()
            startPitchJob(trackID: track.id, sources: sources, settings: track.pitch, folder: folder, jobKey: jobKey)
        }
        for (id, job) in pitchTasks where !wanted.contains(id) {
            job.task.cancel()
            pitchTasks[id] = nil
            pitchProgress[id] = nil
        }
    }

    private func startPitchJob(trackID: UUID, sources: [String], settings: PitchCorrection,
                               folder: URL, jobKey: String) {
        pitchProgress[trackID] = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = StudioPitchJob.run(
                folder: folder, sources: sources, settings: settings,
                progress: { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.pitchTasks[trackID]?.key == jobKey else { return }
                        self.pitchProgress[trackID] = value
                    }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.pitchJobFinished(trackID: trackID, jobKey: jobKey, outcome: outcome)
            }
        }
        pitchTasks[trackID] = (key: jobKey, task: task)
    }

    private func pitchJobFinished(trackID: UUID, jobKey: String, outcome: StudioPitchJob.Outcome) {
        guard pitchTasks[trackID]?.key == jobKey else { return }    // já substituído por outro
        pitchTasks[trackID] = nil
        pitchProgress[trackID] = nil
        guard let index = project?.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if outcome.noVoice {
            pitchFailed.insert(jobKey)
            let name = project?.tracks[index].name ?? "a faixa"
            lastError = "Não encontrei voz suficiente em “\(name)” para descobrir o tom. Escolha o tom à mão."
            return
        }
        if let key = outcome.detectedKey, project?.tracks[index].pitch.isAuto == true {
            // Guarda o tom achado (dispara projectDidChange → reconstrói com os arquivos novos).
            project?.tracks[index].pitch.detectedKey = key
            project?.tracks[index].pitch.detectedScale = outcome.detectedScale
        }
        if outcome.completed {
            if transport == .stopped { rebuildEngineIfActive() } else { needsRebuild = true }
        }
    }

    /// Clips por faixa (só faixas com clips): se isso muda, o grafo precisa ser reconstruído.
    private static func playbackLayout(_ p: StudioProject) -> [UUID: [StudioClip]] {
        var map: [UUID: [StudioClip]] = [:]
        for track in p.tracks where !track.clips.isEmpty { map[track.id] = track.clips }
        return map
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
        // Rede de segurança: se a UI mexeu em `clips` direto, o espelho legado é corrigido antes de salvar
        // (senão uma faixa esvaziada voltaria a ter o clip antigo ao reabrir, pela migração v1 do decoder).
        for i in current.tracks.indices { current.tracks[i].studioSyncLegacyFields() }
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
