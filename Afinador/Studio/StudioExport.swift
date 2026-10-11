import SwiftUI
import UIKit

// MARK: - Exportar mixagem e compartilhar (Arquivos, WhatsApp…)

struct StudioShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController dentro de uma sheet do SwiftUI.
struct StudioShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
struct StudioExportButton: View {
    @ObservedObject var studio: StudioEngine
    let onError: (String) -> Void
    @State private var exporting: ExportFormat?
    @State private var shareItem: StudioShareItem?

    private var hasTracks: Bool { !(studio.project?.tracks.isEmpty ?? true) }
    private var canExport: Bool {
        hasTracks && studio.transport == .stopped && exporting == nil
    }

    var body: some View {
        Menu {
            Section("Exportar mixagem") {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        export(format)
                    } label: {
                        Label(title(for: format), systemImage: icon(for: format))
                    }
                }
            }
        } label: {
            label
        }
        .disabled(!canExport)
        .opacity(hasTracks ? 1 : 0.45)
        .accessibilityLabel(exporting == nil ? "Exportar mixagem" : "Exportando mixagem")
        .sheet(item: $shareItem) { item in
            StudioShareSheet(items: [item.url], onFinish: { shareItem = nil })
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 6) {
            if exporting != nil {
                ProgressView().tint(Color.bg)
                Text("Exportando…")
            } else {
                Image(systemName: "square.and.arrow.up")
                Text("Exportar")
            }
        }
        .font(.system(size: 14, weight: .bold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.brass))
        .foregroundColor(.bg)
    }

    private func title(for format: ExportFormat) -> String {
        switch format {
        case .m4a: return "M4A — leve, bom p/ WhatsApp"
        case .wav: return "WAV — sem perdas"
        }
    }

    private func icon(for format: ExportFormat) -> String {
        switch format {
        case .m4a: return "paperplane"
        case .wav: return "waveform"
        }
    }

    private func export(_ format: ExportFormat) {
        exporting = format
        Task {
            do {
                let url = try await studio.exportMix(format: format)
                exporting = nil
                shareItem = StudioShareItem(url: url)
            } catch {
                exporting = nil
                onError("Não foi possível exportar: \(error.localizedDescription)")
            }
        }
    }
}
