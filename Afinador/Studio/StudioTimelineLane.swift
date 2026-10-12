import SwiftUI

// MARK: - Cabeçalho fixo de uma faixa (coluna da esquerda)

struct StudioTimelineLaneHeader: View, Equatable {
    let track: StudioTrack
    let index: Int
    let isArmed: Bool
    /// false com o transporte andando: não deixa trocar a faixa armada.
    let canArm: Bool
    let onArm: () -> Void
    let onToggleMute: () -> Void
    let onToggleSolo: () -> Void
    let onToggleEffects: () -> Void
    let onOpen: () -> Void

    nonisolated static func == (lhs: StudioTimelineLaneHeader, rhs: StudioTimelineLaneHeader) -> Bool {
        lhs.track == rhs.track && lhs.index == rhs.index
            && lhs.isArmed == rhs.isArmed && lhs.canArm == rhs.canArm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                armButton
                nameButton
            }
            HStack(spacing: 5) {
                StudioTimelineMiniChip(title: "M", isOn: track.isMuted, onColor: .off, action: onToggleMute)
                    .accessibilityLabel(track.isMuted ? "Tirar \(track.name) do mudo" : "Deixar \(track.name) mudo")
                StudioTimelineMiniChip(title: "S", isOn: track.isSolo, onColor: .brass, action: onToggleSolo)
                    .accessibilityLabel(track.isSolo ? "Desligar solo de \(track.name)" : "Solo: ouvir só \(track.name)")
                fxChip
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isArmed ? Color.off.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line).frame(height: 1)
        }
        .opacity(track.isMuted ? 0.65 : 1)
    }

    /// FX: liga/desliga todos os efeitos e a afinação da faixa (ajustes ficam guardados).
    private var fxChip: some View {
        let has: Bool = track.hasEffects
        let on: Bool = has && track.effectsOn
        return Button(action: onToggleEffects) {
            Text("FX")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 30, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.brass : Color.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.brass : Color.line))
                .foregroundColor(on ? Color.bg : (has ? Color.fg : Color.muted.opacity(0.6)))
                .overlay(alignment: .center) {
                    if has && !track.effectsOn {
                        Rectangle()
                            .fill(Color.off)
                            .frame(width: 22, height: 1.5)
                            .rotationEffect(.degrees(-20))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!has)
        .accessibilityLabel(!has ? "Sem efeitos nesta faixa"
                            : (track.effectsOn ? "Desligar efeitos de \(track.name)" : "Ligar efeitos de \(track.name)"))
    }

    private var armButton: some View {
        Button(action: onArm) {
            ZStack {
                Circle()
                    .stroke(Color.off, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(isArmed ? Color.off : Color.clear)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canArm)
        .opacity(canArm ? 1 : 0.5)
        .accessibilityLabel(isArmed ? "\(track.name) armada para gravar" : "Armar \(track.name) para gravar")
        .accessibilityHint(isArmed ? "Toque para desarmar; a próxima gravação cria uma faixa nova" : "A próxima gravação entra nesta faixa")
    }

    private var nameButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 3) {
                Text(track.name)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.muted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Faixa \(index), \(track.name). Abrir ajustes")
    }
}

