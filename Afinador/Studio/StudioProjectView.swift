import SwiftUI
import UniformTypeIdentifiers

/// Qual cadeia de efeitos a folha está editando.
enum StudioEffectsTarget: Identifiable, Equatable {
    case monitor
    case track(UUID)

    var id: String {
        switch self {
        case .monitor: return "monitor"
        case .track(let id): return id.uuidString
        }
    }
}

// MARK: - Tela do projeto aberto

@MainActor
struct StudioProjectView: View {
    @ObservedObject var studio: StudioEngine
    @State private var effectsTarget: StudioEffectsTarget?
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let message = localError {
                        StudioErrorBanner(message: message) { localError = nil }
                    }
                    StudioProjectHeader(studio: studio, onError: { localError = $0 })
                    StudioInputPanel(studio: studio, onEditEffects: { effectsTarget = .monitor })
                    StudioTrackList(
                        studio: studio,
                        onEffects: { id in effectsTarget = .track(id) },
                        onError: { localError = $0 }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            StudioTransportBar(studio: studio)
        }
        .sheet(item: $effectsTarget) { target in
            effectsSheet(for: target)
        }
    }

    @ViewBuilder
    private func effectsSheet(for target: StudioEffectsTarget) -> some View {
        switch target {
        case .monitor:
            StudioEffectsSheet(
                title: "Efeitos ao vivo",
                subtitle: "O que você ouve no fone e o que vai para a próxima gravação.",
                settings: $studio.monitorEffects
            )
        case .track(let id):
            StudioEffectsSheet(
                title: trackName(id),
                subtitle: "Efeitos desta faixa na reprodução e na exportação.",
                settings: trackEffectsBinding(id)
            )
        }
    }

    private func trackName(_ id: UUID) -> String {
        studio.project?.tracks.first(where: { $0.id == id })?.name ?? "Faixa"
    }

    private func trackEffectsBinding(_ id: UUID) -> Binding<EffectSettings> {
        Binding<EffectSettings>(
            get: {
                studio.project?.tracks.first(where: { $0.id == id })?.effects ?? EffectSettings()
            },
            set: { newValue in
                guard var track = studio.project?.tracks.first(where: { $0.id == id }) else { return }
                track.effects = newValue
                studio.updateTrack(track)
            }
        )
    }
}

// MARK: - Cabeçalho: nome, tempo, compasso, clique e contagem

@MainActor
struct StudioProjectHeader: View {
    @ObservedObject var studio: StudioEngine
    let onError: (String) -> Void
    @State private var showRename = false
    @State private var renameText = ""

    private var isStopped: Bool { studio.transport == .stopped }
    private var projectName: String { studio.project?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            nameRow
            settingsPanel
        }
        .alert("Renomear música", isPresented: $showRename) {
            TextField("Nome", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { commitRename() }
        }
    }

    private var topRow: some View {
        HStack {
            Button {
                if !isStopped { studio.stop() }
                studio.closeProject()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    Text("Músicas").font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.brass)
                .frame(minHeight: 36)
            }
            .accessibilityLabel("Voltar para a lista de músicas")
            Spacer()
            StudioExportButton(studio: studio, onError: onError)
        }
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(projectName)
                .font(.system(size: 26, weight: .heavy, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Button {
                renameText = projectName
                showRename = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.muted)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Renomear música")
            Spacer(minLength: 0)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            bpmRow
            signatureRow
            Divider().overlay(Color.line)
            clickRow
            countInRow
        }
        .studioPanel()
        .disabled(!isStopped)
        .opacity(isStopped ? 1 : 0.55)
    }

    private var bpmBinding: Binding<Double> {
        Binding<Double>(
            get: { studio.project?.bpm ?? 90 },
            set: { newValue in studio.project?.bpm = min(max(newValue, 30), 250) }
        )
    }

