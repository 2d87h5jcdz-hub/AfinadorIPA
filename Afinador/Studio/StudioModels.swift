import Foundation

// MARK: - CONTRATO COMPARTILHADO (não renomear sem combinar com todos os módulos)
//
// Módulos:
//  • Studio/StudioEngine.swift      → motor de áudio (gravação em camadas, efeitos, exportação)
//  • Studio/Studio*View.swift       → telas do Estúdio (consomem só a API pública do StudioEngine)
//  • Practice/*                     → Treino: tocar música importada com tom/velocidade/loop,
//                                     separar instrumentos com IA e mandar a base para o Estúdio
//
// Persistência: Documents/Projects/<project.id>/project.json + um arquivo de áudio por faixa
// (Track.fileName, relativo à pasta do projeto). Documents fica visível no app Arquivos.

/// Um trecho de áudio posicionado na linha do tempo de uma faixa (v2).
/// Uma faixa pode ter vários clips (gravações em partes, regravação de trecho, "continuar de onde parou").
struct StudioClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Arquivo de áudio dentro da pasta do projeto (ex.: "take-<uuid>.caf").
    var fileName: String
    /// Onde o clip começa na linha do tempo (s). Já inclui a compensação de latência da gravação.
    var offset: TimeInterval
    /// Ponto de início dentro do arquivo (s) — permite aparar o começo (regravação de trecho).
    var fileStart: TimeInterval = 0
    /// Duração tocada a partir de fileStart (s).
    var duration: TimeInterval
    var end: TimeInterval { offset + duration }
}

/// Uma faixa (camada) de um projeto.
struct StudioTrack: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// LEGADO (v1, uma gravação por faixa). Projetos antigos são migrados para `clips` ao carregar;
    /// código novo usa só `clips`. Mantido para não quebrar inicializadores existentes.
    var fileName: String = ""
    var volume: Float = 1.0          // 0…1.5
    var pan: Float = 0               // -1 (esq) … 1 (dir)
    var isMuted: Bool = false
    var isSolo: Bool = false
    /// LEGADO (v1): deslocamento do único arquivo. Em v2 cada clip tem seu offset.
    var offset: TimeInterval = 0
    var effects: EffectSettings = .preset(.none)
    /// true quando veio de fora (música importada / stem separado), false quando foi gravada no app.
    var isImported: Bool = false
    /// LEGADO (v1): duração do único arquivo. Em v2 use `end`.
    var duration: TimeInterval = 0
    /// v2: trechos de áudio na linha do tempo, ordenados por offset. Faixa vazia = [].
    var clips: [StudioClip] = []
    /// Afinação automática (correção sutil da voz, feita a partir da gravação; o original não muda).
    var pitch: PitchCorrection = PitchCorrection()
    /// Botão FX da faixa: false = toca sem efeitos e sem afinação (os ajustes ficam guardados).
    var effectsOn: Bool = true

    /// A faixa tem algum efeito ou afinação configurados?
    var hasEffects: Bool { effects != EffectSettings() || pitch.enabled }

    /// Fim do último clip (s); 0 para faixa vazia.
    var end: TimeInterval { clips.map(\.end).max() ?? 0 }
}

extension StudioTrack {
    private enum CodingKeys: String, CodingKey {
        case id, name, fileName, volume, pan, isMuted, isSolo, offset, effects, isImported, duration, clips, pitch, effectsOn
    }

    /// Decodifica v1 e v2: uma faixa antiga (fileName sem clips) vira um clip único.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Faixa"
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try c.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        offset = try c.decodeIfPresent(TimeInterval.self, forKey: .offset) ?? 0
        effects = try c.decodeIfPresent(EffectSettings.self, forKey: .effects) ?? .preset(.none)
        isImported = try c.decodeIfPresent(Bool.self, forKey: .isImported) ?? false
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        clips = try c.decodeIfPresent([StudioClip].self, forKey: .clips) ?? []
        pitch = try c.decodeIfPresent(PitchCorrection.self, forKey: .pitch) ?? PitchCorrection()
        effectsOn = try c.decodeIfPresent(Bool.self, forKey: .effectsOn) ?? true
        if clips.isEmpty && !fileName.isEmpty && duration > 0 {
            // v1 gravava offset negativo (compensação de latência a partir do 0). Em v2 offset >= 0:
            // o começo antes do 0 vira fileStart (o que soa é o mesmo).
            var clip = StudioClip(fileName: fileName, offset: offset, fileStart: 0, duration: duration)
            if clip.offset < 0 {
                let cut = min(-clip.offset, duration)
                clip.offset = 0
                clip.fileStart = cut
                clip.duration = duration - cut
            }
            if clip.duration > 0 { clips = [clip] }
        }
    }
}