/// Botão M/S compacto da coluna de faixas.
struct StudioTimelineMiniChip: View {
    let title: String
    let isOn: Bool
    let onColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? onColor : Color.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isOn ? onColor : Color.line))
                .foregroundColor(isOn ? Color.bg : Color.fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Uma faixa na linha do tempo (clips posicionados no tempo)

struct StudioTimelineLane: View, Equatable {
    /// Só para carregar formas de onda (não observado: a faixa não redesenha a cada tique).
    let studio: StudioEngine
    let track: StudioTrack
    let metrics: StudioTimelineMetrics
    let contentWidth: CGFloat
    let isArmed: Bool
    let selectedClipID: UUID?
    let canEdit: Bool
    let onSeek: (Double) -> Void
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Double) -> Void
    let onDragActive: (Bool) -> Void

    nonisolated static func == (lhs: StudioTimelineLane, rhs: StudioTimelineLane) -> Bool {
        lhs.track == rhs.track && lhs.metrics == rhs.metrics
            && lhs.contentWidth == rhs.contentWidth && lhs.isArmed == rhs.isArmed
            && lhs.selectedClipID == rhs.selectedClipID && lhs.canEdit == rhs.canEdit
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            tapArea
            armedTint
            ForEach(track.clips) { clip in
                StudioTimelineClipView(
                    studio: studio,
                    clip: clip,
                    isImported: track.isImported,
                    isMuted: track.isMuted,
                    metrics: metrics,
                    isSelected: clip.id == selectedClipID,
                    canDrag: canEdit && clip.id == selectedClipID,
                    onSelect: { onSelect(clip.id) },
                    onMove: { newOffset in onMove(clip.id, newOffset) },
                    onDragActive: onDragActive
                )
                .equatable()
            }
            bottomLine
        }
        .frame(width: contentWidth, height: StudioTimelineLayout.laneHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linha do tempo de \(track.name)")
    }

    /// Área vazia da faixa: toque = mover a cabeça para ali (e tirar a seleção).
    private var tapArea: some View {
        Color.clear
            .frame(width: contentWidth, height: StudioTimelineLayout.laneHeight)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                onSeek(metrics.time(location.x))
            }
    }

    @ViewBuilder
    private var armedTint: some View {
        if isArmed {
            Color.off.opacity(0.07)
                .frame(width: metrics.windowWidth, height: StudioTimelineLayout.laneHeight)
                .offset(x: metrics.windowStart)
                .allowsHitTesting(false)
        }
    }

    private var bottomLine: some View {
        Rectangle()
            .fill(Color.line)
            .frame(width: metrics.windowWidth, height: 1)
            .offset(x: metrics.windowStart, y: StudioTimelineLayout.laneHeight - 1)
            .allowsHitTesting(false)
    }
}

// MARK: - Um clip (trecho de áudio) com forma de onda

/// Pedaço do clip que cai dentro da janela de desenho (em pontos).
struct StudioClipPiece: Equatable {
    /// x do pedaço no conteúdo da linha do tempo.
    var minX: CGFloat
    var width: CGFloat
    /// Onde o pedaço começa dentro do clip (0 = começo do clip).
    var localStart: CGFloat
}

struct StudioTimelineClipView: View, Equatable {
    let studio: StudioEngine
    let clip: StudioClip
    let isImported: Bool
    let isMuted: Bool
    let metrics: StudioTimelineMetrics
    let isSelected: Bool
    let canDrag: Bool
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onDragActive: (Bool) -> Void

    @State private var peaks: [Float] = []
    @State private var peaksKey: String = ""
    @GestureState private var dragX: CGFloat = 0
    @GestureState private var isDragging: Bool = false

    nonisolated static func == (lhs: StudioTimelineClipView, rhs: StudioTimelineClipView) -> Bool {
        lhs.clip == rhs.clip && lhs.isImported == rhs.isImported && lhs.isMuted == rhs.isMuted
            && lhs.metrics == rhs.metrics && lhs.isSelected == rhs.isSelected && lhs.canDrag == rhs.canDrag
    }

    // MARK: Geometria

    private var clipX: CGFloat { metrics.x(clip.offset) }
    private var clipWidth: CGFloat { max(metrics.x(clip.duration), 2) }
    private var clipHeight: CGFloat { StudioTimelineLayout.laneHeight - StudioTimelineLayout.clipInset * 2 }

    /// Offset (s) mostrado enquanto arrasta, já "grudado" na batida.
    private var previewOffset: Double {
        guard isDragging else { return clip.offset }
        let raw: Double = clip.offset + Double(dragX / max(metrics.pps, 1))
        return metrics.snap(raw)
    }

    private var piece: StudioClipPiece? {
        let startX: CGFloat = metrics.x(previewOffset)
        let endX: CGFloat = startX + clipWidth
        let lo: CGFloat = max(startX, metrics.windowStart)
        let hi: CGFloat = min(endX, metrics.windowEnd)
        guard hi - lo >= 1 else { return nil }
        return StudioClipPiece(minX: lo, width: hi - lo, localStart: lo - startX)
    }

