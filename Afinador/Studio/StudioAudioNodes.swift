import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

// Blocos de áudio do Estúdio. Nada aqui é @MainActor: estas classes são usadas tanto pelo
// motor ao vivo (StudioEngine, na main thread) quanto pelo renderizador offline (thread de fundo).
// Os closures que rodam na thread de áudio (render do clique, taps) são criados aqui, fora de
// qualquer ator, para não herdarem isolamento do MainActor.

// MARK: - Audio Units da Apple

enum StudioAudioUnits {
    /// IDs de parâmetro do AUDynamicsProcessor (AudioUnitParameters.h).
    /// Usamos os valores literais para não depender de nomes que mudaram entre SDKs
    /// (kDynamicsProcessorParam_MasterGain → _OverallGain).
    enum Dynamics {
        static let threshold: AudioUnitParameterID = 0           // -40 … 20 dB
        static let headRoom: AudioUnitParameterID = 1            // 0.1 … 40 dB
        static let expansionRatio: AudioUnitParameterID = 2      // 1 … 50
        static let expansionThreshold: AudioUnitParameterID = 3  // dB
        static let attackTime: AudioUnitParameterID = 4          // 0.0001 … 0.2 s
        static let releaseTime: AudioUnitParameterID = 5         // 0.01 … 3 s
        static let overallGain: AudioUnitParameterID = 6         // -40 … 40 dB
    }

    static var dynamicsDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    static var peakLimiterDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_PeakLimiter,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    /// Limitador no barramento master: evita clipping quando várias faixas somam (ao vivo e na exportação).
    static func makeLimiter() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: peakLimiterDescription)
    }

    static func set(_ unit: AVAudioUnit, _ parameter: AudioUnitParameterID, _ value: Float) {
        _ = AudioUnitSetParameter(unit.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }
}

// MARK: - Cadeia de efeitos: gate → EQ → compressor → drive → guitarra (amp + modulação) → delay → reverb

final class StudioEffectChain {
    let gate: AVAudioUnitEffect
    let eq: AVAudioUnitEQ
    let compressor: AVAudioUnitEffect
    let drive: AVAudioUnitDistortion
    /// Bloco próprio (C++): amplificador neural NAM + chorus/flanger/phaser/tremolo.
    let guitar: AVAudioUnitEffect
    let delay: AVAudioUnitDelay
    let reverb: AVAudioUnitReverb

    init() {
        gate = AVAudioUnitEffect(audioComponentDescription: StudioAudioUnits.dynamicsDescription)
        eq = AVAudioUnitEQ(numberOfBands: 3)
        compressor = AVAudioUnitEffect(audioComponentDescription: StudioAudioUnits.dynamicsDescription)
        drive = AVAudioUnitDistortion()
        PestanaGuitarAU.registerIfNeeded()
        guitar = AVAudioUnitEffect(audioComponentDescription: PestanaGuitarAU.pestanaComponentDescription())
        guitar.bypass = true
        delay = AVAudioUnitDelay()
        reverb = AVAudioUnitReverb()

        // Presets carregados uma vez; depois só ajustamos mix/ganho (loadFactoryPreset zera os ajustes).
        drive.loadFactoryPreset(.multiDistortedCubed)
        reverb.loadFactoryPreset(.mediumRoom)

        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = 100
        low.gain = 0
        low.bypass = false

        let mid = eq.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1000
        mid.bandwidth = 1.0     // oitavas
        mid.gain = 0
        mid.bypass = false

        let high = eq.bands[2]
        high.filterType = .highShelf
        high.frequency = 8000
        high.gain = 0
        high.bypass = false
    }

    var nodes: [AVAudioNode] { [gate, eq, compressor, drive, guitar, delay, reverb] }

    private var guitarUnit: PestanaGuitarAU? { guitar.auAudioUnit as? PestanaGuitarAU }
    /// Modelo .nam carregado agora (para não reler o arquivo a cada ajuste).
    private var loadedAmp: String?
    private var driveStyle: DriveStyle = .distortion

    /// Anexa e conecta source → efeitos → destination, todos no mesmo formato.
    func install(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode,
                 format: AVAudioFormat) {
        let chain = nodes
        for node in chain { engine.attach(node) }
        var previous: AVAudioNode = source
        for node in chain {
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: destination, format: format)
    }