    private var beatsBinding: Binding<Int> {
        Binding<Int>(
            get: { studio.project?.beatsPerBar ?? 4 },
            set: { newValue in studio.project?.beatsPerBar = newValue }
        )
    }

    private var bpmRow: some View {
        Stepper(value: bpmBinding, in: 30...250, step: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(bpmBinding.wrappedValue))")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .monospacedDigit()
                Text("BPM")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.muted)
            }
        }
        .accessibilityLabel("Andamento")
        .accessibilityValue("\(Int(bpmBinding.wrappedValue)) batidas por minuto")
    }

    private var signatureRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compasso").font(.caption).foregroundColor(.muted)
            Picker("Compasso", selection: beatsBinding) {
                Text("2/4").tag(2)
                Text("3/4").tag(3)
                Text("4/4").tag(4)
                Text("6/8").tag(6)
            }
            .pickerStyle(.segmented)
        }
    }

    private var clickRow: some View {
        Toggle(isOn: $studio.clickEnabled) {
            Label("Clique do metrônomo", systemImage: "metronome")
                .font(.system(size: 15))
        }
        .tint(Color.brass)
    }

    private var countInRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contagem antes de gravar").font(.caption).foregroundColor(.muted)
            Picker("Contagem antes de gravar", selection: $studio.countInBars) {
                Text("Nenhuma").tag(0)
                Text("1 compasso").tag(1)
                Text("2 compassos").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let id = studio.project?.id else { return }
        studio.rename(id, to: name)
    }
}

// MARK: - Entrada: medidor, nome, monitoramento e efeito ao vivo

@MainActor
struct StudioInputPanel: View {
    @ObservedObject var studio: StudioEngine
    let onEditEffects: () -> Void

    private var presetBinding: Binding<EffectPreset> {
        Binding<EffectPreset>(
            get: { studio.monitorEffects.preset },
            set: { newValue in
                if newValue == .custom {
                    studio.monitorEffects.preset = .custom
                } else {
                    studio.monitorEffects = EffectSettings.preset(newValue)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputRow
            StudioMeterBar(level: studio.inputLevel, height: 10)
                .accessibilityLabel("Nível da entrada")
                .accessibilityValue("\(Int(studio.inputLevel * 100)) por cento")
            gainRow
            Divider().overlay(Color.line)
            monitorRow
            if studio.monitorEnabled && !studio.isHeadphoneConnected {
                headphoneWarning
            }
            presetRow
        }
        .studioPanel()
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundColor(.brass)
                .accessibilityHidden(true)
            inputMenu
            Spacer(minLength: 4)
            Text("ENTRADA")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.muted)
        }
    }

    /// Escolha da entrada: microfone do iPhone, do fone ou interface USB.
    private var inputMenu: some View {
        Menu {
            ForEach(studio.availableInputs) { option in
                Button {
                    studio.selectInput(option.id)
                } label: {
                    if option.id == studio.selectedInputID {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(studio.inputName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.fg)
        }
        .disabled(studio.transport != .stopped || studio.availableInputs.count < 2)
        .accessibilityLabel("Entrada de áudio: \(studio.inputName). Toque para trocar.")
    }

    /// Ganho digital da entrada (0 a +24 dB).
    private var gainRow: some View {
        HStack(spacing: 10) {
            Text("Ganho")
                .font(.system(size: 13))
                .foregroundColor(.muted)
            Slider(value: $studio.inputGainDB, in: 0...24, step: 1)
                .tint(Color.brass)
            Text("+\(Int(studio.inputGainDB)) dB")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.fg)
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ganho da entrada, mais \(Int(studio.inputGainDB)) decibéis")
    }

    private var monitorRow: some View {
        Toggle(isOn: $studio.monitorEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ouvir a entrada").font(.system(size: 15))
                Text("Monitoramento com efeitos ao vivo")
                    .font(.system(size: 12))
                    .foregroundColor(.muted)
            }
        }
        .tint(Color.brass)
        .accessibilityLabel("Ouvir a entrada com efeitos ao vivo")
    }

    private var headphoneWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "headphones")
                .foregroundColor(.off)
                .accessibilityHidden(true)
            Text("Conecte um fone de ouvido. Sem fone, o som do alto-falante volta para o microfone e pode dar microfonia.")
                .font(.system(size: 13))
                .foregroundColor(.off)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.off.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.off.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    private var presetRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Efeito").font(.caption).foregroundColor(.muted)
                Picker("Efeito ao vivo", selection: presetBinding) {
                    ForEach(EffectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.brass)
            }
            Spacer(minLength: 4)
            StudioChip(title: "Ajustar", systemImage: "slider.horizontal.3", action: onEditEffects)
                .accessibilityLabel("Ajustar efeitos ao vivo")
        }
    }
}