    /// Picos pedidos ao motor: potência de 2 (~1 pico a cada 3 pt) para não buscar de novo a cada passo de zoom.
    private var bucketCount: Int {
        // Não adianta pedir mais picos que o cache tem (200 por segundo).
        let wanted: Double = min(Double(clipWidth) / 3.0, max(clip.duration, 0) * 200.0)
        var n: Int = 32
        while Double(n) < wanted && n < 65536 {
            n *= 2
        }
        return n
    }

    private var waveKey: String {
        "\(clip.id.uuidString)|\(clip.fileName)|\(clip.fileStart)|\(clip.duration)|\(bucketCount)"
    }

    // MARK: Cores

    private var fillColor: Color {
        if isDragging { return Color.brass.opacity(0.35) }
        return isImported ? Color.muted.opacity(0.16) : Color.brass.opacity(0.18)
    }

    private var waveColor: Color {
        isImported ? Color.muted : Color.brass
    }

    private var strokeColor: Color {
        if isSelected { return Color.fg }
        return isImported ? Color.muted.opacity(0.55) : Color.brass.opacity(0.6)
    }

    // MARK: Corpo

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let piece = piece {
                pieceView(piece)
            }
        }
        .task(id: waveKey) {
            await loadPeaks()
        }
        .onChange(of: isDragging) { active in
            onDragActive(active)
        }
    }

    private func pieceView(_ piece: StudioClipPiece) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(fillColor)
            StudioWaveformShape(peaks: peaks, clipWidth: clipWidth, localStart: piece.localStart)
                .fill(waveColor.opacity(isMuted ? 0.4 : 0.9))
                .padding(.vertical, 5)
            if piece.localStart < 1 && isImported {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.muted)
                    .padding(4)
            }
        }
        .frame(width: piece.width, height: clipHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(strokeColor, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .gesture(moveGesture, including: canDrag ? .all : .none)
        .offset(x: piece.minX, y: StudioTimelineLayout.clipInset)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var accessibilityText: String {
        let kind: String = isImported ? "Trecho importado" : "Trecho gravado"
        return "\(kind), de \(StudioUIFormat.spokenTime(clip.offset)) a \(StudioUIFormat.spokenTime(clip.end))"
    }

    /// Toque longo e arraste (só no clip selecionado, com o transporte parado). Solta = moveClip.
    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($dragX) { value, state, _ in
                if case .second(true, let drag?) = value {
                    state = drag.translation.width
                }
            }
            .updating($isDragging) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                let raw: Double = clip.offset + Double(drag.translation.width / max(metrics.pps, 1))
                let target: Double = metrics.snap(raw)
                if abs(target - clip.offset) > 0.0005 {
                    onMove(target)
                }
            }
    }

    private func loadPeaks() async {
        let key: String = waveKey
        guard key != peaksKey else { return }
        let target: StudioClip = clip
        let buckets: Int = bucketCount
        let result: [Float] = await studio.waveform(for: target, buckets: buckets)
        if Task.isCancelled { return }
        peaks = result
        peaksKey = key
    }
}

// MARK: - Forma de onda (picos 0…1, espelhada no centro)

struct StudioWaveformShape: Shape {
    let peaks: [Float]
    /// Largura total do clip (pt); os picos cobrem o clip inteiro.
    let clipWidth: CGFloat
    /// Onde este pedaço começa dentro do clip (pt).
    let localStart: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY: CGFloat = rect.midY
        guard !peaks.isEmpty, clipWidth > 0 else {
            path.addRect(CGRect(x: 0, y: midY - 0.5, width: rect.width, height: 1))
            return path
        }
        let count: Int = peaks.count
        let step: CGFloat = 2
        var x: CGFloat = 0
        while x < rect.width {
            let globalX: CGFloat = localStart + x
            var index: Int = Int(globalX / clipWidth * CGFloat(count))
            index = min(max(index, 0), count - 1)
            let raw: Float = peaks[index]
            let amplitude: CGFloat = CGFloat(raw.isFinite ? min(max(raw, 0), 1) : 0)
            let barHeight: CGFloat = max(1, amplitude * rect.height)
            path.addRect(CGRect(x: x, y: midY - barHeight / 2, width: 1.4, height: barHeight))
            x += step
        }
        return path
    }
}