    /// Aplica as configurações ao vivo. `extraGainDB` (>0 quando volume > 1) vai no ganho global do EQ.
    func apply(_ s: EffectSettings, extraGainDB: Float = 0) {
        applyGate(s)
        applyEQ(s, extraGainDB: extraGainDB)
        applyCompressor(s)
        applyDrive(s)
        applyGuitar(s)
        applyDelay(s)
        reverb.wetDryMix = Self.clamp(s.reverbMix, 0, 1) * 100
        reverb.bypass = s.reverbMix <= 0.001
    }

    private func applyGate(_ s: EffectSettings) {
        // Gate = expansor forte abaixo do limiar; compressão desligada (threshold no máximo).
        let threshold = Self.clamp(s.gateThresholdDB, -80, -20)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.threshold, 20)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.headRoom, 5)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.expansionThreshold, threshold)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.expansionRatio, 12)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.attackTime, 0.001)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.releaseTime, 0.12)
        StudioAudioUnits.set(gate, StudioAudioUnits.Dynamics.overallGain, 0)
        gate.bypass = !s.gateEnabled
    }

    private func applyEQ(_ s: EffectSettings, extraGainDB: Float) {
        let lowGain = Self.clamp(s.eqLowDB, -12, 12)
        let midGain = Self.clamp(s.eqMidDB, -12, 12)
        let highGain = Self.clamp(s.eqHighDB, -12, 12)
        let global = Self.clamp(extraGainDB, -24, 12)
        eq.bands[0].gain = lowGain
        eq.bands[1].gain = midGain
        eq.bands[2].gain = highGain
        eq.globalGain = global
        let flat = abs(lowGain) < 0.05 && abs(midGain) < 0.05 && abs(highGain) < 0.05 && abs(global) < 0.05
        eq.bypass = flat
    }

    private func applyCompressor(_ s: EffectSettings) {
        // amount 0…1 → threshold -10…-35 dB, headroom 6…1.5 dB (mais agressivo), ganho de compensação 2…10 dB.
        let a = Self.clamp(s.compressorAmount, 0, 1)
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.threshold, -10 - 25 * a)
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.headRoom, max(1.5, 6 - 4.5 * a))
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.expansionRatio, 1)
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.attackTime, 0.004)
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.releaseTime, 0.15)
        StudioAudioUnits.set(compressor, StudioAudioUnits.Dynamics.overallGain, 2 + 8 * a)
        compressor.bypass = !s.compressorEnabled
    }

    private func applyGuitar(_ s: EffectSettings) {
        guard let unit = guitarUnit else {
            guitar.bypass = true
            return
        }
        if s.ampModel != loadedAmp {
            loadedAmp = s.ampModel
            if let name = s.ampModel, let url = StudioAmps.url(for: name) {
                var error: NSString?
                if !unit.loadAmpModel(atPath: url.path, error: &error) { unit.clearAmpModel() }
            } else {
                unit.clearAmpModel()
            }
        }
        unit.setAmpInputDB(Self.clamp(s.ampInputDB, -12, 12), outputDB: Self.clamp(s.ampOutputDB, -12, 12))
        unit.setModulationType(s.modType.rawValue, rate: s.modRate, depth: s.modDepth, mix: s.modMix)
        guitar.bypass = !(unit.hasAmpModel || s.modType != .none)
    }

    private func applyDrive(_ s: EffectSettings) {
        if s.driveStyle != driveStyle {
            driveStyle = s.driveStyle
            switch s.driveStyle {
            case .distortion: drive.loadFactoryPreset(.multiDistortedCubed)
            case .crunch: drive.loadFactoryPreset(.multiDistortedSquared)
            case .funk: drive.loadFactoryPreset(.multiDistortedFunk)
            case .fuzz: drive.loadFactoryPreset(.multiDecimated2)
            }
        }
        let d = Self.clamp(s.driveAmount, 0, 1)
        drive.preGain = -12 + 24 * d          // -80 … 20 dB
        drive.wetDryMix = 15 + 70 * d         // %
        drive.bypass = d <= 0.001
    }

    private func applyDelay(_ s: EffectSettings) {
        delay.delayTime = TimeInterval(Self.clamp(s.delayTime, 0.01, 2))
        delay.feedback = Self.clamp(s.delayFeedback, 0, 0.9) * 100
        delay.lowPassCutoff = 6000
        delay.wetDryMix = Self.clamp(s.delayMix, 0, 1) * 100
        delay.bypass = s.delayMix <= 0.001
    }

    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, v)) }
}

