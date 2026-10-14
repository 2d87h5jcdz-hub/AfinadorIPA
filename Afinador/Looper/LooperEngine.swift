import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - LooperEngine
//
// Motor da aba Loop (pedaleira de loop ao vivo).
//
//   inputNode → ganho (EQ global) → mixer → [cadeia de efeitos do Estúdio] → Loop (AU próprio) → mainMixer
//
// O Audio Unit do Loop (PestanaLooperAU / LooperCore em C++) recebe a entrada já com efeitos, grava
// nas faixas e devolve entrada (se "Ouvir a entrada" estiver ligado) + loops. A sincronia é por
// amostra, dentro do próprio render; a latência de ida e volta (entrada + saída + 2 buffers de I/O)
// é compensada na escrita, com ajuste fino pelo usuário.
//
// Os nós (efeitos e Loop) são criados uma vez e reaproveitados quando o AVAudioEngine é recriado
// (troca de fone, interrupção): os loops ficam na memória enquanto a taxa de amostragem não mudar.

@MainActor
final class LooperEngine: ObservableObject {

    struct TrackInfo: Equatable {
        var state: PestanaLoopTrackState = .empty
        var muted = false
        var canUndo = false
        var progress: Float = 0
        var level: Float = 0
        var length: Double = 0
        var multiplier = 1
    }

    static let maxTracks = PestanaLooperAU.maxTracks

    // MARK: Estado publicado

    @Published private(set) var tracks: [TrackInfo] = Array(repeating: TrackInfo(), count: LooperEngine.maxTracks)
    @Published var trackCount: Int {
        didSet {
            let clamped = min(Self.maxTracks, max(1, trackCount))
            if clamped != trackCount { trackCount = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Keys.trackCount)
            if selected >= clamped { selected = clamped - 1 }
            applyAuto()
        }
    }
    @Published var selected: Int = 0
    @Published private(set) var playing = false
    @Published private(set) var hasContent = false
    @Published private(set) var baseSeconds: Double = 0
    @Published private(set) var positionSeconds: Double = 0
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var running = false
    @Published private(set) var isHeadphoneConnected = false
    @Published private(set) var inputName = ""
    @Published private(set) var latencyMS: Double = 0
    @Published var permissionDenied = false
    @Published var lastError: String?

