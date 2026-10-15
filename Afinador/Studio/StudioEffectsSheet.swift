import SwiftUI
import UniformTypeIdentifiers

// MARK: - Folha de efeitos (faixa ou monitoramento)
// Ordem no motor: noise gate → EQ → compressor → guitarra (drive + amp + modulação) → delay → reverb.

struct StudioEffectsSheet: View {
    let title: String
    let subtitle: String
    @Binding var settings: EffectSettings
    /// Seção extra logo abaixo dos presets (ex.: afinação automática das faixas).
    var extraTop: AnyView? = nil
    /// Ao vivo (monitoramento, Loop): aprendendo o ruído agora? nil = faixa do Estúdio (limpa a gravação).
    var noiseLearning: Bool? = nil
    var onLearnNoise: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var ampNames: [String] = StudioAmps.list()
    @State private var showAmpImporter = false
    @State private var ampMessage: String?

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    presetPicker
                    if let extraTop {
                        extraTop
                    }
                    noiseSection
                    gateSection
                    eqSection
                    compressorSection
                    driveSection
                    ampSection
                    modulationSection
                    delaySection
                    reverbSection
                    resetButton
                }
                .padding(16)
            }
        }
        .foregroundColor(.fg)
        .fileImporter(isPresented: $showAmpImporter, allowedContentTypes: [UTType.data],
                      allowsMultipleSelection: false) { result in
            importAmp(result)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Cabeçalho e presets

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .heavy, design: .serif))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Pronto") { dismiss() }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.brass)
        }
        .padding(.top, 8)
    }

    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EffectPreset.allCases) { preset in
                    StudioChip(title: preset.title,
                               isOn: settings.preset == preset,
                               onColor: .brass) {
                        choose(preset)
                    }
                    .accessibilityLabel("Preset \(preset.title)")
                    .accessibilityAddTraits(settings.preset == preset ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func choose(_ preset: EffectPreset) {
        if preset == .custom {
            var s = settings
            s.preset = .custom
            settings = s
        } else {
            // O amplificador escolhido não faz parte dos presets: continua o mesmo.
            var s = EffectSettings.preset(preset)
            s.ampModel = settings.ampModel
            s.ampInputDB = settings.ampInputDB
            s.ampOutputDB = settings.ampOutputDB
            s.keepNoise(from: settings)
            settings = s
        }
    }

    // MARK: Seções

    private var noiseSection: some View {
        StudioEffectSection(title: "Redução de ruído", systemImage: "wind") {
            Toggle(isOn: Binding(get: { settings.noiseEnabled },
                                 set: { on in var s = settings; s.noiseEnabled = on; settings = s })) {
                Text("Tirar o ruído do ambiente")
                    .font(.system(size: 14))
            }
            .tint(Color.brass)
            StudioEffectSlider(label: "Intensidade", value: plainBinding(\.noiseAmount),
                               range: 0...1, text: percentText(settings.noiseAmount))
            noiseHelp
        }
    }

    @ViewBuilder
    private var noiseHelp: some View {
        if let learning = noiseLearning {
            Button {
                onLearnNoise?()
            } label: {
                Label(learning ? "Ouvindo o ruído… fique em silêncio" : "Aprender o ruído (fique 2 s em silêncio)",
                      systemImage: learning ? "ear" : "waveform.badge.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(learning ? Color.line : Color.brass))
                    .foregroundColor(learning ? .fg : .bg)
            }
            .disabled(learning)
            if settings.noiseEnabled && settings.noiseProfile == nil && !learning {
                Text("Falta aprender o ruído: sem isso a redução não age. Aperte o botão acima sem tocar nada.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.off)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(settings.noiseProfile == nil
                 ? "Para ar-condicionado, ventilador, chiado e rua ao longe. Aperte o botão sem tocar nada: o app aprende o ruído e passa a tirar só ele."
                 : "Ruído aprendido. Se o ambiente mudar (ligou o ar, por exemplo), aprenda de novo.")
                .font(.system(size: 12))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Limpa a gravação desta faixa em segundo plano (o original não muda). Usa o ruído aprendido nos efeitos ao vivo ou, sem ele, os trechos sem som da própria gravação.")
                .font(.system(size: 12))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gateSection: some View {
        StudioEffectSection(title: "Noise gate", systemImage: "waveform.badge.minus") {
            Toggle("Ligado", isOn: boolBinding(\.gateEnabled))
                .tint(Color.brass)
            StudioEffectSlider(label: "Limiar", value: floatBinding(\.gateThresholdDB),
                               range: -80 ... -20, text: dbText(settings.gateThresholdDB))
                .disabled(!settings.gateEnabled)
                .opacity(settings.gateEnabled ? 1 : 0.45)
        }
    }

    private var eqSection: some View {
        StudioEffectSection(title: "Equalizador", systemImage: "slider.vertical.3") {
            StudioEffectSlider(label: "Graves · 100 Hz", value: floatBinding(\.eqLowDB),
                               range: -12...12, text: signedDbText(settings.eqLowDB))
            StudioEffectSlider(label: "Médios · 1 kHz", value: floatBinding(\.eqMidDB),
                               range: -12...12, text: signedDbText(settings.eqMidDB))
            StudioEffectSlider(label: "Agudos · 8 kHz", value: floatBinding(\.eqHighDB),
                               range: -12...12, text: signedDbText(settings.eqHighDB))
            StudioEffectSlider(label: "Tirar embolado · 300 Hz", value: floatBinding(\.eqMuddyDB),
                               range: -12...0, text: signedDbText(settings.eqMuddyDB))
            StudioEffectSlider(label: "Presença · 4 kHz", value: floatBinding(\.eqPresenceDB),
                               range: -6...8, text: signedDbText(settings.eqPresenceDB))
            Toggle("Cortar graves abaixo de 80 Hz", isOn: boolBinding(\.eqLowCut))
                .tint(Color.brass)
            Text("Microfone de estúdio muito perto engorda os médios graves (efeito de proximidade). Tire o embolado e dê presença, ou use o preset Microfone de perto.")
                .font(.system(size: 12))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compressorSection: some View {
        StudioEffectSection(title: "Compressor", systemImage: "arrow.down.right.and.arrow.up.left") {
            Toggle("Ligado", isOn: boolBinding(\.compressorEnabled))
                .tint(Color.brass)
            StudioEffectSlider(label: "Quantidade", value: floatBinding(\.compressorAmount),
                               range: 0...1, text: percentText(settings.compressorAmount))
                .disabled(!settings.compressorEnabled)
                .opacity(settings.compressorEnabled ? 1 : 0.45)
        }
    }

    private var driveSection: some View {
        StudioEffectSection(title: "Drive", systemImage: "bolt.fill") {
            StudioEffectSlider(label: "Distorção (0 = desligado)", value: floatBinding(\.driveAmount),
                               range: 0...1, text: percentText(settings.driveAmount))
            menuRow(title: "Estilo", value: settings.driveStyle.title) {
                Picker("Estilo", selection: valueBinding(\.driveStyle)) {
                    ForEach(DriveStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
        }
    }

    // MARK: Amplificador (Neural Amp Modeler)

    private var ampTitle: String {
        guard let name = settings.ampModel else { return "Nenhum" }
        return StudioAmps.displayName(name)
    }

    private var ampSection: some View {
        StudioEffectSection(title: "Amplificador (IA)", systemImage: "hifispeaker.fill") {
            Text("Modelos .nam do Neural Amp Modeler imitam amplificadores e pedais reais. Baixe grátis em tone3000.com e importe aqui. Use com o drive desligado.")
                .font(.system(size: 12))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Modelo")
                    .font(.system(size: 13))
                    .foregroundColor(.muted)
                Spacer()
                Menu {
                    Button("Nenhum") { setAmp(nil) }
                    ForEach(ampNames, id: \.self) { name in
                        Button(StudioAmps.displayName(name)) { setAmp(name) }
                    }
                    Divider()
                    Button {
                        showAmpImporter = true
                    } label: {
                        Label("Importar arquivo .nam…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ampTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.brass)
                }
            }
            if settings.ampModel != nil {
                StudioEffectSlider(label: "Entrada (ganho no amp)", value: plainBinding(\.ampInputDB),
                                   range: -12...12, text: signedDbText(settings.ampInputDB))
                StudioEffectSlider(label: "Saída (volume)", value: plainBinding(\.ampOutputDB),
                                   range: -12...12, text: signedDbText(settings.ampOutputDB))
            }
            if let message = ampMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(message.hasPrefix("✓") ? .ok : .off)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setAmp(_ name: String?) {
        var s = settings
        s.ampModel = name
        settings = s
        ampMessage = nil
    }

    private func importAmp(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            ampMessage = "Não deu para abrir: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let name = try StudioAmps.importModel(from: url)
                ampNames = StudioAmps.list()
                setAmp(name)
                ampMessage = "✓ \(StudioAmps.displayName(name)) importado."
            } catch {
                ampMessage = error.localizedDescription
            }
        }
    }

    // MARK: Modulação

    private var modulationSection: some View {
        StudioEffectSection(title: "Modulação", systemImage: "waveform.path") {
            menuRow(title: "Tipo", value: settings.modType.title) {
                Picker("Tipo", selection: valueBinding(\.modType)) {
                    ForEach(ModulationType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
            }
            if settings.modType != .none {
                StudioEffectSlider(label: "Velocidade", value: floatBinding(\.modRate),
                                   range: 0.05...8, text: String(format: "%.2f Hz", settings.modRate))
                StudioEffectSlider(label: "Profundidade", value: floatBinding(\.modDepth),
                                   range: 0...1, text: percentText(settings.modDepth))
                StudioEffectSlider(label: "Mix", value: floatBinding(\.modMix),
                                   range: 0...1, text: percentText(settings.modMix))
            }
        }
    }

    private func menuRow<Content: View>(title: String, value: String,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.muted)
            Spacer()
            Menu {
                content()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.brass)
            }
        }
    }

    private var delaySection: some View {
        StudioEffectSection(title: "Delay", systemImage: "repeat") {
            StudioEffectSlider(label: "Mix", value: floatBinding(\.delayMix),
                               range: 0...1, text: percentText(settings.delayMix))
            StudioEffectSlider(label: "Tempo", value: floatBinding(\.delayTime),
                               range: 0.05...1.0, text: msText(settings.delayTime))
            StudioEffectSlider(label: "Repetições", value: floatBinding(\.delayFeedback),
                               range: 0...0.9, text: percentText(settings.delayFeedback))
        }
    }

    private var reverbSection: some View {
        StudioEffectSection(title: "Reverb", systemImage: "building.columns") {
            StudioEffectSlider(label: "Mix", value: floatBinding(\.reverbMix),
                               range: 0...1, text: percentText(settings.reverbMix))
        }
    }

    private var resetButton: some View {
        Button {
            var s = EffectSettings.preset(.none)
            s.noiseProfile = settings.noiseProfile
            s.noiseProfileRate = settings.noiseProfileRate
            settings = s
        } label: {
            Label("Tirar todos os efeitos", systemImage: "arrow.counterclockwise")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().stroke(Color.line))
                .foregroundColor(.muted)
        }
        .padding(.top, 4)
    }

    // MARK: Bindings (mexer em qualquer controle vira "Personalizado")

    /// Muda um valor e marca o preset como personalizado.
    private func valueBinding<V>(_ keyPath: WritableKeyPath<EffectSettings, V>) -> Binding<V> {
        Binding<V>(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var s = settings
                s[keyPath: keyPath] = newValue
                s.preset = .custom
                settings = s
            }
        )
    }

    /// Muda um valor sem mexer no preset (ex.: ganhos do amplificador).
    private func plainBinding(_ keyPath: WritableKeyPath<EffectSettings, Float>) -> Binding<Float> {
        Binding<Float>(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var s = settings
                s[keyPath: keyPath] = newValue
                settings = s
            }
        )
    }

    private func floatBinding(_ keyPath: WritableKeyPath<EffectSettings, Float>) -> Binding<Float> {
        Binding<Float>(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var s = settings
                s[keyPath: keyPath] = newValue
                s.preset = .custom
                settings = s
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<EffectSettings, Bool>) -> Binding<Bool> {
        Binding<Bool>(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var s = settings
                s[keyPath: keyPath] = newValue
                s.preset = .custom
                settings = s
            }
        )
    }

    // MARK: Textos

    private func dbText(_ v: Float) -> String { String(format: "%.0f dB", v) }
    private func signedDbText(_ v: Float) -> String { String(format: "%+.1f dB", v) }
    private func percentText(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
    private func msText(_ v: Float) -> String { "\(Int((v * 1000).rounded())) ms" }
}

// MARK: - Peças da folha

struct StudioEffectSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundColor(.fg)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel()
    }
}

struct StudioEffectSlider: View {
    let label: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundColor(.muted)
                Spacer()
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range)
                .tint(Color.brass)
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
    }
}