// MARK: - Uma faixa: players (clips) → conversor → efeitos → mixer da faixa (volume/pan) → master
//
// v2: uma faixa tem vários clips. Os clips são distribuídos em "pistas" (lanes): cada pista é um
// AVAudioPlayerNode que toca clips que NÃO se sobrepõem e cujos arquivos têm o MESMO formato de
// processamento (o player é conectado com esse formato). Normalmente uma faixa = uma pista; clips
// sobrepostos (moveClip) ou de formatos diferentes (punch-in gravado numa faixa importada) ganham
// pistas extras. Todas as pistas entram no mixer `converter` (cada uma num barramento de entrada),
// que converte para o formato estéreo da cadeia.

final class StudioClipLane {
    struct Item {
        let clip: StudioClip
        let file: AVAudioFile
    }

    let player = AVAudioPlayerNode()
    let format: AVAudioFormat
    private(set) var items: [Item] = []
    /// Arquivos abertos por esta pista (um AVAudioFile por nome; não compartilhados entre players).
    private var files: [String: AVAudioFile] = [:]
    /// true se algo foi agendado na última chamada de schedule.
    var hasScheduled = false

    init(format: AVAudioFormat) {
        self.format = format
    }

    var end: TimeInterval { items.last.map { $0.clip.end } ?? -Double.infinity }

    /// Arquivo desta pista para `fileName` (abre uma vez; nil se não existir/ilegível).
    func file(named fileName: String, folder: URL) -> AVAudioFile? {
        if let f = files[fileName] { return f }
        guard let f = try? AVAudioFile(forReading: folder.appendingPathComponent(fileName)),
              f.length > 0 else { return nil }
        files[fileName] = f
        return f
    }

    func adopt(_ file: AVAudioFile, named fileName: String) {
        if files[fileName] == nil { files[fileName] = file }
    }

    func append(_ clip: StudioClip, file: AVAudioFile) {
        items.append(Item(clip: clip, file: file))
    }
}

final class StudioTrackChain {
    let trackID: UUID
    private(set) var lanes: [StudioClipLane] = []
    /// Mixer que recebe todas as pistas e converte para o formato estéreo da cadeia.
    let converter = AVAudioMixerNode()
    let effects = StudioEffectChain()
    /// Volume e pan da faixa (pan é aplicado na entrada do mixer de destino).
    let output = AVAudioMixerNode()
    /// Clips cujo arquivo não pôde ser aberto.
    private(set) var missingClips = 0

    /// Abre os arquivos dos clips (em `folder`) e distribui os clips em pistas.
    init(trackID: UUID, clips: [StudioClip], folder: URL) {
        self.trackID = trackID
        let sorted = clips.filter { $0.duration > 0 }.sorted { $0.offset < $1.offset }
        for clip in sorted {
            // Pista compatível já existente: mesmo formato e sem sobreposição.
            var placed = false
            for lane in lanes where lane.end <= clip.offset + 0.000_5 {
                guard let file = lane.file(named: clip.fileName, folder: folder) else { break }
                if file.processingFormat == lane.format {
                    lane.append(clip, file: file)
                    placed = true
                    break
                }
            }
            if placed { continue }
            guard let file = try? AVAudioFile(forReading: folder.appendingPathComponent(clip.fileName)),
                  file.length > 0, file.processingFormat.sampleRate > 0 else {
                missingClips += 1
                continue
            }
            let lane = StudioClipLane(format: file.processingFormat)
            lane.adopt(file, named: clip.fileName)
            lane.append(clip, file: file)
            lanes.append(lane)
        }
    }

    /// true se há algo para tocar.
    var isPlayable: Bool { !lanes.isEmpty }

    /// Fim do último clip tocável (s).
    var end: TimeInterval { lanes.map { $0.end }.max() ?? 0 }

