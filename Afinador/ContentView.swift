import SwiftUI

extension Color {
    static let bg = Color(red: 0.086, green: 0.071, blue: 0.059)
    static let panel = Color(red: 0.129, green: 0.106, blue: 0.086)
    static let line = Color(red: 0.227, green: 0.188, blue: 0.161)
    static let fg = Color(red: 0.953, green: 0.922, blue: 0.882)
    static let muted = Color(red: 0.659, green: 0.600, blue: 0.541)
    static let brass = Color(red: 0.851, green: 0.643, blue: 0.255)
    static let ok = Color(red: 0.373, green: 0.812, blue: 0.541)
    static let off = Color(red: 0.886, green: 0.412, blue: 0.290)
}

struct TunerView: View {
    @ObservedObject var tuner: TunerEngine
    @State private var showAbout = false
    @Environment(\.verticalSizeClass) private var vSize

    private var inTune: Bool { tuner.frequency != nil && abs(tuner.cents) <= 5 }
    /// iPhone deitado: altura compacta.
    private var isLandscape: Bool { vSize == .compact }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .foregroundColor(.fg)
        .onAppear { tuner.start() }
        .onDisappear { tuner.stop() }
    }

    private var portraitLayout: some View {
        VStack(spacing: 18) {
            header
            dial
            modeRow
            strings
            Spacer(minLength: 0)
            settings
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Paisagem: mostrador à esquerda, controles à direita (com rolagem se faltar altura).
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView(showsIndicators: false) {
                dial
            }
            .frame(maxWidth: .infinity)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    modeRow
                    strings
                    settings
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // medidas do mostrador (menores na paisagem para caber na altura)
    private var gaugeHeight: CGFloat { isLandscape ? 110 : 170 }
    private var noteFontSize: CGFloat { isLandscape ? 64 : 92 }
    private var octaveFontSize: CGFloat { isLandscape ? 22 : 30 }
    private var dialVerticalPadding: CGFloat { isLandscape ? 10 : 18 }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Afina").foregroundColor(.fg) + Text("dor").foregroundColor(.brass))
                .font(.system(size: 24, weight: .heavy, design: .serif))
            Spacer()
            Text(tuner.running ? "OUVINDO" : "MICROFONE DESLIGADO")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(tuner.running ? .ok : .muted)
            Button {
                showAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17))
                    .foregroundColor(.muted)
            }
            .accessibilityLabel("Sobre o Pestana Estúdio")
            .sheet(isPresented: $showAbout) {
                AboutView(isWelcome: false)
            }
        }
    }

    private var dial: some View {
        VStack(spacing: 4) {
            GaugeView(cents: tuner.frequency == nil ? 0 : tuner.centsPrecise, inTune: inTune)
                .frame(height: gaugeHeight)

            HStack(alignment: .top, spacing: 2) {
                Text(tuner.targetMidi.map { Note.name($0) } ?? "–")
                    .font(.system(size: noteFontSize, weight: .heavy, design: .serif))
                if let m = tuner.targetMidi {
                    Text("\(Note.octave(m))")
                        .font(.system(size: octaveFontSize, weight: .semibold, design: .serif))
                        .foregroundColor(.muted)
                        .padding(.top, isLandscape ? 8 : 12)
                }
            }
            .foregroundColor(inTune ? .ok : .fg)
            .padding(.top, isLandscape ? -18 : -30)

            HStack(spacing: 22) {
                readout(tuner.frequency.map { String(format: "%.1f", $0) } ?? "—", "Hz")
                readout(tuner.frequency == nil ? "—" : (tuner.cents > 0 ? "+\(tuner.cents)" : "\(tuner.cents)"), "cents")
            }

            Text(hint)
                .font(.system(size: 15))
                .foregroundColor(hintColor)
                .padding(.top, isLandscape ? 4 : 8)

            if tuner.permissionDenied {
                Text("Libere o microfone em Ajustes › Afinador.")
                    .font(.footnote).foregroundColor(.off).padding(.top, 4)
            }
        }
        .padding(.vertical, dialVerticalPadding)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.line))
    }

    private func readout(_ value: String, _ unit: String) -> some View {
        (Text(value).foregroundColor(.fg) + Text(" \(unit)").foregroundColor(.muted))
            .font(.system(size: 14, design: .monospaced))
            .monospacedDigit()
    }

    private var hint: String {
        guard tuner.frequency != nil else {
            return tuner.mode == .chromatic ? "Toque qualquer nota" : "Toque uma corda"
        }
        if inTune { return "Afinada ✓" }
        return tuner.cents < 0 ? "Baixa · aperte a tarraxa" : "Alta · afrouxe a tarraxa"
    }

    private var hintColor: Color {
        guard tuner.frequency != nil else { return .muted }
        return inTune ? .ok : .off
    }

    private var modeRow: some View {
        HStack {
            Picker("Modo", selection: $tuner.mode) {
                Text("Livre").tag(TunerMode.chromatic)
                Text("Auto").tag(TunerMode.auto)
                Text("Por corda").tag(TunerMode.manual)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 250)
            Spacer()
            Text("segure = ouvir")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var strings: some View {
        HStack(spacing: 8) {
            ForEach(Array(tuner.tuning.midi.enumerated()), id: \.offset) { i, m in
                let active: Bool = tuner.mode == .manual ? tuner.manualIndex == i : tuner.stringIndex == i
                let done = tuner.tunedStrings.contains(i) && !active
                VStack(spacing: 2) {
                    Text(Note.name(m))
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text("\(6 - i)ª")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(done ? .ok : .muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(active ? Color.brass : (done ? Color.ok : Color.line), lineWidth: active ? 2 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    tuner.manualIndex = i
                    tuner.mode = .manual
                }
                .onLongPressGesture(minimumDuration: 0.35) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    tuner.playReference(i)
                }
            }
        }
    }

    private var settings: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Afinação").font(.caption).foregroundColor(.muted)
                Menu {
                    Picker("Afinação", selection: $tuner.tuning) {
                        ForEach(Tuning.all) { Text($0.name).tag($0) }
                    }
                } label: {
                    Text(tuner.tuning.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                        .foregroundColor(.fg)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("Lá central (A4)").font(.caption).foregroundColor(.muted)
                HStack(spacing: 8) {
                    stepButton("−") { tuner.a4 = max(415, tuner.a4 - 1) }
                    Text("\(Int(tuner.a4))")
                        .font(.system(size: 14, design: .monospaced)).monospacedDigit()
                    stepButton("+") { tuner.a4 = min(466, tuner.a4 + 1) }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            }
        }
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 18))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.line))
                .foregroundColor(.fg)
        }
    }
}

