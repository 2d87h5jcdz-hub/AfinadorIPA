import SwiftUI
import UniformTypeIdentifiers

/// Clip selecionado na linha do tempo.
struct StudioClipSelection: Equatable {
    let trackID: UUID
    let clipID: UUID
}

/// Guarda o deslocamento atual da rolagem sem disparar redesenho (não é observado).
final class StudioTimelineScrollBox {
    var offset: CGFloat = 0
    var visibleWidth: CGFloat = 0
}

struct StudioTimelineOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Linha do tempo (faixas lado a lado no tempo, estilo DAW)

@MainActor
struct StudioTimelineView: View {
    @ObservedObject var studio: StudioEngine
    let onError: (String) -> Void

    @State private var pps: CGFloat = StudioTimelineLayout.defaultPPS
    @State private var follow: Bool = true
    @State private var selection: StudioClipSelection?
    @State private var pendingClipDelete: StudioClipSelection?
    @State private var sheetTrack: StudioTrackSheetTarget?
    @State private var renderPage: Int = 0
    @State private var visibleWidth: CGFloat = 240
    @State private var scrollTargetX: CGFloat = 0
    @State private var box = StudioTimelineScrollBox()
    @State private var isDraggingClip = false
    @State private var showImporter = false
    @State private var importing = false

    private static let space = "studio-timeline"
    private static let markerID = "studio-timeline-marker"

    // MARK: Estado derivado

    private var tracks: [StudioTrack] { studio.project?.tracks ?? [] }
    private var isStopped: Bool { studio.transport == .stopped }
    private var isRecordingLike: Bool {
        switch studio.transport {
        case .recording, .countIn: return true
        default: return false
        }
    }

    private var armedIndex: Int? {
        guard let id = studio.armedTrackID else { return nil }
        return tracks.firstIndex(where: { $0.id == id })
    }

    /// Gravando sem faixa armada: mostra uma faixa "fantasma" no fim para o clip ao vivo.
    private var showGhostLane: Bool { isRecordingLike && armedIndex == nil }

    private var liveLaneIndex: Int? {
        guard isRecordingLike else { return nil }
        return armedIndex ?? tracks.count
    }

    private var laneCount: Int { tracks.count + (showGhostLane ? 1 : 0) }

    private var totalHeight: CGFloat {
        StudioTimelineLayout.rulerHeight + StudioTimelineLayout.laneHeight * CGFloat(laneCount)
    }

    /// Segundos de conteúdo: o projeto + folga; cresce em blocos de 30 s durante a gravação
    /// (para a largura não mudar a cada tique da posição).
    private var contentSeconds: Double {
        let position: Double = studio.position.isFinite ? max(studio.position, 0) : 0
        let coarse: Double = (position / 30.0).rounded(.up) * 30.0
        let base: Double = max(studio.duration, coarse)
        let minimum: Double = Double(visibleWidth / pps)
        return max(base + 20.0, minimum)
    }

    private var contentWidth: CGFloat { CGFloat(contentSeconds) * pps }

    private var metrics: StudioTimelineMetrics {
        let page: CGFloat = StudioTimelineLayout.renderPage
        let bpm: Double = max(studio.project?.bpm ?? 90, 20)
        let start: CGFloat = max(0, CGFloat(renderPage - 1) * page)
        let end: CGFloat = min(contentWidth, CGFloat(renderPage + 2) * page + visibleWidth)
        return StudioTimelineMetrics(
            pps: pps,
            beatLength: 60.0 / bpm,
            beatsPerBar: max(studio.project?.beatsPerBar ?? 4, 1),
            windowStart: start,
            windowEnd: max(end, start + 1)
        )
    }

    /// Seleção ainda válida (o clip pode ter sido apagado ou substituído por uma regravação).
    private var validSelection: (StudioTrack, StudioClip)? {
        guard let sel = selection,
              let track = tracks.first(where: { $0.id == sel.trackID }),
              let clip = track.clips.first(where: { $0.id == sel.clipID }) else { return nil }
        return (track, clip)
    }