    func install(in engine: AVAudioEngine, destination: AVAudioNode, format: AVAudioFormat) {
        engine.attach(converter)
        engine.attach(output)
        for lane in lanes {
            engine.attach(lane.player)
            engine.connect(lane.player, to: converter, fromBus: 0,
                           toBus: converter.nextAvailableInputBus, format: lane.format)
        }
        effects.install(in: engine, from: converter, to: output, format: format)
        engine.connect(output, to: destination, format: format)
    }

    func apply(_ track: StudioTrack, anySolo: Bool) {
        let audible = StudioMix.isAudible(track, anySolo: anySolo)
        let volume = max(0, min(1.5, track.volume))
        output.outputVolume = audible ? min(1, volume) : 0
        output.pan = max(-1, min(1, track.pan))
        // Volume acima de 1 (até 1.5 ≈ +3.5 dB) vira ganho global do EQ.
        let boost: Float = volume > 1 ? 20 * log10(volume) : 0
        // FX desligado: cadeia neutra (os ajustes da faixa continuam guardados).
        effects.apply(track.effectsOn ? track.effects : EffectSettings(), extraGainDB: boost)
    }

    /// Agenda todos os clips a partir da posição `songPosition` da música.
    /// `leadIn` = segundos entre o início dos players e a posição `songPosition` (contagem).
    /// Clips que começam depois da posição esperam (silêncio); um clip que já começou toca do meio.
    /// Retorna false se nada foi agendado (faixa já terminou nessa posição).
    func schedule(songPosition: TimeInterval, leadIn: TimeInterval) -> Bool {
        stop()
        var any = false
        for lane in lanes {
            lane.hasScheduled = false
            let sr = lane.format.sampleRate
            guard sr > 0 else { continue }
            for item in lane.items {
                let clip = item.clip
                guard clip.duration > 0, clip.end > songPosition else { continue }
                var delay = max(0, leadIn)
                var fileTime = max(0, clip.fileStart)
                var length = clip.duration
                if clip.offset >= songPosition {
                    delay += clip.offset - songPosition
                } else {
                    let into = songPosition - clip.offset
                    fileTime += into
                    length -= into
                }
                guard length > 0 else { continue }
                let total = item.file.length
                let startFrame = AVAudioFramePosition((fileTime * sr).rounded())
                guard startFrame >= 0, startFrame < total else { continue }
                let wanted = AVAudioFramePosition((length * sr).rounded())
                let count = min(wanted, total - startFrame)
                guard count > 0, count <= AVAudioFramePosition(UInt32.max) else { continue }
                // Tempo no relógio do próprio player (amostra 0 = instante do play).
                let when = AVAudioTime(sampleTime: AVAudioFramePosition((delay * sr).rounded()), atRate: sr)
                lane.player.scheduleSegment(item.file, startingFrame: startFrame,
                                            frameCount: AVAudioFrameCount(count), at: when,
                                            completionHandler: nil)
                lane.hasScheduled = true
            }
            if lane.hasScheduled { any = true }
        }
        return any
    }

    /// Inicia as pistas que têm algo agendado (nil = imediatamente / início do render offline).
    func play(at when: AVAudioTime?) {
        for lane in lanes where lane.hasScheduled {
            lane.player.play(at: when)
        }
    }

    func stop() {
        for lane in lanes {
            lane.player.stop()
            lane.hasScheduled = false
        }
    }
}

// MARK: - Clique do metrônomo sincronizado à grade da música

final class StudioClickGenerator: @unchecked Sendable {
    let sampleRate: Double
    let format: AVAudioFormat

    // Estado compartilhado com a thread de áudio (protegido pelo lock, como no Metronome).
    private let lock = NSLock()
    private var running = false
    private var startHost: UInt64 = 0
    private var songTimeAtStart: Double = 0
    private var countInEnd: Double = -Double.infinity
    private var beatDuration: Double = 60.0 / 90.0
    private var beatsPerBar = 4
    private var clickOn = true
    private var lastBeat = Int.min
    private var framesSinceStart: Int64 = 0
    private var clickPos = Int.max
    private var clickFreq: Double = 1100
    private var clickAmp: Double = 0.55

    init?(sampleRate: Double) {
        guard sampleRate > 0,
              let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        self.sampleRate = sampleRate
        self.format = f
    }