/// Um projeto (música) com várias faixas.
struct StudioProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var bpm: Double = 90
    var beatsPerBar: Int = 4
    var tracks: [StudioTrack] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// Presets prontos de efeito.
enum EffectPreset: String, Codable, CaseIterable, Identifiable {
    case none, steelGuitar, nylonGuitar, vocal, electricClean, electricDrive
    // Guitarra (v3): drives com estilos diferentes e modulações.
    case crunch, highGain, fuzz, solo, cleanChorus, flanger80, phaser, tremolo
    case custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Sem efeito"
        case .steelGuitar: return "Violão aço"
        case .nylonGuitar: return "Violão nylon"
        case .vocal: return "Voz"
        case .electricClean: return "Guitarra limpa"
        case .electricDrive: return "Guitarra drive"
        case .crunch: return "Crunch"
        case .highGain: return "Distorção pesada"
        case .fuzz: return "Fuzz"
        case .solo: return "Solo"
        case .cleanChorus: return "Limpa com chorus"
        case .flanger80: return "Flanger anos 80"
        case .phaser: return "Phaser"
        case .tremolo: return "Tremolo"
        case .custom: return "Personalizado"
        }
    }
}

/// Cadeia de efeitos de uma faixa (e do monitoramento ao vivo).
/// Ordem no motor: redução de ruído → noise gate → EQ (3 bandas) → compressor → guitarra (drive + amp NAM + modulação) → delay → reverb.
struct EffectSettings: Codable, Equatable {
    var preset: EffectPreset = .none
    /// Redução de ruído (ar-condicionado, ventilador, rua ao longe). Fora dos presets.
    /// Ao vivo usa o perfil aprendido (`noiseProfile`, FFT 512 na taxa `noiseProfileRate`); nas
    /// faixas do Estúdio a limpeza é feita na gravação (cópia), com esse perfil ou estimando do silêncio.
    var noiseEnabled = false
    var noiseAmount: Float = 0.5         // 0 … 1
    var noiseProfile: [Float]?
    var noiseProfileRate: Double?
    var gateEnabled = false
    var gateThresholdDB: Float = -50     // -80 … -20
    var eqLowDB: Float = 0               // -12 … +12  (100 Hz, shelf)
    var eqMidDB: Float = 0               // -12 … +12  (1 kHz, bell)
    var eqHighDB: Float = 0              // -12 … +12  (8 kHz, shelf)
    var compressorEnabled = false
    var compressorAmount: Float = 0.5    // 0 … 1  (motor mapeia para threshold/ratio)
    var driveAmount: Float = 0           // 0 … 1  (0 = desligado)
    var delayMix: Float = 0              // 0 … 1
    var delayTime: Float = 0.35          // s
    var delayFeedback: Float = 0.3       // 0 … 0.9
    var reverbMix: Float = 0             // 0 … 1
    /// Estilo do drive (saturador do bloco Guitarra, em C++).
    var driveStyle: DriveStyle = .distortion
    /// Bloco Guitarra: amplificador neural (.nam importado, nome do arquivo em Amps/) e ganhos.
    var ampModel: String?
    var ampInputDB: Float = 0            // -12 … +12
    var ampOutputDB: Float = 0           // -12 … +12
    /// Modulação (depois do amp): chorus, flanger, phaser, tremolo.
    var modType: ModulationType = .none
    var modRate: Float = 0.6             // Hz
    var modDepth: Float = 0.5            // 0 … 1
    var modMix: Float = 0.5              // 0 … 1