// MARK: - Lista de faixas + importação

@MainActor
struct StudioTrackList: View {
    @ObservedObject var studio: StudioEngine
    let onEffects: (UUID) -> Void
    let onError: (String) -> Void
    @State private var pendingDelete: StudioTrack?
    @State private var showImporter = false
    @State private var importing = false

    private var tracks: [StudioTrack] { studio.project?.tracks ?? [] }
    private var isRecording: Bool {
        switch studio.transport {
        case .recording, .countIn: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if tracks.isEmpty && !isRecording {
                emptyHint
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                row(index: pair.offset, track: pair.element)
            }
            if isRecording {
                recordingRow
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert("Apagar faixa?", isPresented: deleteBinding, presenting: pendingDelete) { track in
            Button("Apagar", role: .destructive) { studio.deleteTrack(track.id) }
            Button("Cancelar", role: .cancel) {}
        } message: { track in
            Text("“\(track.name)” será apagada do projeto. Não dá para desfazer.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding<Bool>(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Faixas")
                .font(.system(size: 20, weight: .heavy, design: .serif))
            Text("\(tracks.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.muted)
            Spacer()
            importButton
        }
    }

    private var importButton: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 6) {
                if importing {
                    ProgressView().tint(Color.brass)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(importing ? "Importando…" : "Importar áudio")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.panel))
            .overlay(Capsule().stroke(Color.line))
            .foregroundColor(.fg)
        }
        .disabled(importing || studio.transport != .stopped)
        .accessibilityLabel("Importar áudio do app Arquivos como nova faixa")
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nenhuma faixa ainda")
                .font(.system(size: 16, weight: .semibold, design: .serif))
            Text("Toque no botão vermelho para gravar a primeira camada, ou importe um áudio (uma base, uma guia) do app Arquivos.")
                .font(.system(size: 13))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel()
    }

    private func row(index: Int, track: StudioTrack) -> some View {
        StudioTrackRow(
            track: track,
            index: index + 1,
            level: studio.trackLevels[track.id] ?? 0,
            isLocked: isRecording,
            onUpdate: { updated in studio.updateTrack(updated) },
            onEffects: { onEffects(track.id) },
            onDelete: { pendingDelete = track }
        )
    }

    private var recordingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color.off).frame(width: 10, height: 10)
                Text("Nova faixa \(tracks.count + 1)")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                Spacer()
                Text(studio.transport == .recording ? "GRAVANDO" : "CONTAGEM")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.off)
            }
            StudioMeterBar(level: studio.inputLevel, height: 8)
            Text("Efeito: \(studio.monitorEffects.preset.title)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.muted)
        }
        .studioPanel(stroke: .off)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Gravando nova faixa \(tracks.count + 1)")
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            onError("Não deu para abrir o arquivo: \(error.localizedDescription)")
        case .success(let urls):
            guard !urls.isEmpty else { return }
            importing = true
            Task {
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent
                    do {
                        _ = try await studio.importAudio(from: url, name: name)
                    } catch {
                        onError("Não deu para importar “\(url.lastPathComponent)”: \(error.localizedDescription)")
                    }
                }
                importing = false
            }
        }
    }
}