    // MARK: Corpo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioTimelineToolbar(
                trackCount: tracks.count,
                pps: pps,
                follow: $follow,
                onZoomOut: { setZoom(pps / 1.5) },
                onZoomIn: { setZoom(pps * 1.5) }
            )
            timelinePanel
            clipBar
            if tracks.isEmpty && !isRecordingLike {
                emptyHint
            }
            addRow
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(item: $sheetTrack) { target in
            StudioTimelineTrackSheet(studio: studio, trackID: target.id)
        }
        .alert("Apagar trecho?", isPresented: clipDeleteBinding, presenting: pendingClipDelete) { sel in
            Button("Apagar", role: .destructive) {
                studio.deleteClip(sel.clipID, in: sel.trackID)
                selection = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O trecho sai da faixa. Não dá para desfazer.")
        }
        .onChange(of: studio.transport) { newValue in
            if newValue != .stopped {
                selection = nil
            }
        }
        .onChange(of: selection) { _ in
            // Garante que a rolagem não fique travada se o clip arrastado sumir no meio do gesto.
            isDraggingClip = false
        }
    }

    private var clipDeleteBinding: Binding<Bool> {
        Binding<Bool>(get: { pendingClipDelete != nil }, set: { if !$0 { pendingClipDelete = nil } })
    }

    // MARK: Painel: coluna de faixas + área rolável

    private var timelinePanel: some View {
        HStack(alignment: .top, spacing: 0) {
            headerColumn
            Rectangle()
                .fill(Color.line)
                .frame(width: 1, height: totalHeight)
            scrollArea
        }
        .frame(height: totalHeight)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isRecordingLike ? Color.off.opacity(0.7) : Color.line))
    }

    private var headerColumn: some View {
        VStack(spacing: 0) {
            rulerCorner
            ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                laneHeader(index: pair.offset, track: pair.element)
                    .frame(height: StudioTimelineLayout.laneHeight)
            }
            if showGhostLane {
                ghostHeader
                    .frame(height: StudioTimelineLayout.laneHeight)
            }
        }
        .frame(width: StudioTimelineLayout.headerWidth)
    }

    private var rulerCorner: some View {
        HStack {
            Text("COMPASSO")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: StudioTimelineLayout.rulerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line).frame(height: 1)
        }
    }

    private func laneHeader(index: Int, track: StudioTrack) -> some View {
        let id: UUID = track.id
        let armed: Bool = studio.armedTrackID == id
        return StudioTimelineLaneHeader(
            track: track,
            index: index + 1,
            isArmed: armed,
            canArm: isStopped,
            onArm: { toggleArm(id) },
            onToggleMute: { toggleMute(id) },
            onToggleSolo: { toggleSolo(id) },
            onOpen: { sheetTrack = StudioTrackSheetTarget(id: id) }
        )
        .equatable()
    }

    private var ghostHeader: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.off).frame(width: 10, height: 10)
            Text("Nova faixa")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.off.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Gravando numa faixa nova")
    }

    private var scrollArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    timelineContent
                }
                .coordinateSpace(name: Self.space)
                .scrollDisabled(isDraggingClip)
                .onPreferenceChange(StudioTimelineOffsetKey.self) { offset in
                    handleScrollOffset(offset)
                }
                .simultaneousGesture(pinchGesture)
                .onAppear {
                    updateVisibleWidth(geo.size.width)
                    reveal(x: playheadX, proxy: proxy, animated: false)
                }
                .onChange(of: geo.size.width) { width in
                    updateVisibleWidth(width)
                }
                .onChange(of: studio.position) { newValue in
                    followPlayhead(position: newValue, proxy: proxy)
                }
                .onChange(of: pps) { _ in
                    reveal(x: playheadX, proxy: proxy, animated: false)
                }
                .onChange(of: follow) { on in
                    if on { reveal(x: playheadX, proxy: proxy, animated: true) }
                }
            }
        }
        .frame(height: totalHeight)
    }

    private var timelineContent: some View {
        let m: StudioTimelineMetrics = metrics
        let width: CGFloat = contentWidth
        return ZStack(alignment: .topLeading) {
            StudioTimelineGrid(metrics: m, height: totalHeight)
                .equatable()
            lanesStack(metrics: m, width: width)
            StudioTimelinePlayhead(
                studio: studio,
                pps: pps,
                totalHeight: totalHeight,
                liveLaneIndex: liveLaneIndex
            )
            scrollMarker
        }
        .frame(width: width, height: totalHeight, alignment: .topLeading)
        .background(offsetReader)
    }

    private func lanesStack(metrics m: StudioTimelineMetrics, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            StudioTimelineRuler(metrics: m, contentWidth: width, onSeek: { t in seekFromTap(t) })
                .equatable()
            ForEach(tracks) { track in
                lane(track: track, metrics: m, width: width)
            }
            if showGhostLane {
                Color.off.opacity(0.05)
                    .frame(width: width, height: StudioTimelineLayout.laneHeight)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func lane(track: StudioTrack, metrics m: StudioTimelineMetrics, width: CGFloat) -> some View {
        let trackID: UUID = track.id
        let selectedClip: UUID? = (selection?.trackID == trackID) ? selection?.clipID : nil
        return StudioTimelineLane(
            studio: studio,
            track: track,
            metrics: m,
            contentWidth: width,
            isArmed: studio.armedTrackID == trackID,
            selectedClipID: selectedClip,
            canEdit: isStopped,
            onSeek: { t in seekFromTap(t) },
            onSelect: { clipID in selectClip(clipID, in: trackID) },
            onMove: { clipID, offset in moveClip(clipID, in: trackID, to: offset) },
            onDragActive: { active in isDraggingClip = active }
        )
        .equatable()
    }

    /// Marcador invisível que a rolagem automática usa como alvo (scrollTo com âncora .leading).
    private var scrollMarker: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .id(Self.markerID)
            .padding(.leading, scrollTargetX)
            .allowsHitTesting(false)
    }

    private var offsetReader: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: StudioTimelineOffsetKey.self,
                value: -g.frame(in: .named(Self.space)).minX
            )
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onEnded { scale in
                setZoom(pps * scale)
            }
    }

    // MARK: Barra do clip selecionado

    @ViewBuilder
    private var clipBar: some View {
        if let pair = validSelection {
            StudioTimelineClipBar(
                trackName: pair.0.name,
                clip: pair.1,
                canEdit: isStopped,
                onMoveToCursor: { moveSelectedToCursor() },
                onSeekToEnd: { studio.seekToEnd(of: pair.0.id) },
                onDelete: { pendingClipDelete = selection },
                onClose: { selection = nil }
            )
        }
    }

    // MARK: Rodapé: nova faixa / importar

    private var addRow: some View {
        HStack(spacing: 10) {
            Button {
                selection = nil
                studio.addEmptyTrack(name: nil)
            } label: {
                Label("Nova faixa", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Color.panel))
                    .overlay(Capsule().stroke(Color.brass.opacity(0.7)))
                    .foregroundColor(.fg)
            }
            .disabled(!isStopped)
            .opacity(isStopped ? 1 : 0.5)
            .accessibilityLabel("Adicionar faixa vazia")
            .accessibilityHint("A faixa nova já fica armada para a próxima gravação")
            importButton
            Spacer(minLength: 0)
        }
    }

    private var importButton: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 6) {
                if importing {
                    ProgressView().tint(Color.brass)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(importing ? "Importando…" : "Importar áudio")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.panel))
            .overlay(Capsule().stroke(Color.line))
            .foregroundColor(.fg)
        }
        .disabled(importing || !isStopped)
        .opacity(isStopped ? 1 : 0.5)
        .accessibilityLabel("Importar áudio do app Arquivos como nova faixa")
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nenhuma faixa ainda")
                .font(.system(size: 16, weight: .semibold, design: .serif))
            Text("Toque em “Nova faixa” e depois no botão vermelho para gravar, ou importe um áudio (uma base, uma guia) do app Arquivos.")
                .font(.system(size: 13))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel()
    }

    // MARK: Ações

    private var playheadX: CGFloat {
        let p: Double = studio.position.isFinite ? max(studio.position, 0) : 0
        return CGFloat(p) * pps
    }

    private func setZoom(_ value: CGFloat) {
        let clamped: CGFloat = min(max(value, StudioTimelineLayout.minPPS), StudioTimelineLayout.maxPPS)
        guard abs(clamped - pps) > 0.01 else { return }
        pps = clamped
    }

    private func seekFromTap(_ time: Double) {
        selection = nil
        guard !isRecordingLike else { return }
        studio.seek(to: time)
    }

    private func selectClip(_ clipID: UUID, in trackID: UUID) {
        guard !isRecordingLike else { return }
        let new = StudioClipSelection(trackID: trackID, clipID: clipID)
        selection = (selection == new) ? nil : new
    }

    private func moveClip(_ clipID: UUID, in trackID: UUID, to offset: Double) {
        guard isStopped else { return }
        studio.moveClip(clipID, in: trackID, to: max(0, offset))
    }

    private func moveSelectedToCursor() {
        guard isStopped, let sel = selection else { return }
        studio.moveClip(sel.clipID, in: sel.trackID, to: max(0, studio.position))
    }

    private func toggleArm(_ id: UUID) {
        guard isStopped else { return }
        studio.arm(studio.armedTrackID == id ? nil : id)
    }

    private func toggleMute(_ id: UUID) {
        guard var track = tracks.first(where: { $0.id == id }) else { return }
        track.isMuted.toggle()
        studio.updateTrack(track)
    }

    private func toggleSolo(_ id: UUID) {
        guard var track = tracks.first(where: { $0.id == id }) else { return }
        track.isSolo.toggle()
        studio.updateTrack(track)
    }

    // MARK: Rolagem

    private func updateVisibleWidth(_ width: CGFloat) {
        let w: CGFloat = max(width, 1)
        box.visibleWidth = w
        if abs(visibleWidth - w) > 0.5 {
            visibleWidth = w
        }
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        let safe: CGFloat = max(offset, 0)
        box.offset = safe
        let page: Int = Int(safe / StudioTimelineLayout.renderPage)
        if page != renderPage {
            renderPage = page
        }
    }

    /// Mantém a cabeça visível: andando (com "seguir" ligado) vira a página perto da borda direita;
    /// parado, só rola se a cabeça foi parar fora da tela (ex.: "fim da faixa", voltar ao início).
    private func followPlayhead(position: Double, proxy: ScrollViewProxy) {
        let x: CGFloat = CGFloat(position.isFinite ? max(position, 0) : 0) * pps
        let left: CGFloat = box.offset
        let width: CGFloat = max(box.visibleWidth, 1)
        if isStopped {
            if x < left || x > left + width - 6 {
                reveal(x: x, proxy: proxy, animated: true)
            }
        } else if follow {
            if x < left || x > left + width * 0.85 {
                reveal(x: x, proxy: proxy, animated: false)
            }
        }
    }

    private func reveal(x: CGFloat, proxy: ScrollViewProxy, animated: Bool) {
        let width: CGFloat = max(box.visibleWidth, visibleWidth)
        let maxTarget: CGFloat = max(contentWidth - 2, 0)
        let target: CGFloat = min(max(x - width * 0.15, 0), maxTarget)
        scrollTargetX = target
        box.offset = target
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.markerID, anchor: .leading)
                }
            } else {
                proxy.scrollTo(Self.markerID, anchor: .leading)
            }
        }
    }

    // MARK: Importação

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            onError("Não deu para abrir o arquivo: \(error.localizedDescription)")
        case .success(let urls):
            guard !urls.isEmpty else { return }
            importing = true
            Task {
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent
                    do {
                        _ = try await studio.importAudio(from: url, name: name)
                    } catch {
                        onError("Não deu para importar “\(url.lastPathComponent)”: \(error.localizedDescription)")
                    }
                }
                importing = false
            }
        }
    }
}

