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

/// Uma faixa (camada) de um projeto.
struct StudioTrack: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Nome do arquivo de áudio dentro da pasta do projeto (ex.: "track-<uuid>.caf").
    var fileName: String
    var volume: Float = 1.0          // 0…1.5
    var pan: Float = 0               // -1 (esq) … 1 (dir)
    var isMuted: Bool = false
    var isSolo: Bool = false
    /// Deslocamento aplicado na reprodução (s). Positivo = atrasa. Usado na compensação de latência.
    var offset: TimeInterval = 0
    var effects: EffectSettings = .preset(.none)
    /// true quando veio de fora (música importada / stem separado), false quando foi gravada no app.
    var isImported: Bool = false
    /// Duração em segundos (preenchida pelo motor ao gravar/importar).
    var duration: TimeInterval = 0
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
 }
*/