/// Ponteiro com "mola": persegue a leitura com amortecimento crítico, quadro a quadro,
/// como o ponteiro físico de um afinador (sem trancos e sem passar do ponto).
final class NeedleSpring: ObservableObject {
    private(set) var value: Double = 0
    private var velocity: Double = 0
    private var lastTime: Date?
    /// Rigidez da mola (rad/s): maior = mais rápido.
    private let omega: Double = 14

    func step(toward target: Double, at time: Date) -> Double {
        let dt = min(1.0 / 30.0, max(0, time.timeIntervalSince(lastTime ?? time)))
        lastTime = time
        // x'' = ω²(alvo − x) − 2ωx'  (amortecimento crítico)
        let accel = omega * omega * (target - value) - 2 * omega * velocity
        velocity += accel * dt
        value += velocity * dt
        return value
    }
}

struct GaugeView: View {
    let cents: Double
    let inTune: Bool
    @StateObject private var spring = NeedleSpring()

    private var needleColor: Color { inTune ? Color.ok : Color.brass }

    var body: some View {
        TimelineView(.animation) { context in
            let smoothed = spring.step(toward: max(-50, min(50, cents)), at: context.date)
            let angle = smoothed / 50.0 * 60.0
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 10)
                let radius: CGFloat = min(size.width / 2 - 24, size.height - 30)
                GaugeView.drawScale(ctx, center: center, radius: radius)
                GaugeView.drawNeedle(ctx, center: center, radius: radius, degrees: angle, color: needleColor)
            }
        }
    }

    static func point(_ center: CGPoint, _ radius: CGFloat, _ radians: Double) -> CGPoint {
        let x = center.x + CGFloat(sin(radians)) * radius
        let y = center.y - CGFloat(cos(radians)) * radius
        return CGPoint(x: x, y: y)
    }

    static func drawScale(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        var zone = Path()
        zone.addArc(center: center, radius: radius + 2,
                    startAngle: .degrees(-96), endAngle: .degrees(-84), clockwise: false)
        ctx.stroke(zone, with: .color(Color.ok.opacity(0.35)), lineWidth: 10)

        for c in stride(from: -50, through: 50, by: 5) {
            let major: Bool = c % 25 == 0
            let a: Double = Double(c) / 50.0 * 60.0 * Double.pi / 180.0
            let inner: CGFloat = radius - (major ? 16 : 9)
            var tick = Path()
            tick.move(to: point(center, inner, a))
            tick.addLine(to: point(center, radius, a))
            let color: Color = major ? Color.fg : Color.muted
            ctx.stroke(tick, with: .color(color), lineWidth: major ? 2 : 1)
            if major {
                let label: String = c > 0 ? "+\(c)" : "\(c)"
                let text = Text(label).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.muted)
                ctx.draw(text, at: point(center, radius + 14, a))
            }
        }
    }

    static func drawNeedle(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat, degrees: Double, color: Color) {
        let a: Double = degrees * Double.pi / 180.0
        var needle = Path()
        needle.move(to: center)
        needle.addLine(to: point(center, radius - 4, a))
        ctx.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let dot = Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        ctx.fill(dot, with: .color(color))
    }
}
