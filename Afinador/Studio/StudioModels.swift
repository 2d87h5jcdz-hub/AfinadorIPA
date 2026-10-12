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

    /// Fim do último clip (s); 0 para faixa vazia.
    var end: TimeInterval { clips.map(\.end).max() ?? 0 }
}

extension StudioTrack {
    private enum CodingKeys: String, CodingKey {
        case id, name, fileName, volume, pan, isMuted, isSolo, offset, effects, isImported, duration, clips
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
        if clips.isEmpty && !fileName.isEmpty && duration > 0 {
            clips = [StudioClip(fileName: fileName, offset: offset, fileStart: 0, duration: duration)]
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
    case none, steelGuitar, nylonGuitar, vocal, electricClean, electricDrive, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Sem efeito"
        case .steelGuitar: return "Violão aço"
        case .nylonGuitar: return "Violão nylon"
        case .vocal: return "Voz"
        case .electricClean: return "Guitarra limpa"
        case .electricDrive: return "Guitarra drive"
        case .custom: return "Personalizado"
        }
    }
}

/// Cadeia de efeitos de uma faixa (e do monitoramento ao vivo).
/// Ordem no motor: noise gate → EQ (3 bandas) → compressor → distorção → delay → reverb.
struct EffectSettings: Codable, Equatable {
    var preset: EffectPreset = .none
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
            s.gateEnabled = true; s.gateThresholdDB = -48
            s.eqLowDB = 2; s.eqMidDB = 3; s.eqHighDB = 1
            s.driveAmount = 0.6; s.reverbMix = 0.15
        }
        return s
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