// MARK: - Barra de ferramentas: título, seguir a cabeça, zoom

struct StudioTimelineToolbar: View {
    let trackCount: Int
    let pps: CGFloat
    @Binding var follow: Bool
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Faixas")
                .font(.system(size: 20, weight: .heavy, design: .serif))
            Text("\(trackCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.muted)
            Spacer(minLength: 4)
            followButton
            zoomButton(systemImage: "minus.magnifyingglass", enabled: pps > StudioTimelineLayout.minPPS + 0.5, action: onZoomOut)
                .accessibilityLabel("Afastar o zoom")
            zoomButton(systemImage: "plus.magnifyingglass", enabled: pps < StudioTimelineLayout.maxPPS - 0.5, action: onZoomIn)
                .accessibilityLabel("Aproximar o zoom")
        }
    }

    private var followButton: some View {
        Button {
            follow.toggle()
        } label: {
            Image(systemName: "arrow.right.to.line.compact")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 34)
                .background(Capsule().fill(follow ? Color.brass : Color.panel))
                .overlay(Capsule().stroke(follow ? Color.brass : Color.line))
                .foregroundColor(follow ? Color.bg : Color.fg)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(follow ? "Seguir a cabeça de reprodução: ligado" : "Seguir a cabeça de reprodução: desligado")
    }

    private func zoomButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(Capsule().fill(Color.panel))
                .overlay(Capsule().stroke(Color.line))
                .foregroundColor(.fg)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Ações do clip selecionado

