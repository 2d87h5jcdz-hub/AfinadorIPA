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

    private var inTune: Bool { tuner.frequency != nil && abs(tuner.cents) <= 5 }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
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
        .foregroundColor(.fg)
        .onAppear { tuner.start() }
        .onDisappear { tuner.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Afina").foregroundColor(.fg) + Text("dor").foregroundColor(.brass))
                .font(.system(size: 24, weight: .heavy, design: .serif))
            Spacer()
            Text(tuner.running ? "OUVINDO" : "MICROFONE DESLIGADO")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(tuner.running ? .ok : .muted)
        }
    }

    private var dial: some View {
        VStack(spacing: 4) {
            GaugeView(cents: tuner.frequency == nil ? 0 : tuner.cents, inTune: inTune)
                .frame(height: 170)

            HStack(alignment: .top, spacing: 2) {
                Text(tuner.targetMidi.map { Note.name($0) } ?? "–")
                    .font(.system(size: 92, weight: .heavy, design: .serif))
                if let m = tuner.targetMidi {
                    Text("\(Note.octave(m))")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundColor(.muted)
                        .padding(.top, 12)
                }
            }
            .foregroundColor(inTune ? .ok : .fg)
            .padding(.top, -30)

            HStack(spacing: 22) {
                readout(tuner.frequency.map { String(format: "%.1f", $0) } ?? "—", "Hz")
                readout(tuner.frequency == nil ? "—" : (tuner.cents > 0 ? "+\(tuner.cents)" : "\(tuner.cents)"), "cents")
            }

            Text(hint)
                .font(.system(size: 15))
                .foregroundColor(hintColor)
                .padding(.top, 8)

            if tuner.permissionDenied {
                Text("Libere o microfone em Ajustes › Afinador.")
                    .font(.footnote).foregroundColor(.off).padding(.top, 4)
            }
        }
        .padding(.vertical, 18)
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
        guard tuner.frequency != nil else { return "Toque uma corda" }
        if inTune { return "Afinada ✓" }
        return tuner.cents < 0 ? "Baixa · aperte a tarraxa" : "Alta · afrouxe a tarraxa"
    }

    private var hintColor: Color {
        guard tuner.frequency != nil else { return .muted }
        return inTune ? .ok : .off
    }

    private var modeRow: some View {
        HStack {
            Picker("Modo", selection: $tuner.autoMode) {
                Text("Automático").tag(true)
                Text("Por corda").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 230)
            Spacer()
            Text("segure = ouvir")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.muted)
        }
    }

    private var strings: some View {
        HStack(spacing: 8) {
            ForEach(Array(tuner.tuning.midi.enumerated()), id: \.offset) { i, m in
                let active = tuner.autoMode ? tuner.stringIndex == i : tuner.manualIndex == i
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
                .onTapGesture { tuner.manualIndex = i }
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

struct GaugeView: View {
    let cents: Int
    let inTune: Bool

    private var needleColor: Color { inTune ? Color.ok : Color.brass }

    private var angle: Double {
        let c = Double(max(-50, min(50, cents)))
        return c / 50.0 * 60.0
    }

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 10)
            let radius: CGFloat = min(size.width / 2 - 24, size.height - 30)
            GaugeView.drawScale(ctx, center: center, radius: radius)
            GaugeView.drawNeedle(ctx, center: center, radius: radius, degrees: angle, color: needleColor)
        }
        .animation(.easeOut(duration: 0.12), value: cents)
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
