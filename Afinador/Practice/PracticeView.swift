import SwiftUI
import UniformTypeIdentifiers

// MARK: - Aba Treino

struct PracticeView: View {
    @ObservedObject var studio: StudioEngine
    var openStudio: () -> Void

    @StateObject private var engine = PracticeEngine()
    @State private var showImporter = false
    @State private var sendingToStudio = false

    private static let audioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            content
        }
        .foregroundColor(.fg)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.audioTypes,
                      allowsMultipleSelection: false, onCompletion: { handleImport($0) })
        .alert("Treino", isPresented: errorShown, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(engine.lastError ?? "")
        })
        .onAppear { engine.activate() }
        .onDisappear { engine.deactivate() }
    }

    @ViewBuilder private var content: some View {
        if engine.current != nil {
            PracticePlayerScreen(engine: engine, sending: sendingToStudio,
                                 onBack: { engine.close() }, onStudio: { sendToStudio() })
        } else {
            PracticeLibraryScreen(engine: engine, onImport: { showImporter = true })
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { engine.lastError != nil }, set: { if !$0 { engine.lastError = nil } })
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first { engine.importSong(from: url) }
        case .failure(let error):
            engine.lastError = "Não consegui abrir o arquivo: \(error.localizedDescription)"
        }
    }

    /// Cria um projeto no Estúdio com os stems audíveis (ou a música inteira) e abre o Estúdio.
    private func sendToStudio() {
        guard let song = engine.current, !sendingToStudio else { return }
        engine.pause()
        let items = engine.filesForStudio()
        sendingToStudio = true
        Task {
            _ = studio.newProject(name: song.title)
            do {
                for item in items {
                    _ = try await studio.importAudio(from: item.url, name: item.name)
                }
                sendingToStudio = false
                openStudio()
            } catch {
                sendingToStudio = false
                engine.lastError = "Não consegui mandar para o Estúdio: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Estilo

private struct PracticeCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
    }
}

private extension View {
    func practiceCard() -> some View { modifier(PracticeCard()) }
}

private struct PracticeSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.muted)
    }
}

private struct PracticeChip: View {
    let title: String
    var selected = false
    var tint: Color = .brass
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.22) : Color.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? tint : Color.line))
                .foregroundColor(selected ? tint : .fg)
        }
        .buttonStyle(.plain)
    }
}

enum PracticeFormat {
    static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Biblioteca

private struct PracticeLibraryScreen: View {
    @ObservedObject var engine: PracticeEngine
    let onImport: () -> Void
    @State private var renaming: PracticeSong?
    @State private var newTitle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                importButton
                if engine.library.isEmpty {
                    emptyState
                } else {
                    PracticeSectionTitle(text: "Suas músicas")
                    LazyVStack(spacing: 10) {
                        ForEach(engine.library) { song in
                            PracticeSongRow(song: song, onOpen: { engine.open(song) },
                                            onRename: { newTitle = song.title; renaming = song },
                                            onDelete: { engine.delete(song) })
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert("Renomear", isPresented: renameShown, actions: {
            TextField("Nome", text: $newTitle)
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Salvar") {
                if let s = renaming { engine.rename(s, to: newTitle) }
                renaming = nil
            }
        })
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("Trei").foregroundColor(.fg) + Text("no").foregroundColor(.brass))
                .font(.system(size: 24, weight: .heavy, design: .serif))
            Text("Toque junto com suas músicas: mude o tom, a velocidade, repita um trecho e tire um instrumento com IA.")
                .font(.footnote)
                .foregroundColor(.muted)
        }
    }

    private var importButton: some View {
        Button(action: onImport) {
            HStack(spacing: 10) {
                if engine.isImporting {
                    ProgressView().tint(.bg)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(engine.isImporting ? "Importando…" : "Importar música (MP3, M4A, WAV)")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.brass))
            .foregroundColor(.bg)
        }
        .buttonStyle(.plain)
        .disabled(engine.isImporting)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 28)).foregroundColor(.brass)
            Text("Nenhuma música ainda").font(.headline)
            Text("Coloque o arquivo no app Arquivos (iCloud Drive, \"No meu iPhone\"…) e toque em Importar.")
                .font(.footnote).foregroundColor(.muted)
        }
        .practiceCard()
    }
}

