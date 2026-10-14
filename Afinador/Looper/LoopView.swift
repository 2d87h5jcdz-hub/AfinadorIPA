import SwiftUI
import UIKit

// MARK: - Aba Loop (pedaleira de loop)

struct LoopView: View {
    @ObservedObject var looper: LooperEngine
    @State private var showEffects = false
    @State private var showClearAll = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            PedalCatcher(
                onMain: { looper.pressSelected() },
                onNext: { looper.selectNext() },
                onHoldNext: { looper.togglePlayAll() },
                onUndo: { looper.undo(looper.selected) },
                onTrack: { looper.press($0) }
            )
            .frame(width: 0, height: 0)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    transport
                    LoopAutoCard(looper: looper)
                    inputCard
                    ForEach(0..<looper.trackCount, id: \.self) { t in
                        LoopTrackRow(looper: looper, index: t)
                    }
                    trackCountRow
                    pedalHint
                    settingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .foregroundColor(.fg)
        .onAppear { looper.start() }
        .onDisappear { looper.stop() }
        .sheet(isPresented: $showEffects) {
            StudioEffectsSheet(title: "Efeitos do Loop",
                               subtitle: "Valem para o que você toca e para o que é gravado nas faixas.",
                               settings: $looper.effects)
        }
        .confirmationDialog("Apagar todas as faixas?", isPresented: $showClearAll, titleVisibility: .visible) {
            Button("Apagar tudo", role: .destructive) { looper.clearAll() }
        }
        .alert("Loop", isPresented: Binding(get: { looper.lastError != nil }, set: { if !$0 { looper.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(looper.lastError ?? "")
        }
    }

    // MARK: Cabeçalho

    private var anyRecording: Bool {
        looper.tracks.prefix(looper.trackCount).contains { $0.state == .recording || $0.state == .overdubbing }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Lo").foregroundColor(.fg) + Text("op").foregroundColor(.brass))
                .font(.system(size: 24, weight: .heavy, design: .serif))
            Spacer()
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(anyRecording ? .off : (looper.playing ? .ok : .muted))
        }
    }

    private var statusText: String {
        if !looper.running { return looper.permissionDenied ? "SEM MICROFONE" : "DESLIGADO" }
        if looper.phase == .countIn { return "CONTAGEM" }
        if looper.phase == .waitingSound { return "ESPERANDO VOCÊ TOCAR" }
        if anyRecording { return "GRAVANDO" }
        return looper.playing ? "TOCANDO" : "PARADO"
    }

    // MARK: Transporte (todas as faixas)

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                looper.togglePlayAll()
            } label: {
                Image(systemName: looper.playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(looper.hasContent ? Color.brass : Color.line))
                    .foregroundColor(looper.hasContent ? .bg : .muted)
            }
            .disabled(!looper.hasContent)
            .accessibilityLabel(looper.playing ? "Parar tudo" : "Tocar tudo")

