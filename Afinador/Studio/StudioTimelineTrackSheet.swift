import SwiftUI

/// Alvo da folha de ajustes de uma faixa (aberta pelo nome na coluna da linha do tempo).
struct StudioTrackSheetTarget: Identifiable, Equatable {
    let id: UUID
}

// MARK: - Folha de ajustes da faixa: volume, pan, M/S, efeitos, renomear, apagar, armar

@MainActor
struct StudioTimelineTrackSheet: View {
    @ObservedObject var studio: StudioEngine
    let trackID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showEffects = false
    @State private var confirmDelete = false

    private var tracks: [StudioTrack] { studio.project?.tracks ?? [] }
    private var track: StudioTrack? { tracks.first(where: { $0.id == trackID }) }
    private var index: Int { (tracks.firstIndex(where: { $0.id == trackID }) ?? 0) + 1 }
    private var isStopped: Bool { studio.transport == .stopped }
    private var isArmed: Bool { studio.armedTrackID == trackID }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let track = track {
                        trackControls(track)
                        recordActions(track)
                    } else {
                        Text("Esta faixa não existe mais.")
                            .font(.system(size: 15))
                            .foregroundColor(.muted)
                    }
                }
                .padding(16)
            }
        }
        .foregroundColor(.fg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showEffects) {
            StudioEffectsSheet(
                title: track?.name ?? "Faixa",
                subtitle: "Efeitos desta faixa na reprodução e na exportação.",
                settings: effectsBinding,
                extraTop: AnyView(StudioPitchPanel(studio: studio, trackID: trackID))
            )
        }
        .alert("Apagar faixa?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) { deleteTrack() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("“\(track?.name ?? "Faixa")” e todos os trechos dela serão apagados. Não dá para desfazer.")
        }
    }

    private var header: some View {
        HStack {
            Text("Ajustes da faixa")
                .font(.system(size: 20, weight: .heavy, design: .serif))
            Spacer()
            Button("Pronto") { dismiss() }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.brass)
        }
        .padding(.top, 8)
    }

    private func trackControls(_ track: StudioTrack) -> some View {
        StudioTrackRow(
            track: track,
            index: index,
            level: studio.trackLevels[track.id] ?? 0,
            isLocked: !isStopped,
            onUpdate: { updated in studio.updateTrack(updated) },
            onEffects: { showEffects = true },
            onDelete: { confirmDelete = true }
        )
    }

    private func recordActions(_ track: StudioTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary(track))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.muted)
            HStack(spacing: 8) {
                StudioChip(title: isArmed ? "Armada" : "Gravar aqui",
                           systemImage: "record.circle",
                           isOn: isArmed,
                           onColor: .off) {
                    studio.arm(isArmed ? nil : trackID)
                }
                .disabled(!isStopped)
                .accessibilityLabel(isArmed ? "Desarmar esta faixa" : "Armar esta faixa para a próxima gravação")
                StudioChip(title: "Fim da faixa", systemImage: "arrow.right.to.line") {
                    studio.seekToEnd(of: trackID)
                }
                .disabled(isRecordingLike)
                .accessibilityLabel("Levar a cabeça de reprodução para o fim desta faixa")
                Spacer(minLength: 0)
            }
        }
        .studioPanel(padding: 12)
    }

    private var isRecordingLike: Bool {
        switch studio.transport {
        case .recording, .countIn: return true
        default: return false
        }
    }

    private func summary(_ track: StudioTrack) -> String {
        let count: Int = track.clips.count
        let pieces: String = count == 1 ? "1 trecho" : "\(count) trechos"
        if count == 0 { return "Faixa vazia — arme e grave." }
        return "\(pieces) · termina em \(StudioUIFormat.time(track.end))"
    }

    private var effectsBinding: Binding<EffectSettings> {
        Binding<EffectSettings>(
            get: { track?.effects ?? EffectSettings() },
            set: { newValue in
                guard var current = track else { return }
                current.effects = newValue
                studio.updateTrack(current)
            }
        )
    }

    private func deleteTrack() {
        studio.deleteTrack(trackID)
        dismiss()
    }
}