private struct PracticeSongRow: View {
    let song: PracticeSong
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: song.hasStems ? "waveform.path.ecg" : "music.note")
                    .font(.system(size: 18))
                    .foregroundColor(.brass)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12, design: .monospaced)).foregroundColor(.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.muted)
            }
            .practiceCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onRename) { Label("Renomear", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Apagar", systemImage: "trash") }
        }
    }

    private var subtitle: String {
        var parts = [PracticeFormat.time(song.duration)]
        if song.hasStems { parts.append("separada") }
        if song.semitones != 0 { parts.append(PracticeNotes.intervalText(song.semitones)) }
        if song.speed != 1 { parts.append("\(Int((song.speed * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Player

private struct PracticePlayerScreen: View {
    @ObservedObject var engine: PracticeEngine
    let sending: Bool
    let onBack: () -> Void
    let onStudio: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PracticePlayerHeader(engine: engine, onBack: onBack)
                VStack(spacing: 14) {
                    PracticeScrubber(engine: engine)
                    PracticeTransport(engine: engine)
                }
                .practiceCard()
                PracticeLoopCard(engine: engine)
                PracticePitchCard(engine: engine)
                PracticeSpeedCard(engine: engine)
                PracticeStemsCard(engine: engine)
                PracticeStudioCard(engine: engine, sending: sending, onStudio: onStudio)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct PracticePlayerHeader: View {
    @ObservedObject var engine: PracticeEngine
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.panel))
                    .overlay(Circle().stroke(Color.line))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.current?.title ?? "")
                    .font(.system(size: 20, weight: .heavy, design: .serif))
                    .lineLimit(1)
                Text(engine.useStems ? "INSTRUMENTOS SEPARADOS" : "MÚSICA ORIGINAL")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(engine.useStems ? .ok : .muted)
            }
            Spacer()
        }
    }
}

private struct PracticeScrubber: View {
    @ObservedObject var engine: PracticeEngine
    @State private var dragValue: Double?

    private var upper: Double { max(engine.duration, 0.1) }
    private var shown: Double { min(dragValue ?? engine.position, upper) }

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { dragValue = $0 }), in: 0...upper,
                   onEditingChanged: editingChanged)
                .tint(.brass)
                .background(PracticeLoopBand(a: engine.loopA, b: engine.loopB, duration: upper))
            HStack {
                Text(PracticeFormat.time(shown))
                Spacer()
                Text("-" + PracticeFormat.time(upper - shown))
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.muted)
        }
    }

    private func editingChanged(_ editing: Bool) {
        if !editing, let v = dragValue {
            engine.seek(to: v)
            dragValue = nil
        }
    }
}

/// Faixa do loop A-B desenhada atrás do slider.
private struct PracticeLoopBand: View {
    let a: TimeInterval?
    let b: TimeInterval?
    let duration: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 12
            let w = max(1, geo.size.width - inset * 2)
            if let a {
                let x0 = inset + w * CGFloat(a / duration)
                let x1 = b.map { inset + w * CGFloat($0 / duration) } ?? x0 + 2
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.brass.opacity(0.28))
                    .frame(width: max(2, x1 - x0), height: 18)
                    .position(x: (x0 + x1) / 2, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PracticeTransport: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        HStack(spacing: 28) {
            skipButton("gobackward.5", -5)
            Button(action: { engine.togglePlay() }) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.bg)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.brass))
            }
            .buttonStyle(.plain)
            skipButton("goforward.5", 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func skipButton(_ icon: String, _ delta: TimeInterval) -> some View {
        Button { engine.skip(delta) } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.bg))
                .overlay(Circle().stroke(Color.line))
        }
        .buttonStyle(.plain)
    }
}

