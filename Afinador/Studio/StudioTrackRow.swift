import SwiftUI

// MARK: - Uma faixa (camada) do projeto

struct StudioTrackRow: View {
    let track: StudioTrack
    let index: Int
    let level: Float
    /// true durante gravação/contagem: não deixa apagar nem renomear.
    let isLocked: Bool
    let onUpdate: (StudioTrack) -> Void
    let onEffects: () -> Void
    let onDelete: () -> Void

    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            StudioMeterBar(level: track.isMuted ? 0 : level, height: 6)
                .accessibilityHidden(true)
            volumeRow
            panRow
            buttonsRow
        }
        .studioPanel(padding: 12, stroke: track.isSolo ? Color.brass : Color.line)
        .opacity(track.isMuted ? 0.6 : 1)
        .alert("Renomear faixa", isPresented: $showRename) {
            TextField("Nome", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { commitRename() }
        }
    }

    // MARK: Linhas

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.line))
                .accessibilityHidden(true)
            Text(track.name)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if track.isImported {
                importedBadge
            }
            Spacer(minLength: 4)
            Text(StudioUIFormat.time(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.muted)
                .accessibilityLabel("Duração \(StudioUIFormat.spokenTime(track.duration))")
            menu
        }
    }

    private var importedBadge: some View {
        Text("IMPORTADA")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.line))
            .foregroundColor(.muted)
            .accessibilityLabel("Faixa importada")
    }

    private var menu: some View {
        Menu {
            Button {
                renameText = track.name
                showRename = true
            } label: { Label("Renomear", systemImage: "pencil") }
            Button(action: onEffects) { Label("Efeitos", systemImage: "slider.horizontal.3") }
            Button(role: .destructive, action: onDelete) { Label("Apagar faixa", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundColor(.muted)
                .frame(width: 40, height: 40)
        }
        .disabled(isLocked)
        .accessibilityLabel("Opções da faixa \(track.name)")
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundColor(.muted)
                .frame(width: 22)
                .accessibilityHidden(true)
            Slider(value: volumeBinding, in: 0...1.5)
                .tint(Color.brass)
                .accessibilityLabel("Volume de \(track.name)")
                .accessibilityValue("\(volumePercent) por cento")
            Text("\(volumePercent)%")
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.muted)
                .frame(width: 46, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var panRow: some View {
        HStack(spacing: 10) {
            Text("E")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.muted)
                .frame(width: 22)
                .accessibilityHidden(true)
            Slider(value: panBinding, in: -1...1)
                .tint(Color.muted)
                .accessibilityLabel("Pan de \(track.name)")
                .accessibilityValue(spokenPan)
            Button {
                var t = track
                t.pan = 0
                onUpdate(t)
            } label: {
                Text(panLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.muted)
                    .frame(width: 46, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Centralizar pan")
        }
    }

    private var buttonsRow: some View {
        HStack(spacing: 8) {
            StudioChip(title: "M", isOn: track.isMuted, onColor: .off) {
                var t = track
                t.isMuted.toggle()
                onUpdate(t)
            }
            .accessibilityLabel(track.isMuted ? "Tirar do mudo" : "Deixar mudo")
            StudioChip(title: "S", isOn: track.isSolo, onColor: .brass) {
                var t = track
                t.isSolo.toggle()
                onUpdate(t)
            }
            .accessibilityLabel(track.isSolo ? "Desligar solo" : "Solo: ouvir só esta faixa")
            Spacer(minLength: 4)
            StudioChip(title: track.effects.preset.title,
                       systemImage: "slider.horizontal.3",
                       isOn: false,
                       action: onEffects)
                .lineLimit(1)
                .accessibilityLabel("Efeitos de \(track.name): \(track.effects.preset.title)")
        }
    }

    // MARK: Bindings e textos

    private var volumeBinding: Binding<Float> {
        Binding<Float>(
            get: { track.volume },
            set: { newValue in
                var t = track
                t.volume = newValue
                onUpdate(t)
            }
        )
    }

    private var panBinding: Binding<Float> {
        Binding<Float>(
            get: { track.pan },
            set: { newValue in
                var t = track
                // "gruda" no centro
                t.pan = abs(newValue) < 0.04 ? 0 : newValue
                onUpdate(t)
            }
        )
    }

    private var volumePercent: Int { Int((track.volume * 100).rounded()) }

    private var panLabel: String {
        let p: Int = Int((track.pan * 100).rounded())
        if p < 0 { return "E\(-p)" }
        if p > 0 { return "D\(p)" }
        return "C"
    }

    private var spokenPan: String {
        let p: Int = Int((track.pan * 100).rounded())
        if p < 0 { return "\(-p) por cento à esquerda" }
        if p > 0 { return "\(p) por cento à direita" }
        return "centro"
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var t = track
        t.name = name
        onUpdate(t)
    }
}
