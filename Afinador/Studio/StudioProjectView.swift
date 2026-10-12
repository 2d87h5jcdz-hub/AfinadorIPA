import SwiftUI

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
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        layout
        .sheet(item: $effectsTarget) { target in
            effectsSheet(for: target)
        }
    }

    @ViewBuilder
    private var layout: some View {
        if vSize == .compact {
            landscapeLayout
        } else {
            portraitLayout
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = localError {
            StudioErrorBanner(message: message) { localError = nil }
        }
    }

    private var header: some View {
        StudioProjectHeader(studio: studio, onError: { localError = $0 })
    }

    private var inputPanel: some View {
        StudioInputPanel(studio: studio, onEditEffects: { effectsTarget = .monitor })
    }

    private var timeline: some View {
        StudioTimelineView(studio: studio, onError: { localError = $0 })
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    errorBanner
                    header
                    inputPanel
                    timeline
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            StudioTransportBar(studio: studio)
        }
    }

    /// Horizontal: à esquerda música, entrada e transporte; à direita a linha do tempo com mais espaço.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        errorBanner
                        header
                        inputPanel
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                StudioTransportBar(studio: studio)
            }
            .frame(width: 330)
            Rectangle()
                .fill(Color.line)
                .frame(width: 1)
            ScrollView {
                timeline
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
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
    /// Painel de andamento/compasso/clique recolhível (libera espaço para a linha do tempo).
    @AppStorage("studio.settingsExpanded") private var settingsExpanded: Bool = false

    private var isStopped: Bool { studio.transport == .stopped }
    private var projectName: String { studio.project?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            nameRow
            if settingsExpanded {
                settingsPanel
            } else {
                settingsSummary
            }
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

    private var signatureText: String {
        let beats: Int = studio.project?.beatsPerBar ?? 4
        return beats == 6 ? "6/8" : "\(beats)/4"
    }

    private var summaryText: String {
        let bpm: Int = Int(studio.project?.bpm ?? 90)
        let click: String = studio.clickEnabled ? "clique" : "sem clique"
        let count: String
        switch studio.countInBars {
        case 0: count = "sem contagem"
        case 1: count = "contagem 1"
        default: count = "contagem \(studio.countInBars)"
        }
        return "\(bpm) BPM · \(signatureText) · \(click) · \(count)"
    }

    /// Linha compacta (painel recolhido): toque para abrir os ajustes.
    private var settingsSummary: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { settingsExpanded = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "metronome")
                    .foregroundColor(.brass)
                Text(summaryText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.muted)
            }
            .foregroundColor(.fg)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Andamento e compasso: \(summaryText). Toque para ajustar")
    }

    private var collapseRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { settingsExpanded = false }
        } label: {
            HStack {
                Text("ANDAMENTO E COMPASSO")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.muted)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.muted)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recolher ajustes de andamento e compasso")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            collapseRow
            settingsControls
                .disabled(!isStopped)
                .opacity(isStopped ? 1 : 0.55)
        }
        .studioPanel()
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            bpmRow
            signatureRow
            Divider().overlay(Color.line)
            clickRow
            countInRow
        }
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

    /// Painel recolhível: recolhido mostra só entrada + medidor (telas pequenas).
    @AppStorage("studio.inputExpanded") private var expanded: Bool = false

    var body: some View {
        if expanded {
            expandedBody
        } else {
            compactBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded = true }
            } label: {
                compactRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Entrada: \(studio.inputName), efeito \(studio.monitorEffects.preset.title). Toque para ajustar")
            if studio.monitorEnabled && !studio.isHeadphoneConnected {
                headphoneWarning
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundColor(.brass)
            VStack(alignment: .leading, spacing: 2) {
                Text(studio.inputName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(compactDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.muted)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            StudioMeterBar(level: studio.inputLevel, height: 8)
                .frame(width: 70)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.muted)
        }
        .foregroundColor(.fg)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private var compactDetail: String {
        let monitor: String = studio.monitorEnabled ? "ouvindo" : "sem retorno"
        return "\(studio.monitorEffects.preset.title) · \(monitor)"
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded = false }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.muted)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recolher painel de entrada")
    }

    private var expandedBody: some View {
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
            collapseButton
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