    static func preset(_ p: EffectPreset) -> EffectSettings {
        var s = EffectSettings()
        s.preset = p
        switch p {
        case .none, .custom: break
        case .steelGuitar:
            s.gateEnabled = true; s.gateThresholdDB = -55
            s.eqLowDB = -2; s.eqMidDB = 1; s.eqHighDB = 3
            s.compressorEnabled = true; s.compressorAmount = 0.4
            s.reverbMix = 0.22
        case .nylonGuitar:
            s.gateEnabled = true; s.gateThresholdDB = -58
            s.eqLowDB = 1; s.eqMidDB = 0; s.eqHighDB = 1.5
            s.compressorEnabled = true; s.compressorAmount = 0.3
            s.reverbMix = 0.25
        case .vocal:
            s.gateEnabled = true; s.gateThresholdDB = -45
            s.eqLowDB = -4; s.eqMidDB = 1.5; s.eqHighDB = 2.5
            s.compressorEnabled = true; s.compressorAmount = 0.6
            s.delayMix = 0.08; s.delayTime = 0.28; s.delayFeedback = 0.2
            s.reverbMix = 0.18
        case .electricClean:
            s.eqLowDB = 0; s.eqMidDB = 2; s.eqHighDB = 2
            s.compressorEnabled = true; s.compressorAmount = 0.5
            s.delayMix = 0.15; s.reverbMix = 0.2
        case .electricDrive:
            s.gateEnabled = true; s.gateThresholdDB = -62
            s.eqLowDB = 2; s.eqMidDB = 3; s.eqHighDB = 1
            s.driveAmount = 0.6; s.reverbMix = 0.15
        case .crunch:
            s.gateEnabled = true; s.gateThresholdDB = -62
            s.eqLowDB = 1; s.eqMidDB = 2; s.eqHighDB = 1.5
            s.driveStyle = .crunch; s.driveAmount = 0.45
            s.reverbMix = 0.15
        case .highGain:
            s.gateEnabled = true; s.gateThresholdDB = -60
            s.eqLowDB = 3; s.eqMidDB = -2; s.eqHighDB = 2
            s.driveStyle = .distortion; s.driveAmount = 0.85
            s.compressorEnabled = true; s.compressorAmount = 0.3
            s.reverbMix = 0.12
        case .fuzz:
            s.gateEnabled = true; s.gateThresholdDB = -60
            s.eqLowDB = 2; s.eqMidDB = 1; s.eqHighDB = -1
            s.driveStyle = .fuzz; s.driveAmount = 0.7
            s.reverbMix = 0.1
        case .solo:
            s.gateEnabled = true; s.gateThresholdDB = -62
            s.eqLowDB = 0; s.eqMidDB = 3; s.eqHighDB = 1.5
            s.compressorEnabled = true; s.compressorAmount = 0.5
            s.driveStyle = .distortion; s.driveAmount = 0.7
            s.delayMix = 0.25; s.delayTime = 0.38; s.delayFeedback = 0.35
            s.reverbMix = 0.25
        case .cleanChorus:
            s.eqLowDB = -1; s.eqMidDB = 0; s.eqHighDB = 2
            s.compressorEnabled = true; s.compressorAmount = 0.4
            s.modType = .chorus; s.modRate = 0.8; s.modDepth = 0.55; s.modMix = 0.5
            s.reverbMix = 0.2
        case .flanger80:
            s.eqLowDB = 0; s.eqMidDB = 1; s.eqHighDB = 2
            s.driveStyle = .crunch; s.driveAmount = 0.3
            s.modType = .flanger; s.modRate = 0.25; s.modDepth = 0.8; s.modMix = 0.6
            s.reverbMix = 0.15
        case .phaser:
            s.eqLowDB = 0; s.eqMidDB = 1; s.eqHighDB = 1
            s.driveStyle = .crunch; s.driveAmount = 0.25
            s.modType = .phaser; s.modRate = 0.5; s.modDepth = 0.7; s.modMix = 0.6
            s.reverbMix = 0.15
        case .tremolo:
            s.eqLowDB = 0; s.eqMidDB = 0; s.eqHighDB = 1.5
            s.modType = .tremolo; s.modRate = 5; s.modDepth = 0.7; s.modMix = 1
            s.reverbMix = 0.25
        }
        return s
    }
}

/// Estilo do drive (curva de saturação no GuitarFXCore; mesma numeração do DriveType em C++).
enum DriveStyle: Int, Codable, CaseIterable, Identifiable {
    case distortion = 0, crunch, funk, fuzz
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .distortion: return "Distorção"
        case .crunch: return "Crunch"
        case .funk: return "Funk"
        case .fuzz: return "Fuzz"
        }
    }
}

/// Modulação do bloco Guitarra (o número vai para o Audio Unit em C++).
enum ModulationType: Int, Codable, CaseIterable, Identifiable {
    case none = 0, chorus, flanger, phaser, tremolo
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "Nenhuma"
        case .chorus: return "Chorus"
        case .flanger: return "Flanger"
        case .phaser: return "Phaser"
        case .tremolo: return "Tremolo"
        }
    }
}

extension EffectSettings {
    private enum CodingKeys: String, CodingKey {
        case preset, gateEnabled, gateThresholdDB, eqLowDB, eqMidDB, eqHighDB
        case compressorEnabled, compressorAmount, driveAmount, delayMix, delayTime, delayFeedback, reverbMix
        case driveStyle, ampModel, ampInputDB, ampOutputDB, modType, modRate, modDepth, modMix
        case noiseEnabled, noiseAmount, noiseProfile, noiseProfileRate
    }

