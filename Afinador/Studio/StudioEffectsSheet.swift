import SwiftUI

// MARK: - Folha de efeitos (faixa ou monitoramento)
// Ordem no motor: noise gate → EQ → compressor → drive → delay → reverb.

struct StudioEffectsSheet: View {
    let title: String
    let subtitle: String
    @Binding var settings: EffectSettings
    /// Seção extra logo abaixo dos presets (ex.: afinação automática das faixas).
    var extraTop: AnyView? = nil
    @Environment(\.dismiss) private var dismiss

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
                    gateSection
                    eqSection
                    compressorSection
                    driveSection
                    delaySection
                    reverbSection
                    resetButton
                }
                .padding(16)
            }
        }
        .foregroundColor(.fg)
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
            settings = EffectSettings.preset(preset)
        }
    }

    // MARK: Seções

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
            settings = EffectSettings.preset(.none)
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