    func makeNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            self.render(timestamp: timestamp, frameCount: frameCount, bufferList: bufferList)
        }
    }

    /// Começa a gerar cliques. `songTimeAtStart` = tempo da música (s) no instante `startHost`
    /// (negativo/antes da posição durante a contagem). Cliques antes de `countInEnd` tocam sempre.
    func start(startHost: UInt64, songTimeAtStart: Double, countInEnd: Double,
               bpm: Double, beatsPerBar: Int, clickOn: Bool) {
        lock.lock()
        self.startHost = startHost
        self.songTimeAtStart = songTimeAtStart
        self.countInEnd = countInEnd
        self.beatDuration = 60.0 / max(20, bpm)
        self.beatsPerBar = max(1, beatsPerBar)
        self.clickOn = clickOn
        self.lastBeat = Int.min
        self.framesSinceStart = 0
        self.running = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func setClickOn(_ on: Bool) {
        lock.lock()
        clickOn = on
        lock.unlock()
    }

    func setTempo(bpm: Double, beatsPerBar: Int) {
        lock.lock()
        beatDuration = 60.0 / max(20, bpm)
        self.beatsPerBar = max(1, beatsPerBar)
        lock.unlock()
    }

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: AVAudioFrameCount,
                        bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let n = Int(frameCount)
        let sr = sampleRate
        let clickLength = Int(sr * 0.035)

        lock.lock()
        let active = running
        var t0: Double = 0
        if active {
            let ts = timestamp.pointee
            if ts.mFlags.contains(.hostTimeValid) {
                t0 = songTimeAtStart + StudioHostClock.seconds(from: startHost, to: ts.mHostTime)
            } else {
                t0 = songTimeAtStart + Double(framesSinceStart) / sr
            }
            framesSinceStart += Int64(n)
        }

        for frame in 0..<n {
            if active {
                let t = t0 + Double(frame) / sr
                if t >= songTimeAtStart {
                    let beat = Int((t / beatDuration).rounded(.down))
                    if beat != lastBeat {
                        lastBeat = beat
                        let into = t - Double(beat) * beatDuration
                        // Só dispara se estamos no começo do tempo (evita clique "atrasado" ao iniciar no meio).
                        if into < 0.02 && (clickOn || t < countInEnd) {
                            let bpb = beatsPerBar
                            let inBar = ((beat % bpb) + bpb) % bpb
                            let accent = inBar == 0
                            clickFreq = accent ? 2000 : 1100
                            clickAmp = accent ? 0.9 : 0.55
                            clickPos = 0
                        }
                    }
                }
            }

            var value: Float = 0
            if clickPos < clickLength {
                let t = Double(clickPos) / sr
                let env = exp(-t * 140.0)
                value = Float(sin(2 * Double.pi * clickFreq * t) * env * clickAmp * 0.7)
                clickPos += 1
            }
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[frame] = value
            }
        }
        lock.unlock()
        return noErr
    }
}

// MARK: - Gravação da tomada (escrita do áudio SECO da entrada, a partir de um tap)

final class StudioTakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var startHost: UInt64 = 0
    private var started = false
    private var frames: AVAudioFramePosition = 0
    private var failure: String?

    /// Arma a gravação: amostras capturadas antes de `startHost` são descartadas.
    func arm(file: AVAudioFile, startHost: UInt64) {
        lock.lock()
        self.file = file
        self.startHost = startHost
        started = false
        frames = 0
        failure = nil
        lock.unlock()
    }

    /// Para de gravar e fecha o arquivo (o AVAudioFile é liberado aqui, o que finaliza o cabeçalho).
    func finish() -> (frames: AVAudioFramePosition, failure: String?) {
        lock.lock()
        file = nil
        let result = (frames, failure)
        started = false
        frames = 0
        failure = nil
        lock.unlock()
        return result
    }

    /// Chamado pelo tap da entrada (thread de áudio não real-time).
    func process(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let target = file, failure == nil else { return }
        let format = buffer.format
        let total = AVAudioFramePosition(buffer.frameLength)
        guard total > 0 else { return }
        let fileFormat = target.processingFormat
        guard format.channelCount == fileFormat.channelCount, format.sampleRate == fileFormat.sampleRate else {
            failure = "o formato da entrada mudou durante a gravação"
            return
        }

        var skip: AVAudioFramePosition = 0
        if !started {
            let sr = format.sampleRate
            let bufferSeconds = Double(total) / sr
            let bufferHost: UInt64 = when.isHostTimeValid
                ? when.hostTime
                : StudioHostClock.now() &- StudioHostClock.ticks(forSeconds: bufferSeconds)
            let delta = StudioHostClock.seconds(from: bufferHost, to: startHost)
            if delta >= bufferSeconds { return }          // buffer inteiro antes do início
            if delta > 0 { skip = min(total - 1, AVAudioFramePosition(delta * sr)) }
            started = true
        }

        do {
            if skip > 0, let sub = Self.slice(buffer, from: skip) {
                try target.write(from: sub)
                frames += total - skip
            } else {
                try target.write(from: buffer)
                frames += total
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(buffer.frameLength)
        guard start > 0, start < total, !buffer.format.isInterleaved,
              let src = buffer.floatChannelData else { return nil }
        let count = AVAudioFrameCount(total - start)
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let dst = out.floatChannelData else { return nil }
        let bytes = Int(count) * MemoryLayout<Float>.size
        for ch in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch].advanced(by: Int(start)), bytes)
        }
        out.frameLength = count
        return out
    }
}

