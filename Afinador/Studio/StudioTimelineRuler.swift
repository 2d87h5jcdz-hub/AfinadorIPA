import SwiftUI

// MARK: - Geometria da linha do tempo
//
// Tudo que é largo (régua, grade, formas de onda) só é desenhado dentro de uma "janela" em volta
// da área visível (windowStart…windowEnd, em pontos do conteúdo). Assim um zoom alto numa música
// longa não cria camadas gigantes (memória) e a régua não refaz centenas de compassos à toa.

enum StudioTimelineLayout {
    static let rulerHeight: CGFloat = 28
    static let laneHeight: CGFloat = 64
    static let headerWidth: CGFloat = 118
    static let clipInset: CGFloat = 5
    /// Tamanho do "passo" da janela de desenho (pontos). A janela cobre a página anterior,
    /// a atual e as duas seguintes, mais a largura visível.
    static let renderPage: CGFloat = 768
    static let minPPS: CGFloat = 20
    static let maxPPS: CGFloat = 300
    static let defaultPPS: CGFloat = 60
}

/// Valores (sem referência ao motor) que as subviews usam para posicionar coisas no tempo.
struct StudioTimelineMetrics: Equatable {
    /// Pontos por segundo (zoom).
    var pps: CGFloat
    /// Duração de um tempo (s) = 60 / bpm.
    var beatLength: Double
    var beatsPerBar: Int
    /// Janela de desenho, em pontos do conteúdo.
    var windowStart: CGFloat
    var windowEnd: CGFloat

    var windowWidth: CGFloat { max(windowEnd - windowStart, 1) }
    var barLength: Double { beatLength * Double(max(beatsPerBar, 1)) }

    func x(_ t: Double) -> CGFloat {
        let safe: Double = t.isFinite ? t : 0
        return CGFloat(safe) * pps
    }

    func time(_ x: CGFloat) -> Double {
        let safeX: CGFloat = max(x, 0)
        return Double(safeX / max(pps, 1))
    }

    /// Arredonda para o tempo (batida) mais próximo; nunca negativo.
    func snap(_ t: Double) -> Double {
        guard beatLength > 0.0001, t.isFinite else { return max(0, t.isFinite ? t : 0) }
        let n: Double = (t / beatLength).rounded()
        return max(0, n * beatLength)
    }

    /// De quantos em quantos compassos escrever o número (para não amontoar no zoom baixo).
    var barLabelEvery: Int {
        let barWidth: CGFloat = x(barLength)
        var every: Int = 1
        while barWidth * CGFloat(every) < 34 && every < 512 {
            every *= 2
        }
        return every
    }

    /// Compassos (índice 0-based) que caem dentro da janela.
    var visibleBars: ClosedRange<Int>? {
        let bar: Double = barLength
        guard bar > 0.0001, pps > 0 else { return nil }
        let startTime: Double = Double(windowStart / pps)
        let endTime: Double = Double(windowEnd / pps)
        let first: Int = max(0, Int((startTime / bar).rounded(.down)))
        let last: Int = Int((endTime / bar).rounded(.up))
        guard last >= first else { return nil }
        return first...last
    }
}

// MARK: - Régua (compassos e tempos)

struct StudioTimelineRuler: View, Equatable {
    let metrics: StudioTimelineMetrics
    let contentWidth: CGFloat
    let onSeek: (Double) -> Void

    nonisolated static func == (lhs: StudioTimelineRuler, rhs: StudioTimelineRuler) -> Bool {
        lhs.metrics == rhs.metrics && lhs.contentWidth == rhs.contentWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Canvas { context, size in
                StudioTimelineRuler.draw(in: &context, size: size, metrics: metrics)
            }
            .frame(width: metrics.windowWidth, height: StudioTimelineLayout.rulerHeight)
            .offset(x: metrics.windowStart)
            .allowsHitTesting(false)
        }
        .frame(width: contentWidth, height: StudioTimelineLayout.rulerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            onSeek(metrics.time(location.x))
        }
        .accessibilityElement()
        .accessibilityLabel("Régua de compassos")
        .accessibilityHint("Toque para levar a cabeça de reprodução até ali")
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, metrics: StudioTimelineMetrics) {
        let height: CGFloat = size.height
        var bottom = Path()
        bottom.addRect(CGRect(x: 0, y: height - 1, width: size.width, height: 1))
        context.fill(bottom, with: .color(Color.line))

        guard let bars = metrics.visibleBars else { return }
        let every: Int = metrics.barLabelEvery
        let beatWidth: CGFloat = metrics.x(metrics.beatLength)
        let beats: Int = max(metrics.beatsPerBar, 1)

        var majorTicks = Path()
        var minorTicks = Path()
        for bar in bars {
            let barX: CGFloat = metrics.x(Double(bar) * metrics.barLength) - metrics.windowStart
            if bar % every == 0 {
                majorTicks.addRect(CGRect(x: barX, y: 6, width: 1, height: height - 6))
                let label = Text("\(bar + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.muted)
                context.draw(label, at: CGPoint(x: barX + 3, y: 3), anchor: .topLeading)
            } else {
                minorTicks.addRect(CGRect(x: barX, y: height - 9, width: 1, height: 9))
            }
            if beatWidth >= 9 && every == 1 && beats > 1 {
                for beat in 1..<beats {
                    let beatX: CGFloat = barX + beatWidth * CGFloat(beat)
                    minorTicks.addRect(CGRect(x: beatX, y: height - 5, width: 1, height: 5))
                }
            }
        }
        context.fill(majorTicks, with: .color(Color.muted.opacity(0.8)))
        context.fill(minorTicks, with: .color(Color.muted.opacity(0.45)))
    }
}