            VStack(alignment: .leading, spacing: 6) {
                Text(cycleTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(cycleSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.muted)
                    .lineLimit(2)
                cycleBar
            }
            Spacer(minLength: 0)
            Button {
                showClearAll = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .foregroundColor(looper.hasContent ? .off : .muted)
            }
            .disabled(!looper.hasContent)
            .accessibilityLabel("Apagar tudo")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.line))
    }

    private var cycleTitle: String {
        if looper.phase == .countIn { return "Contagem… \(looper.beat + 1)" }
        if looper.phase == .waitingSound { return "Pode começar a tocar" }
        if looper.baseSeconds > 0 { return "Ciclo de \(Self.seconds(looper.baseSeconds))" }
        if anyRecording { return "Gravando o ciclo… \(Self.seconds(looper.positionSeconds))" }
        return "Grave a primeira faixa"
    }

    private var cycleSubtitle: String {
        if looper.phase == .waitingSound { return "A gravação começa na primeira nota." }
        if looper.phase == .countIn { return "A gravação começa no próximo compasso." }
        if looper.baseSeconds > 0 { return "Todas as faixas seguem este tempo." }
        if looper.autoEnabled {
            return "Toque no botão da faixa: o loop fecha sozinho depois de \(looper.bars) \(looper.bars == 1 ? "compasso" : "compassos")."
        }
        return "Toque no botão da faixa para gravar e de novo para fechar o loop."
    }

    private var cycleBar: some View {
        GeometryReader { geo in
            let progress: Double = looper.baseSeconds > 0
                ? (looper.positionSeconds.truncatingRemainder(dividingBy: looper.baseSeconds)) / looper.baseSeconds
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.line)
                Capsule().fill(Color.brass)
                    .frame(width: geo.size.width * CGFloat(looper.playing ? progress : 0))
            }
        }
        .frame(height: 5)
    }

    // MARK: Entrada e efeitos

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .foregroundColor(.brass)
                VStack(alignment: .leading, spacing: 4) {
                    Text(looper.inputName.isEmpty ? "Entrada" : looper.inputName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    LevelBar(level: looper.inputLevel)
                        .frame(height: 5)
                }
                Spacer(minLength: 8)
                Button {
                    showEffects = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(effectsLabel).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Capsule().fill(Color.line))
                    .foregroundColor(.fg)
                }
            }
            Toggle(isOn: $looper.monitorEnabled) {
                Text("Ouvir a entrada")
                    .font(.system(size: 14))
            }
            .tint(Color.brass)
            if !looper.isHeadphoneConnected {
                Text("Sem fone, o microfone capta o som que sai do alto-falante: ele pode entrar nas camadas e dar microfonia. Para tocar ao vivo, use fone ou uma interface.")
                    .font(.system(size: 12))
                    .foregroundColor(.off)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.line))
    }

    private var effectsLabel: String {
        let p = looper.effects.preset
        if p == .none { return "Efeitos" }
        return p.title
    }

    // MARK: Faixas

    private var trackCountRow: some View {
        HStack(spacing: 10) {
            Button {
                looper.addTrack()
            } label: {
                Label("Faixa", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().stroke(Color.line))
            }
            .disabled(looper.trackCount >= LooperEngine.maxTracks)
            Button {
                looper.removeTrack()
            } label: {
                Label("Faixa", systemImage: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().stroke(Color.line))
            }
            .disabled(looper.trackCount <= 1 || looper.tracks[looper.trackCount - 1].state != .empty)
            Spacer()
            Text("\(looper.trackCount) de \(LooperEngine.maxTracks)")
                .font(.system(size: 12))
                .foregroundColor(.muted)
        }
        .foregroundColor(.fg)
    }

    private var pedalHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pedal Bluetooth")
                .font(.system(size: 14, weight: .semibold))
            Text("Pedais de virar página funcionam como teclado. → (ou espaço) aperta o botão da faixa selecionada. ← troca a faixa selecionada. Segure ← para parar ou tocar tudo. Num teclado, as teclas 1 a 6 apertam cada faixa e Apagar desfaz a última camada.")
                .font(.system(size: 12))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).stroke(Color.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    // MARK: Ajustes

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
            } label: {
                HStack {
                    Text("Ajustes")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.muted)
                }
            }
            .foregroundColor(.fg)
            if showSettings {
                stepperRow(title: "Ganho da entrada",
                           value: "+\(Int(looper.inputGainDB)) dB",
                           minus: { looper.inputGainDB -= 1 },
                           plus: { looper.inputGainDB += 1 })
                stepperRow(title: "Compensação de atraso",
                           value: "\(Int(looper.latencyMS.rounded())) ms",
                           minus: { looper.latencyTrimMS -= 1 },
                           plus: { looper.latencyTrimMS += 1 })
                Text("Se as camadas gravadas por cima ficarem atrasadas em relação às outras, aumente a compensação. Se ficarem adiantadas, diminua. O valor inicial vem do iPhone e da rota de áudio.")
                    .font(.system(size: 12))
                    .foregroundColor(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if looper.latencyTrimMS != 0 {
                    Button("Voltar ao valor do iPhone") { looper.latencyTrimMS = 0 }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.brass)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.line))
        .padding(.bottom, 16)
    }

    private func stepperRow(title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            HStack(spacing: 8) {
                smallButton("−", action: minus)
                Text(value)
                    .font(.system(size: 14, design: .monospaced)).monospacedDigit()
                    .frame(minWidth: 58)
                smallButton("+", action: plus)
            }
        }
    }

    private func smallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 18))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.line))
                .foregroundColor(.fg)
        }
    }

    static func seconds(_ s: Double) -> String {
        String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Linha de uma faixa

struct LoopTrackRow: View {
    @ObservedObject var looper: LooperEngine
    let index: Int
    @State private var showClear = false

    private var info: LooperEngine.TrackInfo { looper.tracks[index] }
    private var isSelected: Bool { looper.selected == index }
    private var isRecording: Bool { info.state == .recording || info.state == .overdubbing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                LoopTrackButton(info: info, playing: looper.playing) {
                    looper.press(index)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Faixa \(index + 1)")
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(isRecording ? .off : .muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                trailing
            }
            if info.state != .empty {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                    Slider(value: Binding(get: { Double(looper.volumes[index]) },
                                          set: { looper.setVolume(Float($0), for: index) }),
                           in: 0...1.5)
                        .tint(Color.brass)
                    LevelBar(level: info.level)
                        .frame(width: 44, height: 5)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.brass : Color.line, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { looper.selected = index }
        .confirmationDialog("Apagar a faixa \(index + 1)?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Apagar faixa", role: .destructive) { looper.clear(index) }
        }
    }

    private var subtitle: String {
        switch info.state {
        case .empty:
            return info.multiplier == 1 ? "Toque para gravar" : "Toque para gravar · \(info.multiplier) ciclos"
        case .recording:
            return looper.autoEnabled ? "Gravando… fecha sozinho" : "Gravando… toque para fechar o loop"
        case .overdubbing:
            return looper.autoEnabled ? "Gravando por cima uma volta…" : "Gravando por cima… toque para parar"
        case .armed:
            if looper.phase == .countIn { return "Grava depois da contagem" }
            if looper.phase == .waitingSound { return "Grava quando você tocar" }
            return "Armada · entra no próximo ciclo (toque para cancelar)"
        case .playing:
            let len = LoopView.seconds(info.length)
            let cycles = info.multiplier > 1 ? " · \(info.multiplier) ciclos" : ""
            if info.muted { return "Parada · \(len)\(cycles)" }
            return "Tocando · \(len)\(cycles)"
        @unknown default:
            return ""
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if info.state == .empty || info.state == .armed {
            Menu {
                Picker("Tamanho", selection: Binding(get: { info.multiplier },
                                                     set: { looper.setMultiplier($0, for: index) })) {
                    Text("1 ciclo").tag(1)
                    Text("2 ciclos").tag(2)
                    Text("4 ciclos").tag(4)
                }
            } label: {
                Text("×\(info.multiplier)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 44, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.line))
                    .foregroundColor(.fg)
            }
            .accessibilityLabel("Tamanho da faixa em ciclos")
        } else {
            HStack(spacing: 6) {
                iconButton(info.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           color: info.muted ? .off : .fg,
                           label: info.muted ? "Voltar a tocar" : "Parar faixa") {
                    looper.toggleMute(index)
                }
                iconButton("arrow.uturn.backward", color: info.canUndo ? .fg : .muted, label: "Desfazer a última camada") {
                    looper.undo(index)
                }
                .disabled(!info.canUndo)
                iconButton("trash", color: isRecording ? .muted : .off, label: "Apagar faixa") {
                    showClear = true
                }
                .disabled(isRecording)
            }
        }
    }

    private func iconButton(_ name: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.line))
                .foregroundColor(color)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Botão redondo da faixa (com anel de progresso)

struct LoopTrackButton: View {
    let info: LooperEngine.TrackInfo
    let playing: Bool
    let action: () -> Void

    private var ringColor: Color {
        switch info.state {
        case .recording, .overdubbing: return .off
        case .playing: return info.muted ? .muted : .brass
        default: return .line
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.line, lineWidth: 5)
                if info.state != .empty && info.state != .recording && info.state != .armed {
                    Circle()
                        .trim(from: 0, to: CGFloat(playing ? info.progress : 0))
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if info.state == .recording {
                    Circle().stroke(Color.off, lineWidth: 5)
                }
                if info.state == .armed {
                    Circle().stroke(Color.off, style: StrokeStyle(lineWidth: 3, dash: [5, 5]))
                }
                icon
            }
            .frame(width: 66, height: 66)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder
    private var icon: some View {
        switch info.state {
        case .empty:
            Circle().fill(Color.off.opacity(0.85)).frame(width: 22, height: 22)
        case .armed:
            ArmedDot()
        case .recording:
            RecordingDot()
        case .overdubbing:
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.off)
        default:
            Image(systemName: info.muted ? "play.fill" : "repeat")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(info.muted ? .muted : .brass)
        }
    }

    private var accessibility: String {
        switch info.state {
        case .empty: return "Gravar"
        case .armed: return "Cancelar"
        case .recording: return "Fechar o loop"
        case .overdubbing: return "Parar de gravar por cima"
        default: return info.muted ? "Voltar a tocar" : "Gravar por cima"
        }
    }
}

/// Faixa armada: anel tracejado e bolinha vazada.
struct ArmedDot: View {
    var body: some View {
        Circle()
            .stroke(Color.off, lineWidth: 3)
            .frame(width: 20, height: 20)
    }
}

/// Bolinha vermelha piscando enquanto grava.
struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.off)
            .frame(width: 26, height: 26)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Barra de nível simples (0…1).
struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            let clamped = CGFloat(min(1, max(0, level)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.line)
                Capsule()
                    .fill(clamped > 0.9 ? Color.off : Color.ok)
                    .frame(width: geo.size.width * clamped)
            }
        }
    }
}