// MARK: - Medidores (taps escrevem; o timer da main thread lê e publica)

final class StudioLevelMeters: @unchecked Sendable {
    private let lock = NSLock()
    private var input: Float = 0
    private var tracks: [UUID: Float] = [:]

    func reportInput(_ level: Float) {
        lock.lock()
        input = max(input, level)
        lock.unlock()
    }

    func reportTrack(_ id: UUID, _ level: Float) {
        lock.lock()
        tracks[id] = max(tracks[id] ?? 0, level)
        lock.unlock()
    }

    /// Picos desde a última leitura (zera depois de ler).
    func take() -> (input: Float, tracks: [UUID: Float]) {
        lock.lock()
        let result = (input, tracks)
        input = 0
        tracks = [:]
        lock.unlock()
        return result
    }

    /// Pico do buffer mapeado de -60…0 dBFS para 0…1.
    static func normalizedPeak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if buffer.format.isInterleaved {
            vDSP_maxmgv(data[0], 1, &peak, vDSP_Length(frames * channels))
        } else {
            for c in 0..<channels {
                var m: Float = 0
                vDSP_maxmgv(data[c], 1, &m, vDSP_Length(frames))
                peak = max(peak, m)
            }
        }
        guard peak > 0.000_001 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 60) / 60))
    }
}

// MARK: - Fábricas dos blocos de tap (criados fora do MainActor de propósito)

enum StudioTaps {
    static func inputTap(meters: StudioLevelMeters, recorder: StudioTakeRecorder,
                         gain: StudioInputGain) -> AVAudioNodeTapBlock {
        return { buffer, when in
            gain.apply(to: buffer)
            meters.reportInput(StudioLevelMeters.normalizedPeak(of: buffer))
            recorder.process(buffer, when: when)
        }
    }

    static func trackTap(id: UUID, meters: StudioLevelMeters) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            meters.reportTrack(id, StudioLevelMeters.normalizedPeak(of: buffer))
        }
    }
}

/// Ganho digital da entrada, lido na thread de áudio (tap). 0 dB = sem alteração.
final class StudioInputGain: @unchecked Sendable {
    private let lock = NSLock()
    private var linear: Float = 1

    func setDecibels(_ db: Float) {
        lock.lock()
        linear = powf(10, db / 20)
        lock.unlock()
    }

    /// Multiplica as amostras no lugar, limitando a ±1 para não estourar o arquivo gravado.
    func apply(to buffer: AVAudioPCMBuffer) {
        lock.lock()
        let g = linear
        lock.unlock()
        guard g != 1, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        for c in 0..<count {
            let samples = channels[c]
            for i in 0..<frames {
                samples[i] = min(1, max(-1, samples[i] * g))
            }
        }
    }
}

/// Uma entrada de áudio que o usuário pode escolher no Estúdio.
struct StudioInputOption: Identifiable, Equatable {
    let id: String        // uid da porta
    let name: String      // "Microfone do iPhone", "Microfone do fone", "iRig HD"…
    let portType: String  // AVAudioSession.Port.rawValue
}