    @Published var monitorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitorEnabled, forKey: Keys.monitor)
            looper?.setMonitor(monitorEnabled)
        }
    }
    @Published var effects: EffectSettings {
        didSet {
            effectChain.apply(effects)
            if let data = try? JSONEncoder().encode(effects) {
                UserDefaults.standard.set(data, forKey: Keys.effects)
            }
        }
    }
    /// Ajuste fino da compensação de latência (ms). Positivo = o que você grava entra mais cedo.
    @Published var latencyTrimMS: Double {
        didSet {
            UserDefaults.standard.set(latencyTrimMS, forKey: Keys.trim)
            updateLatency()
        }
    }
    @Published var inputGainDB: Float {
        didSet {
            let clamped = min(24, max(0, inputGainDB))
            if clamped != inputGainDB { inputGainDB = clamped; return }
            boost?.globalGain = clamped
            UserDefaults.standard.set(clamped, forKey: Keys.inputGain)
        }
    }
    @Published private(set) var volumes: [Float]

    // MARK: Modo automático (tempo e compassos)

    @Published var autoEnabled: Bool { didSet { saveAuto() } }
    @Published var bpm: Int { didSet { let c = min(240, max(40, bpm)); if c != bpm { bpm = c; return }; saveAuto() } }
    @Published var beatsPerBar: Int { didSet { saveAuto() } }
    @Published var bars: Int { didSet { saveAuto() } }
    @Published var startOnSound: Bool { didSet { saveAuto() } }
    @Published var chain: Bool { didSet { saveAuto() } }
    @Published var gapCycles: Int { didSet { saveAuto() } }
    @Published var clickInLoop: Bool { didSet { saveAuto() } }
    /// 0 = pouca (precisa tocar forte), 1 = média, 2 = muita.
    @Published var soundSensitivity: Int { didSet { saveAuto() } }
    @Published private(set) var phase: PestanaLoopPhase = .none
    @Published private(set) var beat: Int = 0
    @Published private(set) var autoCycleSeconds: Double = 0
    private var tapTimes: [Date] = []

    // MARK: Interno

    private enum Keys {
        static let trackCount = "loop.trackCount"
        static let monitor = "loop.monitor"
        static let effects = "loop.effects"
        static let trim = "loop.latencyTrimMS"
        static let inputGain = "loop.inputGainDB"
        static let volumes = "loop.volumes"
        static let multipliers = "loop.multipliers"
        static let auto = "loop.auto"
        static let preferredInputType = "studio.preferredInputType"   // mesma escolha do Estúdio
    }

    private var engine: AVAudioEngine?
    private let effectChain = StudioEffectChain()
    private let looperNode: AVAudioUnitEffect
    private var looper: PestanaLooperAU? { looperNode.auAudioUnit as? PestanaLooperAU }
    private var boost: AVAudioUnitEQ?
    private var monitorIn: AVAudioMixerNode?
    private var timer: Timer?
    private var wantsRunning = false
    private var previousIOBuffer: TimeInterval?
    private var cancellables = Set<AnyCancellable>()
    private var engineConfigCancellable: AnyCancellable?

    init() {
        let d = UserDefaults.standard
        let savedCount = d.integer(forKey: Keys.trackCount)
        trackCount = savedCount > 0 ? min(Self.maxTracks, savedCount) : 4
        monitorEnabled = d.object(forKey: Keys.monitor) as? Bool ?? true
        if let data = d.data(forKey: Keys.effects), let saved = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            effects = saved
        } else {
            effects = .preset(.none)
        }
        latencyTrimMS = d.double(forKey: Keys.trim)
        inputGainDB = min(24, max(0, d.float(forKey: Keys.inputGain)))
        let savedVolumes = d.array(forKey: Keys.volumes) as? [Float] ?? []
        volumes = (0..<Self.maxTracks).map { $0 < savedVolumes.count ? savedVolumes[$0] : 1 }
        let a = d.dictionary(forKey: Keys.auto) ?? [:]
        autoEnabled = a["on"] as? Bool ?? false
        bpm = a["bpm"] as? Int ?? 90
        beatsPerBar = a["beats"] as? Int ?? 4
        bars = a["bars"] as? Int ?? 4
        startOnSound = a["onSound"] as? Bool ?? false
        chain = a["chain"] as? Bool ?? false
        gapCycles = a["gap"] as? Int ?? 0
        clickInLoop = a["click"] as? Bool ?? false
        soundSensitivity = a["sens"] as? Int ?? 1

        PestanaLooperAU.registerIfNeeded()
        looperNode = AVAudioUnitEffect(audioComponentDescription: PestanaLooperAU.pestanaComponentDescription())
        if let looper {
            looper.setMonitor(monitorEnabled)
            let mults = d.array(forKey: Keys.multipliers) as? [Int] ?? []
            for t in 0..<Self.maxTracks {
                looper.setVolume(volumes[t], forTrack: t)
                if t < mults.count { looper.setMultiplier(mults[t], forTrack: t) }
            }
        }
        applyAuto()
        observeSession()
        refresh()
    }

    private func saveAuto() {
        let a: [String: Any] = [
            "on": autoEnabled, "bpm": bpm, "beats": beatsPerBar, "bars": bars, "onSound": startOnSound,
            "chain": chain, "gap": gapCycles, "click": clickInLoop, "sens": soundSensitivity,
        ]
        UserDefaults.standard.set(a, forKey: Keys.auto)
        applyAuto()
    }

    private func applyAuto() {
        guard let looper else { return }
        looper.setTempoBPM(Double(bpm), beatsPerBar: beatsPerBar)
        looper.setAutoEnabled(autoEnabled, bars: bars, startOnSound: startOnSound,
                              chain: chain, gapCycles: gapCycles, trackCount: trackCount)
        looper.setClickDuringLoop(clickInLoop, volume: 0.45)
        let levels: [Float] = [0.15, 0.07, 0.03]
        looper.setTriggerLevel(levels[min(2, max(0, soundSensitivity))])
        autoCycleSeconds = looper.autoCycleSeconds
    }

    /// Tempo pelo toque (média dos últimos intervalos).
    func tapTempo() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 5 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        var total: TimeInterval = 0
        for i in 1..<tapTimes.count { total += tapTimes[i].timeIntervalSince(tapTimes[i - 1]) }
        let interval = total / Double(tapTimes.count - 1)
        if interval > 0 { bpm = Int((60 / interval).rounded()) }
    }

    /// Tempo e compassos só mudam sem nada gravado (o ciclo já foi definido).
    var canChangeTempo: Bool { !hasContent }

    // MARK: - Ciclo de vida (aba visível)

    func start() {
        wantsRunning = true
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            startEngine()
        case .denied:
            permissionDenied = true
        default:
            Self.requestPermission { granted in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsRunning else { return }
                    if granted { self.startEngine() } else { self.permissionDenied = true }
                }
            }
        }
    }

    nonisolated private static func requestPermission(_ done: @escaping @Sendable (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
    }

    /// Saindo da aba: fecha gravações, para os loops (o conteúdo continua na memória) e solta o microfone.
    func stop() {
        wantsRunning = false
        looper?.stopAll()
        timer?.invalidate()
        timer = nil
        teardownEngine()
        restoreIOBuffer()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        refresh()
    }

    private func startEngine() {
        guard engine == nil else { return }
        configureSession()
        buildEngine()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func buildEngine() {
        teardownEngine()
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outRate = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: outRate > 0 ? outRate : inFormat.sampleRate,
                                         channels: 2) else {
            lastError = "Nenhuma entrada de áudio disponível."
            running = false
            return
        }

        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].bypass = true
        eq.globalGain = inputGainDB
        let mixer = AVAudioMixerNode()
        newEngine.attach(eq)
        newEngine.attach(mixer)
        newEngine.attach(looperNode)
        newEngine.connect(input, to: eq, format: inFormat)
        newEngine.connect(eq, to: mixer, format: inFormat)
        effectChain.install(in: newEngine, from: mixer, to: looperNode, format: format)
        newEngine.connect(looperNode, to: newEngine.mainMixerNode, format: format)
        effectChain.apply(effects)
        boost = eq
        monitorIn = mixer

        engineConfigCancellable = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: newEngine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleConfigurationChange() }

        engine = newEngine
        newEngine.prepare()
        do {
            try newEngine.start()
            running = true
            lastError = nil
        } catch {
            running = false
            lastError = "Não foi possível ligar o áudio. Feche outros apps de áudio e tente de novo."
        }
        updateRouteInfo()
        updateLatency()
    }

    private func teardownEngine() {
        engineConfigCancellable = nil
        guard let old = engine else { return }
        old.stop()
        for node in effectChain.nodes + [looperNode] where node.engine === old {
            old.detach(node)
        }
        if let boost { old.detach(boost) }
        if let monitorIn { old.detach(monitorIn) }
        boost = nil
        monitorIn = nil
        engine = nil
    }

    private func handleConfigurationChange() {
        guard wantsRunning else { return }
        buildEngine()
    }

    // MARK: - Sessão de áudio

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        if previousIOBuffer == nil { previousIOBuffer = session.preferredIOBufferDuration }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            applyPreferredInput()
        } catch {
            lastError = "Não foi possível configurar o áudio do aparelho."
        }
    }

    private func restoreIOBuffer() {
        guard let previous = previousIOBuffer else { return }
        previousIOBuffer = nil
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(previous > 0 ? previous : 0.023)
    }

    /// Mesma regra do Estúdio: a escolha salva; senão interface USB; senão o microfone do iPhone
    /// (com fone plugado, o iOS trocaria para o microfone do fone).
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let saved = UserDefaults.standard.string(forKey: Keys.preferredInputType)
        let target = inputs.first { $0.portType.rawValue == saved }
            ?? inputs.first { $0.portType == .usbAudio }
            ?? inputs.first { $0.portType == .builtInMic }
        guard let target, session.currentRoute.inputs.first?.uid != target.uid else { return }
        try? session.setPreferredInput(target)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.wantsRunning else { return }
                self.updateRouteInfo()
                self.updateLatency()
            }
            .store(in: &cancellables)
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &cancellables)
    }

    private func handleInterruption(_ note: Notification) {
        guard wantsRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            looper?.stopAll()
        case .ended:
            buildEngine()
        @unknown default:
            break
        }
    }

    private func updateRouteInfo() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let safe: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .lineOut]
        isHeadphoneConnected = route.outputs.contains { safe.contains($0.portType) }
        if let input = route.inputs.first {
            switch input.portType {
            case .builtInMic: inputName = "Microfone do iPhone"
            case .headsetMic: inputName = "Microfone do fone"
            default: inputName = input.portName
            }
        } else {
            inputName = "Sem entrada"
        }
    }

    private func updateLatency() {
        let s = AVAudioSession.sharedInstance()
        let rate = engine?.outputNode.outputFormat(forBus: 0).sampleRate ?? s.sampleRate
        let roundTrip = s.inputLatency + s.outputLatency + 2 * s.ioBufferDuration
        let total = max(0, roundTrip + latencyTrimMS / 1000)
        latencyMS = total * 1000
        looper?.setLatencySamples(Int((total * (rate > 0 ? rate : 48000)).rounded()))
    }

    // MARK: - Ações

    func press(_ track: Int) {
        guard track >= 0, track < trackCount else { return }
        selected = track
        if !running { start() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        attemptPress(track, tries: 12)
    }

    /// Logo depois de fechar uma gravação a faixa ainda escreve a "cauda" (a latência); tenta de novo.
    private func attemptPress(_ track: Int, tries: Int) {
        guard let looper else { return }
        if looper.pressTrack(track) {
            refresh()
            return
        }
        guard tries > 0 else {
            lastError = "Não deu para gravar agora (memória cheia?). Apague uma faixa e tente de novo."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.attemptPress(track, tries: tries - 1)
        }
    }

    func pressSelected() { press(selected) }

    func selectNext() {
        selected = (selected + 1) % max(1, trackCount)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleMute(_ track: Int) {
        looper?.toggleMuteTrack(track)
        refresh()
    }

    func undo(_ track: Int) {
        looper?.undoTrack(track)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refresh()
    }

    func clear(_ track: Int) {
        looper?.clearTrack(track)
        refresh()
    }

    func togglePlayAll() {
        guard let looper else { return }
        if looper.isPlaying { looper.stopAll() } else { looper.playAll() }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        refresh()
    }

    func clearAll() {
        looper?.clearAll()
        refresh()
    }

    func setMultiplier(_ multiplier: Int, for track: Int) {
        looper?.setMultiplier(multiplier, forTrack: track)
        let mults = (0..<Self.maxTracks).map { looper?.multiplier(forTrack: $0) ?? 1 }
        UserDefaults.standard.set(mults, forKey: Keys.multipliers)
        refresh()
    }

    func setVolume(_ volume: Float, for track: Int) {
        guard track >= 0, track < volumes.count else { return }
        volumes[track] = volume
        looper?.setVolume(volume, forTrack: track)
        UserDefaults.standard.set(volumes, forKey: Keys.volumes)
    }

    func addTrack() { trackCount += 1 }

    /// Só tira a última faixa se ela estiver vazia.
    func removeTrack() {
        guard trackCount > 1, tracks[trackCount - 1].state == .empty else { return }
        trackCount -= 1
    }

    // MARK: - Leitura do estado (30 vezes por segundo)

    private func refresh() {
        guard let looper else { return }
        looper.collectGarbage()
        var next = tracks
        for t in 0..<Self.maxTracks {
            next[t] = TrackInfo(
                state: looper.state(forTrack: t),
                muted: looper.isTrackMuted(t),
                canUndo: looper.canUndoTrack(t),
                progress: looper.progress(forTrack: t),
                level: looper.level(forTrack: t),
                length: looper.lengthSeconds(forTrack: t),
                multiplier: looper.multiplier(forTrack: t)
            )
        }
        if next != tracks { tracks = next }
        if playing != looper.isPlaying { playing = looper.isPlaying }
        if hasContent != looper.hasContent { hasContent = looper.hasContent }
        if baseSeconds != looper.baseSeconds { baseSeconds = looper.baseSeconds }
        positionSeconds = looper.positionSeconds
        inputLevel = looper.inputLevel
        if phase != looper.phase { phase = looper.phase }
        if beat != looper.currentBeat { beat = looper.currentBeat }
    }
}
