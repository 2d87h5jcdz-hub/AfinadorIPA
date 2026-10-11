import SwiftUI

// MARK: - Transporte fixo no rodapé: tempo, linha do tempo, tocar/parar/gravar

@MainActor
struct StudioTransportBar: View {
    @ObservedObject var studio: StudioEngine
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    // MARK: Estado derivado

    private var isStopped: Bool { studio.transport == .stopped }
    private var isPlaying: Bool { studio.transport == .playing }
    private var isRecording: Bool { studio.transport == .recording }
    private var countInBeat: Int? {
        if case .countIn(let beat) = studio.transport { return beat }
        return nil
    }
    private var isArmed: Bool { isRecording || countInBeat != nil }

    private var timelineLength: Double {
        max(studio.duration, studio.position, 1.0)
    }

    private var beatsPerBar: Int { max(studio.project?.beatsPerBar ?? 4, 1) }

    private var barBeatText: String {
        let bpm: Double = max(studio.project?.bpm ?? 90, 1)
        let beatLength: Double = 60.0 / bpm
        let shown: Double = scrubbing ? scrubValue : studio.position
        let totalBeats: Int = Int(max(shown, 0) / beatLength)
        let bar: Int = totalBeats / beatsPerBar + 1
        let beat: Int = totalBeats % beatsPerBar + 1
        return "compasso \(bar) · tempo \(beat)"
    }

    // MARK: Corpo

    var body: some View {
        VStack(spacing: 10) {
            statusRow
            if let beat = countInBeat {
                StudioCountInDisplay(beat: beat, beatsPerBar: beatsPerBar)
            } else {
                timeline
            }
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            Color.panel
                .overlay(alignment: .top) {
                    Rectangle().fill(isArmed ? Color.off : Color.line).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(StudioUIFormat.time(scrubbing ? scrubValue : studio.position))
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .accessibilityLabel("Posição \(StudioUIFormat.spokenTime(studio.position))")
            Text("/ \(StudioUIFormat.time(studio.duration))")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.muted)
                .accessibilityLabel("de \(StudioUIFormat.spokenTime(studio.duration))")
            Spacer(minLength: 4)
            StudioStatusPill(transport: studio.transport)
        }
    }

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(value: scrubBinding, in: 0...timelineLength, onEditingChanged: { editing in
                if !editing && scrubbing {
                    studio.seek(to: scrubValue)
                    scrubbing = false
                }
            })
            .tint(Color.brass)
            .disabled(isArmed)
            .accessibilityLabel("Linha do tempo")
            .accessibilityValue(StudioUIFormat.spokenTime(studio.position))
            HStack {
                Text(barBeatText)
                Spacer()
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.muted)
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding<Double>(
            get: { scrubbing ? scrubValue : min(studio.position, timelineLength) },
            set: { newValue in
                scrubValue = newValue
                scrubbing = true
            }
        )
    }

    // MARK: Botões

    private var buttons: some View {
        HStack(spacing: 16) {
            rewindButton
            playButton
            recordButton
        }
    }

    private var rewindButton: some View {
        Button {
            studio.seek(to: 0)
        } label: {
            Image(systemName: "backward.end.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.bg))
                .overlay(Circle().stroke(Color.line))
                .foregroundColor(.fg)
        }
        .disabled(isArmed)
        .opacity(isArmed ? 0.4 : 1)
        .accessibilityLabel("Voltar para o início")
    }

    private var playButton: some View {
        Button {
            if isStopped {
                studio.play(from: nil)
            } else {
                studio.stop()
            }
        } label: {
            Label(isStopped ? "Tocar" : "Parar", systemImage: isStopped ? "play.fill" : "stop.fill")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Capsule().fill(isStopped ? Color.brass : Color.fg))
                .foregroundColor(.bg)
        }
        .accessibilityLabel(isStopped ? "Tocar" : "Parar")
    }

    private var recordButton: some View {
        Button {
            if isArmed {
                studio.stop()
            } else {
                if isPlaying { studio.stop() }
                studio.record()
            }
        } label: {
            StudioRecordGlyph(isArmed: isArmed)
        }
        .accessibilityLabel(isArmed ? "Parar gravação" : "Gravar nova faixa")
        .accessibilityHint(isArmed ? "" : "As outras faixas tocam enquanto você grava")
    }
}

// MARK: - Peças do transporte

struct StudioRecordGlyph: View {
    let isArmed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.bg)
                .overlay(Circle().stroke(isArmed ? Color.off : Color.line, lineWidth: isArmed ? 3 : 1))
            if isArmed {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.off)
                    .frame(width: 22, height: 22)
            } else {
                Circle()
                    .fill(Color.off)
                    .frame(width: 30, height: 30)
            }
        }
        .frame(width: 64, height: 64)
    }
}

struct StudioStatusPill: View {
    let transport: TransportState

    private var text: String {
        switch transport {
        case .stopped: return "PARADO"
        case .playing: return "TOCANDO"
        case .countIn: return "CONTAGEM"
        case .recording: return "GRAVANDO"
        }
    }

    private var color: Color {
        switch transport {
        case .stopped: return .muted
        case .playing: return .ok
        case .countIn: return .brass
        case .recording: return .off
        }
    }

    private var blinks: Bool { transport == .recording }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            pill(dotVisible: dotVisible(at: context.date))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.lowercased())
    }

    private func dotVisible(at date: Date) -> Bool {
        guard blinks else { return true }
        let halfSeconds: Int = Int(date.timeIntervalSinceReferenceDate * 2)
        return halfSeconds % 2 == 0
    }

    private func pill(dotVisible: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(dotVisible ? 1 : 0.15)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().stroke(color.opacity(0.6)))
    }
}

/// Mostra a contagem antes da gravação: número grande + bolinhas do compasso.
struct StudioCountInDisplay: View {
    let beat: Int
    let beatsPerBar: Int

    var body: some View {
        HStack(spacing: 16) {
            Text("\(beat)")
                .font(.system(size: 54, weight: .heavy, design: .serif))
                .monospacedDigit()
                .foregroundColor(.brass)
                .frame(minWidth: 50)
            VStack(alignment: .leading, spacing: 8) {
                Text("Prepare-se…")
                    .font(.system(size: 15, weight: .semibold))
                dots
            }
            Spacer(minLength: 0)
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Contagem: \(beat)")
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(1...max(beatsPerBar, 1), id: \.self) { i in
                Circle()
                    .fill(i == beat ? (i == 1 ? Color.ok : Color.brass) : Color.bg)
                    .overlay(Circle().stroke(i == 1 ? Color.brass : Color.line))
                    .frame(width: 16, height: 16)
            }
        }
    }
}
