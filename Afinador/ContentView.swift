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

struct ContentView: View {
    @StateObject private var tuner = TunerEngine()

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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let center = CGPoint(x: w / 2, y: h - 10)
            let radius = min(w / 2 - 24, h - 30)
            ZStack {
                // zona afinada
                Path { p in
                    p.addArc(center: center, radius: radius + 2,
                             startAngle: .degrees(-90 - 6), endAngle: .degrees(-90 + 6), clockwise: false)
                }
                .stroke(Color.ok.opacity(0.35), lineWidth: 10)

                ForEach(Array(stride(from: -50, through: 50, by: 5)), id: \.self) { c in
                    let major = c % 25 == 0
                    let a = Double(c) / 50 * 60 * .pi / 180
                    let r1 = radius - (major ? 16 : 9)
                    Path { p in
                        p.move(to: CGPoint(x: center.x + sin(a) * r1, y: center.y - cos(a) * r1))
                        p.addLine(to: CGPoint(x: center.x + sin(a) * radius, y: center.y - cos(a) * radius))
                    }
                    .stroke(major ? Color.fg : Color.muted, lineWidth: major ? 2 : 1)
                    if major {
                        Text(c > 0 ? "+\(c)" : "\(c)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.muted)
                            .position(x: center.x + sin(a) * (radius + 14), y: center.y - cos(a) * (radius + 14))
                    }
                }

                Path { p in
                    p.move(to: center)
                    p.addLine(to: CGPoint(x: center.x, y: center.y - radius + 4))
                }
                .stroke(inTune ? Color.ok : Color.brass, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(Double(max(-50, min(50, cents))) / 50 * 60), anchor: UnitPoint(x: center.x / w, y: center.y / h))
                .animation(.easeOut(duration: 0.12), value: cents)

                Circle().fill(inTune ? Color.ok : Color.brass)
                    .frame(width: 14, height: 14)
                    .position(center)
            }
        }
    }
}
