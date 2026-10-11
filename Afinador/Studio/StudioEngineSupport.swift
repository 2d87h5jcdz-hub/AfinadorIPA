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