    /// Limiar do gate dos presets com drive até a v1.2.
    private static let oldDriveGate: [EffectPreset: Float] = [
        .electricDrive: -48, .crunch: -52, .highGain: -45, .fuzz: -48, .solo: -48
    ]

    /// Lê projetos antigos: campos que não existiam ficam no padrão.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? c.decodeIfPresent(EffectPreset.self, forKey: .preset)) ?? .custom
        gateEnabled = try c.decodeIfPresent(Bool.self, forKey: .gateEnabled) ?? gateEnabled
        gateThresholdDB = try c.decodeIfPresent(Float.self, forKey: .gateThresholdDB) ?? gateThresholdDB
        eqLowDB = try c.decodeIfPresent(Float.self, forKey: .eqLowDB) ?? eqLowDB
        eqMidDB = try c.decodeIfPresent(Float.self, forKey: .eqMidDB) ?? eqMidDB
        eqHighDB = try c.decodeIfPresent(Float.self, forKey: .eqHighDB) ?? eqHighDB
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? compressorEnabled
        compressorAmount = try c.decodeIfPresent(Float.self, forKey: .compressorAmount) ?? compressorAmount
        driveAmount = try c.decodeIfPresent(Float.self, forKey: .driveAmount) ?? driveAmount
        delayMix = try c.decodeIfPresent(Float.self, forKey: .delayMix) ?? delayMix
        delayTime = try c.decodeIfPresent(Float.self, forKey: .delayTime) ?? delayTime
        delayFeedback = try c.decodeIfPresent(Float.self, forKey: .delayFeedback) ?? delayFeedback
        reverbMix = try c.decodeIfPresent(Float.self, forKey: .reverbMix) ?? reverbMix
        driveStyle = (try? c.decodeIfPresent(DriveStyle.self, forKey: .driveStyle)) ?? driveStyle
        // v1.3: os presets com drive tinham o gate alto demais (cortava a cauda da nota).
        // Se o valor salvo ainda é o antigo do preset, passa para o novo.
        if let old = Self.oldDriveGate[preset], abs(gateThresholdDB - old) < 0.01 {
            gateThresholdDB = Self.preset(preset).gateThresholdDB
        }
        ampModel = try c.decodeIfPresent(String.self, forKey: .ampModel)
        ampInputDB = try c.decodeIfPresent(Float.self, forKey: .ampInputDB) ?? ampInputDB
        ampOutputDB = try c.decodeIfPresent(Float.self, forKey: .ampOutputDB) ?? ampOutputDB
        modType = (try? c.decodeIfPresent(ModulationType.self, forKey: .modType)) ?? modType
        modRate = try c.decodeIfPresent(Float.self, forKey: .modRate) ?? modRate
        modDepth = try c.decodeIfPresent(Float.self, forKey: .modDepth) ?? modDepth
        modMix = try c.decodeIfPresent(Float.self, forKey: .modMix) ?? modMix
        noiseEnabled = try c.decodeIfPresent(Bool.self, forKey: .noiseEnabled) ?? noiseEnabled
        noiseAmount = try c.decodeIfPresent(Float.self, forKey: .noiseAmount) ?? noiseAmount
        noiseProfile = try? c.decodeIfPresent([Float].self, forKey: .noiseProfile)
        noiseProfileRate = try? c.decodeIfPresent(Double.self, forKey: .noiseProfileRate)
    }

    /// Mantém os ajustes de ruído ao trocar de preset (o ruído é do ambiente, não do timbre).
    mutating func keepNoise(from other: EffectSettings) {
        noiseEnabled = other.noiseEnabled
        noiseAmount = other.noiseAmount
        noiseProfile = other.noiseProfile
        noiseProfileRate = other.noiseProfileRate
    }

    /// Intensidade da limpeza na gravação (nil = desligada).
    var noiseCleanupLevel: Float? {
        guard noiseEnabled, noiseAmount > 0.001 else { return nil }
        return noiseAmount
    }
}

/// Estado do transporte do Estúdio.
enum TransportState: Equatable {
    case stopped
    case playing
    case countIn(beat: Int)     // contagem antes de gravar (1…beatsPerBar)
    case recording
}

/// Formato de exportação da mixagem.
enum ExportFormat: String, CaseIterable, Identifiable {
    case m4a, wav
    var id: String { rawValue }
}

