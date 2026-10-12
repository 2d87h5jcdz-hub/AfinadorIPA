import SwiftUI

// MARK: - Seção "Afinação automática" na folha de efeitos de uma faixa

@MainActor
struct StudioPitchPanel: View {
    @ObservedObject var studio: StudioEngine
    let trackID: UUID

    private var track: StudioTrack? { studio.project?.tracks.first(where: { $0.id == trackID }) }
    private var pitch: PitchCorrection { track?.pitch ?? PitchCorrection() }
    private var progress: Double? { studio.pitchProgress[trackID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if track?.effectsOn == false {
                effectsOffBanner
            }
            pitchSection
        }
    }

    /// Aviso quando o botão FX da faixa está desligado (os ajustes aqui não soam até religar).
    private var effectsOffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .foregroundColor(.off)
            Text("Os efeitos desta faixa estão desligados (botão FX).")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Ligar") {
                guard var current = track else { return }
                current.effectsOn = true
                studio.updateTrack(current)
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.brass)
        }
        .studioPanel(padding: 12, stroke: Color.off.opacity(0.6))
    }

    private var pitchSection: some View {
        StudioEffectSection(title: "Afinação automática", systemImage: "tuningfork") {
            Toggle(isOn: binding(\.enabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Corrigir afinação da voz")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sutil: leva cada nota para o lugar e mantém vibrato e expressão. A gravação original não muda.")
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.brass)
            if pitch.enabled {
                keyRow
                if !pitch.isAuto {
                    scalePicker
                }
                StudioEffectSlider(label: "Intensidade", value: binding(\.strength), range: 0.3...1,
                                   text: "\(Int((pitch.strength * 100).rounded()))%")
                Text("Mais baixo soa mais natural; 100% leva a nota exatamente para o lugar.")
                    .font(.system(size: 11))
                    .foregroundColor(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
        }
    }

    private var keyRow: some View {
        HStack {
            Text("Tom")
                .font(.system(size: 13))
                .foregroundColor(.muted)
            Spacer()
            Menu {
                Picker("Tom", selection: binding(\.key)) {
                    Text("Automático (pela voz)").tag(-1)
                    ForEach(0..<12, id: \.self) { k in
                        Text(PitchCorrection.noteNames[k]).tag(k)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(keyLabel)
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.brass)
            }
        }
    }

    private var keyLabel: String {
        if pitch.isAuto {
            if let k = pitch.detectedKey {
                return "Auto · " + PitchCorrection.keyTitle(k, pitch.detectedScale ?? .major)
            }
            return "Automático"
        }
        return PitchCorrection.noteNames[max(0, min(11, pitch.key))]
    }

    private var scalePicker: some View {
        Picker("Escala", selection: binding(\.scale)) {
            ForEach(PitchScale.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var status: some View {
        if let value = progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: value)
                    .tint(Color.brass)
                Text("Afinando… \(Int((value * 100).rounded()))% (dá para continuar usando o app)")
                    .font(.system(size: 12))
                    .foregroundColor(.muted)
            }
        } else if pitch.signature != nil {
            Label("Pronto: a reprodução e a exportação já usam a voz afinada.", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundColor(.ok)
        } else {
            Text("Preparando…")
                .font(.system(size: 12))
                .foregroundColor(.muted)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PitchCorrection, Value>) -> Binding<Value> {
        Binding<Value>(
            get: { pitch[keyPath: keyPath] },
            set: { newValue in
                guard var current = track else { return }
                current.pitch[keyPath: keyPath] = newValue
                studio.updateTrack(current)
            }
        )
    }
}