private struct PracticeLoopCard: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PracticeSectionTitle(text: "Repetir trecho (A-B)")
                Spacer()
                Text(status).font(.system(size: 12, design: .monospaced))
                    .foregroundColor(engine.loopActive ? .ok : .muted)
            }
            HStack(spacing: 8) {
                PracticeChip(title: "A", selected: engine.loopA != nil, action: { engine.setLoopA() })
                PracticeChip(title: "B", selected: engine.loopB != nil, action: { engine.setLoopB() })
                PracticeChip(title: "Limpar", action: { engine.clearLoop() })
                Spacer()
                if let a = engine.loopA {
                    Button { engine.seek(to: a) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.brass)
                }
            }
        }
        .practiceCard()
    }

    private var status: String {
        switch (engine.loopA, engine.loopB) {
        case let (a?, b?): return "\(PracticeFormat.time(a)) → \(PracticeFormat.time(b))"
        case let (a?, nil): return "A \(PracticeFormat.time(a)) · marque o B"
        default: return "desligado"
        }
    }
}

private struct PracticePitchCard: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PracticeSectionTitle(text: "Tom")
                Spacer()
                keyMenu
            }
            HStack(spacing: 14) {
                stepButton("minus", -1)
                VStack(spacing: 2) {
                    Text(PracticeNotes.intervalText(engine.semitones))
                        .font(.system(size: 18, weight: .bold))
                    Text(keyLine).font(.system(size: 13)).foregroundColor(.muted)
                }
                .frame(maxWidth: .infinity)
                stepButton("plus", 1)
            }
        }
        .practiceCard()
    }

    private var keyLine: String {
        let st = engine.semitones
        if let k = engine.current?.originalKey {
            return st == 0 ? "Tom: \(PracticeNotes.name(k))"
                           : "\(PracticeNotes.name(k)) → \(PracticeNotes.transposed(k, by: st))"
        }
        return st == 0 ? "Sem mudança" : "Ex.: um acorde de C vira \(PracticeNotes.transposed(0, by: st))"
    }

    private var keyMenu: some View {
        Menu {
            Button("Não sei") { engine.setOriginalKey(nil) }
            ForEach(0..<12, id: \.self) { k in
                Button(PracticeNotes.name(k)) { engine.setOriginalKey(k) }
            }
        } label: {
            Text("Tom original: \(engine.current?.originalKey.map { PracticeNotes.name($0) } ?? "?")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.brass)
        }
    }

    private func stepButton(_ icon: String, _ delta: Int) -> some View {
        let next = engine.semitones + delta
        let enabled = PracticeEngine.semitoneRange.contains(next)
        return Button { engine.setSemitones(next) } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.bg))
                .overlay(Circle().stroke(Color.line))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct PracticeSpeedCard: View {
    @ObservedObject var engine: PracticeEngine
    private let presets: [Double] = [0.5, 0.75, 0.9, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PracticeSectionTitle(text: "Velocidade")
                Spacer()
                Text("\(Int((engine.speed * 100).rounded()))%")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            Slider(value: Binding(get: { engine.speed }, set: { engine.setSpeed($0) }),
                   in: PracticeEngine.speedRange, step: 0.01)
                .tint(.brass)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    PracticeChip(title: "\(Int(p * 100))%", selected: abs(engine.speed - p) < 0.005) {
                        engine.setSpeed(p)
                    }
                }
            }
        }
        .practiceCard()
    }
}

// MARK: - Instrumentos (IA)

private struct PracticeStemsCard: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PracticeSectionTitle(text: "Instrumentos")
            if engine.current?.hasStems == true {
                PracticeMixer(engine: engine)
            } else {
                PracticeSeparatePanel(engine: engine)
            }
        }
        .practiceCard()
    }
}

