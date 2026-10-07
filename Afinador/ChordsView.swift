import SwiftUI

struct ChordsView: View {
    let a4: Double
    @AppStorage("chordRoot") private var root = 0
    @AppStorage("chordQuality") private var qualityId = "maj"
    @State private var voicingIndex = 0
    @State private var player = ChordPlayer()

    private var quality: ChordQuality {
        ChordQuality.all.first { $0.id == qualityId } ?? ChordQuality.all[0]
    }
    private var voicings: [Voicing] { ChordBook.voicings(root: root, quality: quality) }
    private var current: Voicing? {
        let v = voicings
        guard !v.isEmpty else { return nil }
        return v[min(voicingIndex, v.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Acordes")
                        .font(.system(size: 24, weight: .heavy, design: .serif))
                    rootGrid
                    qualityStrip
                    card
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .foregroundColor(.fg)
        .onChange(of: root) { _ in voicingIndex = 0 }
        .onChange(of: qualityId) { _ in voicingIndex = 0 }
    }

    private var rootGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(0..<12, id: \.self) { r in
                let selected = r == root
                Button { root = r } label: {
                    Text(ChordBook.rootNames[r])
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.brass : Color.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                        .foregroundColor(selected ? Color.bg : Color.fg)
                }
            }
        }
    }

    private var qualityStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChordQuality.all) { q in
                    let selected = q.id == qualityId
                    Button { qualityId = q.id } label: {
                        Text(q.suffix.isEmpty ? "Maior" : q.suffix)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(selected ? Color.line : Color.panel))
                            .overlay(Capsule().stroke(selected ? Color.brass : Color.line))
                            .foregroundColor(selected ? Color.fg : Color.muted)
                    }
                }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChordBook.name(root: root, quality: quality))
                        .font(.system(size: 44, weight: .heavy, design: .serif))
                    Text("\(ChordBook.solfege[root]) \(quality.label.lowercased())")
                        .font(.system(size: 14))
                        .foregroundColor(.muted)
                }
                Spacer()
                notesView
            }

            if let v = current {
                ChordDiagram(voicing: v)
                    .frame(height: 260)
                    .contentShape(Rectangle())
                    .onTapGesture { strum(v) }
                    .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                        if g.translation.width < -30 { nextVoicing(1) }
                        if g.translation.width > 30 { nextVoicing(-1) }
                    })
            }

            HStack {
                Button { nextVoicing(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }
                Spacer()
                Text("Posição \(min(voicingIndex, voicings.count - 1) + 1) de \(voicings.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.muted)
                Spacer()
                Button { nextVoicing(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 40) }
            }
            .foregroundColor(.fg)

            Button {
                if let v = current { strum(v) }
            } label: {
                Label("Tocar acorde", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.brass))
                    .foregroundColor(.bg)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.line))
    }

    private var notesView: some View {
        let names = ChordBook.notes(root: root, quality: quality)
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    VStack(spacing: 1) {
                        Text(n).font(.system(size: 15, weight: .semibold, design: .serif))
                        Text(quality.degrees[i]).font(.system(size: 10, design: .monospaced)).foregroundColor(.muted)
                    }
                    .frame(minWidth: 26)
                }
            }
        }
    }

    private func nextVoicing(_ step: Int) {
        let n = voicings.count
        guard n > 0 else { return }
        voicingIndex = (min(voicingIndex, n - 1) + step + n) % n
    }

    private func strum(_ v: Voicing) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        player.play(midis: ChordBook.midiNotes(v), a4: a4)
    }
}

struct ChordDiagram: View {
    let voicing: Voicing

    private var baseFret: Int {
        voicing.highestFret <= 4 ? 1 : voicing.lowestFret
    }

    var body: some View {
        Canvas { ctx, size in
            ChordDiagram.draw(ctx, size: size, voicing: voicing, base: baseFret)
        }
    }

    static func draw(_ ctx: GraphicsContext, size: CGSize, voicing: Voicing, base: Int) {
        let rows = 5
        let left: CGFloat = 44
        let right: CGFloat = 44
        let top: CGFloat = 34
        let bottom: CGFloat = 8
        let gridW: CGFloat = size.width - left - right
        let gridH: CGFloat = size.height - top - bottom
        let dx: CGFloat = gridW / 5
        let dy: CGFloat = gridH / CGFloat(rows)

        // trastes
        for r in 0...rows {
            var p = Path()
            let y = top + CGFloat(r) * dy
            p.move(to: CGPoint(x: left, y: y))
            p.addLine(to: CGPoint(x: left + gridW, y: y))
            let isNut = r == 0 && base == 1
            ctx.stroke(p, with: .color(isNut ? Color.fg : Color.line), lineWidth: isNut ? 5 : 1.5)
        }
        // cordas (mais grossas no grave)
        for s in 0..<6 {
            var p = Path()
            let x = left + CGFloat(s) * dx
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: top + gridH))
            let w: CGFloat = 2.2 - CGFloat(s) * 0.25
            ctx.stroke(p, with: .color(Color.muted), lineWidth: w)
        }
        // número da casa
        if base > 1 {
            let t = Text("\(base)ª").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Color.muted)
            ctx.draw(t, at: CGPoint(x: left - 22, y: top + dy / 2))
        }

        // pestana
        if let b = voicing.barre {
            let firstPlayed = voicing.frets.firstIndex { $0 >= 0 } ?? 0
            let lastAtBarre = voicing.frets.lastIndex { $0 == b } ?? firstPlayed
            if lastAtBarre > firstPlayed {
                let y = top + (CGFloat(b - base) + 0.5) * dy
                let x1 = left + CGFloat(firstPlayed) * dx
                let x2 = left + CGFloat(lastAtBarre) * dx
                let rect = CGRect(x: x1 - 11, y: y - 11, width: x2 - x1 + 22, height: 22)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 11), with: .color(Color.brass))
            }
        }

        // dedos, cordas soltas e abafadas
        for s in 0..<6 {
            let f = voicing.frets[s]
            let x = left + CGFloat(s) * dx
            if f < 0 {
                let t = Text("×").font(.system(size: 18, weight: .semibold)).foregroundColor(Color.muted)
                ctx.draw(t, at: CGPoint(x: x, y: top - 16))
            } else if f == 0 {
                let r = CGRect(x: x - 7, y: top - 23, width: 14, height: 14)
                ctx.stroke(Path(ellipseIn: r), with: .color(Color.fg), lineWidth: 1.8)
            } else if f != voicing.barre {
                let y = top + (CGFloat(f - base) + 0.5) * dy
                let r = CGRect(x: x - 12, y: y - 12, width: 24, height: 24)
                let isRoot = s == (voicing.frets.firstIndex { $0 >= 0 } ?? -1)
                ctx.fill(Path(ellipseIn: r), with: .color(isRoot ? Color.ok : Color.brass))
            }
        }
    }
}
