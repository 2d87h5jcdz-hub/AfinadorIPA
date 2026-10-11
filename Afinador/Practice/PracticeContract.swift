import Foundation

// MARK: - CONTRATO DO TREINO / SEPARADOR (Practice/*)
//
// Fluxo: importar música (Arquivos) → tocar com tom/velocidade/loop → (opcional) separar com IA
// em stems → mixer (mudo/solo/volume) → "Usar como base no Estúdio" (cria projeto com os stems
// que ficaram ligados, via StudioEngine.newProject + importAudio).

/// Instrumentos que um separador pode devolver.
enum StemKind: String, Codable, CaseIterable, Identifiable {
    case vocals, drums, bass, guitar, piano, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vocals: return "Voz"
        case .drums: return "Bateria"
        case .bass: return "Baixo"
        case .guitar: return "Violão/Guitarra"
        case .piano: return "Piano"
        case .other: return "Outros"
        }
    }
}

/// Resultado de uma separação: um arquivo por stem.
struct SeparatedSong: Codable, Equatable {
    var sourceName: String
    var stems: [StemKind: URL]
}

/// Separador de fontes. A implementação com IA (Demucs em Core ML) só existe se o modelo
/// estiver no bundle; sem ele, `isAvailable` é false e a UI explica como obter.
protocol StemSeparating {
    var isAvailable: Bool { get }
    var supportedStems: [StemKind] { get }
    /// progress: 0…1, chamado fora da main thread.
    func separate(_ songURL: URL, into folder: URL, progress: @escaping (Double) -> Void) async throws -> SeparatedSong
}
