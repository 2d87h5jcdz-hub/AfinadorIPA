import SwiftUI

// MARK: - Entrada da aba Estúdio

@MainActor
struct StudioView: View {
    @ObservedObject var studio: StudioEngine

    var body: some View {
        ZStack(alignment: .top) {
            Color.bg.ignoresSafeArea()
            content
            errorBanner
        }
        .foregroundColor(.fg)
        .onAppear { studio.activate() }
        .onDisappear { studio.deactivate() }
    }

    @ViewBuilder
    private var content: some View {
        if studio.project != nil {
            StudioProjectView(studio: studio)
        } else {
            StudioProjectListView(studio: studio)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = studio.lastError {
            StudioErrorBanner(message: message) {
                withAnimation(.easeOut(duration: 0.2)) { studio.clearError() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Peças visuais compartilhadas pelas telas do Estúdio

enum StudioUIFormat {
    /// 1:05.3
    static func time(_ t: TimeInterval) -> String {
        let safe: Double = (t.isFinite && t > 0) ? t : 0
        let whole = Int(safe)
        let minutes = whole / 60
        let seconds = whole % 60
        let tenths = Int((safe - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    /// Para leitores de tela: "1 minuto e 5 segundos".
    static func spokenTime(_ t: TimeInterval) -> String {
        let safe: Double = (t.isFinite && t > 0) ? t : 0
        let whole = Int(safe)
        let minutes = whole / 60
        let seconds = whole % 60
        if minutes == 0 { return "\(seconds) segundos" }
        return "\(minutes) minutos e \(seconds) segundos"
    }

    static func tracksCount(_ n: Int) -> String {
        n == 1 ? "1 faixa" : "\(n) faixas"
    }
}

struct StudioPanelModifier: ViewModifier {
    var padding: CGFloat = 14
    var stroke: Color = .line

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(stroke))
    }
}

extension View {
    func studioPanel(padding: CGFloat = 14, stroke: Color = .line) -> some View {
        modifier(StudioPanelModifier(padding: padding, stroke: stroke))
    }
}

/// Medidor de nível horizontal (0…1).
struct StudioMeterBar: View {
    var level: Float
    var height: CGFloat = 8

    private var clamped: CGFloat {
        let v: Float = level.isFinite ? min(max(level, 0), 1) : 0
        return CGFloat(v)
    }

    private var fillColor: Color {
        if clamped > 0.9 { return .off }
        if clamped > 0.65 { return .brass }
        return .ok
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.line)
                Capsule()
                    .fill(fillColor)
                    .frame(width: geo.size.width * clamped)
                    .animation(.linear(duration: 0.06), value: clamped)
            }
        }
        .frame(height: height)
    }
}

struct StudioErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.off)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.muted)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Fechar aviso")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.off.opacity(0.7)))
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Erro: \(message)")
    }
}

/// Botão-pílula pequeno usado em vários lugares (M, S, FX…).
struct StudioChip: View {
    let title: String
    var systemImage: String? = nil
    var isOn: Bool = false
    var onColor: Color = .brass
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(isOn ? onColor : Color.bg))
            .overlay(Capsule().stroke(isOn ? onColor : Color.line))
            .foregroundColor(isOn ? Color.bg : Color.fg)
        }
        .buttonStyle(.plain)
    }
}
