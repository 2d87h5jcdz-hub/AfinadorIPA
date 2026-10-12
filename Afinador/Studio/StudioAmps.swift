import Foundation

// MARK: - Amplificadores (modelos .nam do Neural Amp Modeler)
//
// Ficam em Documentos/Amps (visível no app Arquivos). O usuário baixa capturas gratuitas
// (ex.: tone3000.com) e importa; o app confere se o arquivo abre antes de copiar.

enum StudioAmps {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Amps", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Nomes dos arquivos .nam disponíveis, em ordem alfabética.
    static func list() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".nam") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL? {
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Nome amigável: sem a extensão.
    static func displayName(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    enum ImportError: LocalizedError {
        case notNAM
        case invalid(String)
        case copy(String)
        var errorDescription: String? {
            switch self {
            case .notNAM: return "Escolha um arquivo .nam (modelo do Neural Amp Modeler)."
            case .invalid(let why): return "Esse modelo não abriu: \(why)"
            case .copy(let why): return "Não deu para copiar o arquivo: \(why)"
            }
        }
    }

    /// Copia um .nam escolhido no app Arquivos para Amps/ e devolve o nome salvo.
    static func importModel(from source: URL) throws -> String {
        guard source.pathExtension.lowercased() == "nam" else { throw ImportError.notNAM }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".nam")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
        } catch {
            throw ImportError.copy(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        if let problem = PestanaGuitarAU.validateModel(atPath: temp.path) {
            throw ImportError.invalid(problem)
        }
        var name = source.lastPathComponent
        var destination = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            name = "\(source.deletingPathExtension().lastPathComponent) \(n).nam"
            destination = folder.appendingPathComponent(name)
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: temp, to: destination)
        } catch {
            throw ImportError.copy(error.localizedDescription)
        }
        return name
    }
}