// MARK: - Pedal Bluetooth / teclado

/// View invisível que vira "first responder" para receber as teclas de um pedal de virar página
/// (que se apresenta como teclado Bluetooth) ou de um teclado.
struct PedalCatcher: UIViewRepresentable {
    var onMain: () -> Void
    var onNext: () -> Void
    var onHoldNext: () -> Void
    var onUndo: () -> Void
    var onTrack: (Int) -> Void

    func makeUIView(context: Context) -> PedalCatcherView {
        let view = PedalCatcherView()
        view.handlers = self
        return view
    }

    func updateUIView(_ uiView: PedalCatcherView, context: Context) {
        uiView.handlers = self
        if uiView.window != nil && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }
}

final class PedalCatcherView: UIView {
    var handlers: PedalCatcher?
    private var holdTimer: Timer?
    private var holdFired = false
    private var secondaryDown = false

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
    }

    private static let mainKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardRightArrow, .keyboardDownArrow, .keyboardSpacebar, .keyboardReturnOrEnter, .keyboardPageDown,
    ]
    private static let secondaryKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardLeftArrow, .keyboardUpArrow, .keyboardPageUp,
    ]
    private static let trackKeys: [UIKeyboardHIDUsage] = [
        .keyboard1, .keyboard2, .keyboard3, .keyboard4, .keyboard5, .keyboard6,
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let code = press.key?.keyCode else { continue }
            if Self.mainKeys.contains(code) {
                handlers?.onMain()
                handled = true
            } else if Self.secondaryKeys.contains(code) {
                if !secondaryDown {
                    secondaryDown = true
                    holdFired = false
                    holdTimer?.invalidate()
                    let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.holdFired = true
                        self.handlers?.onHoldNext()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    holdTimer = timer
                }
                handled = true
            } else if code == .keyboardDeleteOrBackspace {
                handlers?.onUndo()
                handled = true
            } else if let i = Self.trackKeys.firstIndex(of: code) {
                handlers?.onTrack(i)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let code = press.key?.keyCode else { continue }
            if Self.secondaryKeys.contains(code) {
                holdTimer?.invalidate()
                holdTimer = nil
                if secondaryDown && !holdFired { handlers?.onNext() }
                secondaryDown = false
                handled = true
            } else if Self.mainKeys.contains(code) || code == .keyboardDeleteOrBackspace
                        || Self.trackKeys.contains(code) {
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        holdTimer?.invalidate()
        holdTimer = nil
        secondaryDown = false
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Modo automático (tempo e compassos)

struct LoopAutoCard: View {
    @ObservedObject var looper: LooperEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $looper.autoEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loop automático")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Fecha sozinho no tempo certo, sem tirar as mãos do instrumento.")
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.brass)
            .disabled(!looper.canChangeTempo)
            if looper.autoEnabled {
                tempoRow
                barsRow
                startRow
                chainRow
                Toggle(isOn: $looper.clickInLoop) {
                    Text("Clique durante o loop").font(.system(size: 14))
                }
                .tint(Color.brass)
                if !looper.canChangeTempo {
                    Text("Para mudar o tempo ou os compassos, apague as faixas.")
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.line))
    }

    private var tempoRow: some View {
        HStack(spacing: 10) {
            beatDots
            Spacer(minLength: 4)
            stepButton("−") { looper.bpm -= 1 }
            Text("\(looper.bpm) BPM")
                .font(.system(size: 15, weight: .semibold, design: .monospaced)).monospacedDigit()
                .frame(minWidth: 84)
            stepButton("+") { looper.bpm += 1 }
            Button("Tap") { looper.tapTempo() }
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 48, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.line))
                .foregroundColor(.fg)
        }
        .disabled(!looper.canChangeTempo)
    }

    private var beatDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<looper.beatsPerBar, id: \.self) { i in
                let active = (looper.playing || looper.phase == .countIn) && looper.beat == i
                Circle()
                    .fill(active ? (i == 0 ? Color.brass : Color.fg) : Color.line)
                    .frame(width: 9, height: 9)
            }
        }
    }

    private var barsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Compasso").font(.system(size: 14))
                Spacer()
                Picker("Compasso", selection: $looper.beatsPerBar) {
                    Text("2/4").tag(2)
                    Text("3/4").tag(3)
                    Text("4/4").tag(4)
                    Text("6/8").tag(6)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            HStack {
                Text("Tamanho").font(.system(size: 14))
                Spacer()
                Picker("Compassos", selection: $looper.bars) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            Text("Ciclo de \(looper.bars) \(looper.bars == 1 ? "compasso" : "compassos") · \(LoopView.seconds(looper.autoCycleSeconds))")
                .font(.system(size: 12))
                .foregroundColor(.muted)
        }
        .disabled(!looper.canChangeTempo)
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Começar").font(.system(size: 14))
                Spacer()
                Picker("Começar", selection: $looper.startOnSound) {
                    Text("Com contagem").tag(false)
                    Text("Ao tocar").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            if looper.startOnSound {
                HStack {
                    Text("Sensibilidade").font(.system(size: 14))
                    Spacer()
                    Picker("Sensibilidade", selection: $looper.soundSensitivity) {
                        Text("Baixa").tag(0)
                        Text("Média").tag(1)
                        Text("Alta").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }
        }
        .disabled(!looper.canChangeTempo)
    }

    private var chainRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $looper.chain) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gravar as faixas em sequência").font(.system(size: 14))
                    Text("Depois da base, cada faixa vazia grava sozinha no ciclo seguinte.")
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.brass)
            if looper.chain {
                HStack {
                    Text("Folga entre faixas").font(.system(size: 14))
                    Spacer()
                    Picker("Folga", selection: $looper.gapCycles) {
                        Text("Nenhuma").tag(0)
                        Text("1 ciclo").tag(1)
                        Text("2 ciclos").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }
        }
        .disabled(!looper.canChangeTempo)
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 18))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.line))
                .foregroundColor(.fg)
        }
    }
}