/*
 MARK: - API PÚBLICA DO StudioEngine (implementada em Studio/StudioEngine.swift)

 @MainActor final class StudioEngine: ObservableObject {
     // Estado publicado
     @Published private(set) var projects: [StudioProject]          // todos, mais recente primeiro
     @Published var project: StudioProject?                          // projeto aberto (edições salvam sozinhas)
     @Published private(set) var transport: TransportState
     @Published private(set) var position: TimeInterval              // cabeça de reprodução (s)
     @Published private(set) var inputLevel: Float                   // 0…1, nível do microfone/interface (medidor)
     @Published private(set) var trackLevels: [UUID: Float]          // 0…1 por faixa durante a reprodução
     @Published var clickEnabled: Bool                               // clique do metrônomo ao tocar/gravar
     @Published var countInBars: Int                                 // 0, 1 ou 2 compassos de contagem
     @Published var monitorEnabled: Bool                             // ouvir a entrada com efeitos ao vivo (use fone!)
     @Published var monitorEffects: EffectSettings                   // efeitos do monitoramento e da próxima gravação
     @Published private(set) var inputName: String                   // "Microfone do iPhone", "iRig HD", ...
     @Published private(set) var isHeadphoneConnected: Bool
     @Published private(set) var lastError: String?
     var duration: TimeInterval { get }                              // maior faixa do projeto

     // Projetos
     func newProject(name: String) -> StudioProject                 // cria, salva e abre
     func open(_ id: UUID)
     func rename(_ id: UUID, to name: String)
     func deleteProject(_ id: UUID)
     func closeProject()

     // Transporte
     func play(from: TimeInterval? = nil)
     func stop()
     func record()            // contagem (se countInBars > 0) e grava nova faixa tocando as demais
     func seek(to: TimeInterval)

     // Faixas
     func updateTrack(_ track: StudioTrack)                          // volume/pan/mute/solo/efeitos/nome
     func deleteTrack(_ id: UUID)
     func importAudio(from url: URL, name: String) async throws -> StudioTrack   // copia p/ projeto (security-scoped ok)

     // Exportação
     func exportMix(format: ExportFormat) async throws -> URL        // arquivo temporário pronto p/ compartilhar

     // Ciclo de vida
     func activate()     // ao entrar na aba: prepara sessão de áudio/engine
     func deactivate()   // ao sair: para tudo e libera o microfone

     // ── v2: LINHA DO TEMPO / CLIPS (já existentes: availableInputs, selectedInputID, selectInput(_:),
     //        inputGainDB, isExporting, latencyCompensation, fileURL(for:), clearError()) ──

     /// Faixa que recebe a próxima gravação ("armada"). nil = record() cria uma faixa nova (comportamento v1).
     @Published var armedTrackID: UUID?
     /// Começo da gravação em andamento na linha do tempo (s), para a UI desenhar o clip "ao vivo"
     /// na faixa armada (nil fora da gravação). O fim é `position`.
     @Published private(set) var recordingStart: TimeInterval?

     /// Cria uma faixa vazia ("Faixa N" se name == nil), salva, e já a deixa armada.
     @discardableResult func addEmptyTrack(name: String?) -> StudioTrack
     /// Arma (ou desarma com nil) a faixa da próxima gravação. Só com o transporte parado.
     func arm(_ trackID: UUID?)
     /// record() v2: grava a partir da posição atual na faixa armada (ou numa faixa nova se nada
     /// estiver armado). O trecho novo SUBSTITUI o que houver por baixo naquela faixa (punch-in):
     /// clips sobrepostos são aparados/divididos (ajustando fileStart/duration/offset), nunca o arquivo.
     /// Ao parar, o clip novo entra em track.clips (ordenado por offset) e a faixa continua armada.

     /// Leva a cabeça de reprodução ao fim da faixa ("continuar de onde parou").
     func seekToEnd(of trackID: UUID)
     /// Move um clip na linha do tempo (offset >= 0). Só parado.
     func moveClip(_ clipID: UUID, in trackID: UUID, to offset: TimeInterval)
     /// Remove um clip da faixa (apaga o arquivo se nenhum outro clip o usa). Só parado.
     func deleteClip(_ clipID: UUID, in trackID: UUID)
     /// Forma de onda do trecho tocado do clip: `buckets` picos 0…1 (cache em disco por arquivo).
     func waveform(for clip: StudioClip, buckets: Int) async -> [Float]

     // Compatibilidade: importAudio cria faixa com 1 clip; StudioProject.duration/`duration` = maior track.end;
     // reprodução, exportação e níveis consideram todos os clips de cada faixa.
 }
*/