// MARK: - Grade atrás das faixas (linhas de compasso e tempo)

struct StudioTimelineGrid: View, Equatable {
    let metrics: StudioTimelineMetrics
    let height: CGFloat

    nonisolated static func == (lhs: StudioTimelineGrid, rhs: StudioTimelineGrid) -> Bool {
        lhs.metrics == rhs.metrics && lhs.height == rhs.height
    }

    var body: some View {
        Canvas { context, size in
            StudioTimelineGrid.draw(in: &context, size: size, metrics: metrics)
        }
        .frame(width: metrics.windowWidth, height: max(height, 1))
        .offset(x: metrics.windowStart)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, metrics: StudioTimelineMetrics) {
        guard let bars = metrics.visibleBars else { return }
        let every: Int = metrics.barLabelEvery
        let beatWidth: CGFloat = metrics.x(metrics.beatLength)
        let beats: Int = max(metrics.beatsPerBar, 1)
        var barLines = Path()
        var beatLines = Path()
        for bar in bars {
            let barX: CGFloat = metrics.x(Double(bar) * metrics.barLength) - metrics.windowStart
            if bar % every == 0 {
                barLines.addRect(CGRect(x: barX, y: 0, width: 1, height: size.height))
            }
            if beatWidth >= 16 && every == 1 && beats > 1 {
                for beat in 1..<beats {
                    let beatX: CGFloat = barX + beatWidth * CGFloat(beat)
                    beatLines.addRect(CGRect(x: beatX, y: 0, width: 1, height: size.height))
                }
            }
        }
        context.fill(barLines, with: .color(Color.line.opacity(0.9)))
        context.fill(beatLines, with: .color(Color.line.opacity(0.4)))
    }
}

// MARK: - Cabeça de reprodução + clip "ao vivo" durante a gravação
//
// É a única peça da linha do tempo que depende de `position`; fica numa view pequena para que
// as faixas e as formas de onda não sejam redesenhadas a cada atualização da posição.

@MainActor
struct StudioTimelinePlayhead: View {
    @ObservedObject var studio: StudioEngine
    let pps: CGFloat
    let totalHeight: CGFloat
    /// Faixa (índice visual) onde a gravação está entrando; nil fora da gravação.
    let liveLaneIndex: Int?

    private var isRecording: Bool { studio.transport == .recording }

    private var headX: CGFloat {
        let p: Double = studio.position.isFinite ? max(studio.position, 0) : 0
        return CGFloat(p) * pps
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            liveClip
            Rectangle()
                .fill(isRecording ? Color.off : Color.fg)
                .frame(width: 2, height: max(totalHeight, 1))
                .offset(x: headX - 1)
            headMarker
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var headMarker: some View {
        Circle()
            .fill(isRecording ? Color.off : Color.fg)
            .frame(width: 9, height: 9)
            .offset(x: headX - 4.5, y: StudioTimelineLayout.rulerHeight - 9)
    }

    /// Retângulo do clip sendo gravado (do começo da tomada até a cabeça) na faixa de destino.
    private var liveRect: CGRect? {
        guard isRecording, let lane = liveLaneIndex, let start = studio.recordingStart else { return nil }
        let startX: CGFloat = CGFloat(max(start, 0)) * pps
        // Limita a largura desenhada (gravação longa em zoom alto) — o começo fica fora da tela.
        let drawnStart: CGFloat = max(startX, headX - 3000)
        let width: CGFloat = max(headX - drawnStart, 1)
        let laneTop: CGFloat = StudioTimelineLayout.rulerHeight + CGFloat(lane) * StudioTimelineLayout.laneHeight
        let top: CGFloat = laneTop + StudioTimelineLayout.clipInset
        let height: CGFloat = StudioTimelineLayout.laneHeight - StudioTimelineLayout.clipInset * 2
        return CGRect(x: drawnStart, y: top, width: width, height: height)
    }

    @ViewBuilder
    private var liveClip: some View {
        if let rect = liveRect {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.off.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.off, lineWidth: 1.5))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}