struct StudioTimelineClipBar: View {
    let trackName: String
    let clip: StudioClip
    let canEdit: Bool
    let onMoveToCursor: () -> Void
    let onSeekToEnd: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StudioChip(title: "Mover p/ cursor", systemImage: "arrow.left.and.right", action: onMoveToCursor)
                        .disabled(!canEdit)
                        .accessibilityLabel("Mover o trecho para a posição da cabeça de reprodução")
                    StudioChip(title: "Fim da faixa", systemImage: "arrow.right.to.line", action: onSeekToEnd)
                        .accessibilityLabel("Ir para o fim da faixa")
                    StudioChip(title: "Apagar trecho", systemImage: "trash", action: onDelete)
                        .disabled(!canEdit)
                        .accessibilityLabel("Apagar trecho")
                }
            }
            Text("Dica: segure o trecho e arraste para mover (gruda na batida).")
                .font(.system(size: 11))
                .foregroundColor(.muted)
        }
        .studioPanel(padding: 12, stroke: Color.brass.opacity(0.6))
        .opacity(canEdit ? 1 : 0.6)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trecho de \(trackName)")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .lineLimit(1)
                Text("\(StudioUIFormat.time(clip.offset)) – \(StudioUIFormat.time(clip.end))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.muted)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.muted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tirar a seleção")
        }
    }
}
