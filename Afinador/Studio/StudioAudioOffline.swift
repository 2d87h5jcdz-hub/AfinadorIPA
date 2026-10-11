import AVFoundation
import Foundation

// Operações pesadas de arquivo do Estúdio. Rodam fora da main thread (Task.detached no StudioEngine).

struct StudioImportResult: Sendable {
    let fileName: String
    let duration: TimeInterval
}

enum StudioFileOps {
    /// Valida que o arquivo é legível pelo AVAudioFile e copia para a pasta do projeto
    /// como "track-<uuid>.<ext original>". O acesso security-scoped é aberto por quem chama.
    static func importCopy(from source: URL, into folder: URL, trackID: UUID) throws -> StudioImportResult {
        let name = source.lastPathComponent
        let duration: TimeInterval
        do {
            let audio = try AVAudioFile(forReading: source)
            let sr = audio.fileFormat.sampleRate
            guard sr > 0, audio.length > 0 else { throw StudioEngineError.unreadableAudio(name) }
            duration = Double(audio.length) / sr
        } catch let error as StudioEngineError {
            throw error
        } catch {
            throw StudioEngineError.unreadableAudio(name)
        }

        var ext = source.pathExtension.lowercased()
        if ext.isEmpty { ext = "caf" }
        let fileName = "track-\(trackID.uuidString).\(ext)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw StudioEngineError.copyFailed(name)
        }
        return StudioImportResult(fileName: fileName, duration: duration)
    }
}

/// Mixagem offline: um AVAudioEngine separado em manual rendering mode com o MESMO grafo do
/// motor ao vivo (StudioTrackChain + limitador master), respeitando volume/pan/mudo/solo/efeitos/offset.
enum StudioOfflineRenderer {
    static let sampleRate: Double = 44_100
    static let maxFrames: AVAudioFrameCount = 4096

    static func render(project: StudioProject, folder: URL, format: ExportFormat, to destination: URL) throws {
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw StudioEngineError.exportFailed("formato de áudio inválido")
        }
        let anySolo = project.tracks.contains { $0.isSolo }
        let audible = project.tracks.filter { StudioMix.isAudible($0, anySolo: anySolo) && $0.volume > 0 }
        guard !audible.isEmpty else { throw StudioEngineError.nothingToExport }

        let engine = AVAudioEngine()
        do {
            // Ativado ANTES de montar o grafo para o mainMixer → output já usar o formato de render.
            try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        } catch {
            throw StudioEngineError.exportFailed("não foi possível preparar o renderizador")
        }

        let master = AVAudioMixerNode()
        let limiter = StudioAudioUnits.makeLimiter()
        engine.attach(master)
        engine.attach(limiter)
        engine.connect(master, to: limiter, format: renderFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: renderFormat)

        var chains: [(chain: StudioTrackChain, track: StudioTrack)] = []
        var end: TimeInterval = 0
        var hasTail = false
        for track in audible {
            let url = folder.appendingPathComponent(track.fileName)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { continue }
            let chain = StudioTrackChain(trackID: track.id, file: file)
            chain.install(in: engine, destination: master, format: renderFormat)
            chain.apply(track, anySolo: anySolo)
            chains.append((chain: chain, track: track))
            end = max(end, track.offset + chain.fileDuration)
            if track.effects.reverbMix > 0.001 || track.effects.delayMix > 0.001 { hasTail = true }
        }
        guard !chains.isEmpty, end > 0 else { throw StudioEngineError.nothingToExport }

        // Cauda para reverb/delay não serem cortados no fim.
        let totalFrames = AVAudioFramePosition((end + (hasTail ? 2.5 : 0.1)) * sampleRate)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw StudioEngineError.exportFailed("não foi possível iniciar o renderizador")
        }
        defer {
            for item in chains { item.chain.player.stop() }
            engine.stop()
        }

        for item in chains {
            if item.chain.schedule(songPosition: 0, offset: item.track.offset, leadIn: 0) {
                item.chain.player.play()
            }
        }

        try? FileManager.default.removeItem(at: destination)
        try renderLoop(engine: engine, totalFrames: totalFrames, format: format, to: destination)
    }

    /// Separado em função própria para o AVAudioFile de saída ser liberado (e finalizado) ao retornar.
    private static func renderLoop(engine: AVAudioEngine, totalFrames: AVAudioFramePosition,
                                   format: ExportFormat, to destination: URL) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw StudioEngineError.exportFailed("sem memória para o buffer de render")
        }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings(for: format),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw StudioEngineError.exportFailed("não foi possível criar o arquivo de saída")
        }

        var stalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            if Task.isCancelled { throw CancellationError() }
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(frames, to: buffer)
            } catch {
                throw StudioEngineError.exportFailed(error.localizedDescription)
            }
            switch status {
            case .success:
                stalls = 0
                do { try output.write(from: buffer) } catch {
                    throw StudioEngineError.exportFailed("erro ao gravar o arquivo (\(error.localizedDescription))")
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 1000 { throw StudioEngineError.exportFailed("o renderizador travou") }
            case .error:
                throw StudioEngineError.exportFailed("erro no renderizador")
            @unknown default:
                throw StudioEngineError.exportFailed("estado desconhecido do renderizador")
            }
        }
    }

    static func settings(for format: ExportFormat) -> [String: Any] {
        switch format {
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}