private struct PracticeSeparatePanel: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        if engine.isSeparating {
            progress
        } else if !engine.separatorAvailable {
            unavailable
        } else {
            separateButton
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: engine.separationProgress).tint(.brass)
            HStack {
                Text("Separando… \(Int(engine.separationProgress * 100))%")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancelar", action: { engine.cancelSeparation() })
                    .foregroundColor(.off)
            }
            Text("Leva alguns minutos (a IA roda no próprio iPhone). Deixe o app aberto.")
                .font(.footnote).foregroundColor(.muted)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Separar instrumentos (IA)", systemImage: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.muted)
            Text("Modelo de IA não incluído nesta versão do app. Rode o workflow \"Modelo Demucs\" no GitHub e gere o .ipa de novo para ativar.")
                .font(.footnote).foregroundColor(.muted)
        }
    }

    private var separateButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { engine.separateCurrent() }) {
                Label("Separar instrumentos (IA)", systemImage: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.brass))
                    .foregroundColor(.bg)
            }
            .buttonStyle(.plain)
            Text("Separa em: " + engine.separatorStems.map { $0.title }.joined(separator: ", ") + ". Depois dá para tirar o violão e tocar por cima, ou tirar a voz e cantar.")
                .font(.footnote).foregroundColor(.muted)
        }
    }
}

private struct PracticeMixer: View {
    @ObservedObject var engine: PracticeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { engine.useStems }, set: { engine.setUseStems($0) })) {
                Text("Usar instrumentos separados").font(.system(size: 15, weight: .semibold))
            }
            .tint(.brass)
            if engine.useStems {
                quickActions
                ForEach(engine.availableStems) { kind in
                    PracticeStemRow(engine: engine, kind: kind)
                }
                if !engine.availableStems.contains(.guitar) {
                    Text("Este modelo não separa o violão: ele fica em \"Outros\".")
                        .font(.footnote).foregroundColor(.muted)
                }
            }
            Button(role: .destructive, action: { engine.deleteStems() }) {
                Label("Apagar separação", systemImage: "trash").font(.footnote)
            }
            .foregroundColor(.off)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            if engine.availableStems.contains(.guitar) {
                PracticeChip(title: "Sem violão") { engine.removeOnly(.guitar) }
            }
            if engine.availableStems.contains(.vocals) {
                PracticeChip(title: "Karaokê") { engine.removeOnly(.vocals) }
            }
            PracticeChip(title: "Tudo") { engine.resetMix() }
        }
    }
}

private struct PracticeStemRow: View {
    @ObservedObject var engine: PracticeEngine
    let kind: StemKind

    private var state: StemMixState { engine.stemMix[kind] ?? StemMixState() }

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(engine.isAudible(kind) ? .fg : .muted)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            toggle("M", on: state.isMuted, tint: .off) { engine.toggleMute(kind) }
            toggle("S", on: state.isSolo, tint: .ok) { engine.toggleSolo(kind) }
            Slider(value: Binding(get: { Double(state.volume) }, set: { engine.setStemVolume(kind, Float($0)) }),
                   in: 0...1.5)
                .tint(.brass)
        }
    }

    private func toggle(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? tint.opacity(0.25) : Color.bg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? tint : Color.line))
                .foregroundColor(on ? tint : .muted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Estúdio

private struct PracticeStudioCard: View {
    @ObservedObject var engine: PracticeEngine
    let sending: Bool
    let onStudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PracticeSectionTitle(text: "Gravar por cima")
            Button(action: onStudio) {
                HStack(spacing: 10) {
                    if sending { ProgressView().tint(.fg) } else { Image(systemName: "waveform.badge.plus") }
                    Text(sending ? "Preparando projeto…" : "Usar como base no Estúdio")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Color.brass, lineWidth: 1.5))
                .foregroundColor(.brass)
            }
            .buttonStyle(.plain)
            .disabled(sending)
            Text(caption).font(.footnote).foregroundColor(.muted)
        }
        .practiceCard()
    }

    private var caption: String {
        let names = engine.filesForStudio().map { $0.name }
        let base = "Cria um projeto no Estúdio com: " + names.joined(separator: ", ") + "."
        if engine.semitones != 0 || engine.speed != 1 {
            return base + " Tom e velocidade do Treino não vão junto (os arquivos vão no original)."
        }
        return base
    }
}
