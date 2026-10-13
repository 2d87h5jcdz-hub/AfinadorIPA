import SwiftUI

/// Aviso de boas-vindas (primeira abertura) e "Sobre": o app é gratuito; doação é opcional.
struct AboutView: View {
    /// true na primeira abertura (botão "Começar"); false quando aberto pelo ⓘ ("Fechar").
    let isWelcome: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    static let projectURL = URL(string: "https://github.com/2d87h5jcdz-hub/PestanaEstudio")!
    static let donateURL = URL(string: "https://github.com/2d87h5jcdz-hub/PestanaEstudio#-apoie-o-projeto")!

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "Versão \(v)"
    }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    title
                    freeCard
                    donateCard
                    buttons
                    Text(version + " · código aberto no GitHub")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(.fg)
        .interactiveDismissDisabled(isWelcome)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "guitars.fill")
                .font(.system(size: 34))
                .foregroundColor(.brass)
            (Text("Pestana ").foregroundColor(.fg) + Text("Estúdio").foregroundColor(.brass))
                .font(.system(size: 30, weight: .heavy, design: .serif))
            Text(isWelcome ? "Bem-vindo!" : "Sobre o app")
                .font(.system(size: 15))
                .foregroundColor(.muted)
        }
        .padding(.top, 12)
    }

    private var freeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Gratuito, sem anúncios — e sempre será", systemImage: "heart.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.ok)
            Text("O Pestana Estúdio é um projeto gratuito, feito para quem toca. Ninguém deve cobrar por ele.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Se você pagou por este app, recebeu uma cópia não oficial. A versão oficial é baixada somente pela página do projeto no GitHub.")
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .studioPanel()
    }

    private var donateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quer apoiar?", systemImage: "hands.sparkles.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.brass)
            Text("Se o app te ajudou e você tiver condições, uma doação de qualquer valor é um incentivo para continuar melhorando o Pestana e criar novos projetos. A chave Pix está na página do projeto.")
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .studioPanel()
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                openURL(Self.donateURL)
            } label: {
                Label("Abrir a página do projeto", systemImage: "arrow.up.right.square")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.panel))
                    .overlay(Capsule().stroke(Color.brass))
                    .foregroundColor(.brass)
            }
            Button {
                dismiss()
            } label: {
                Text(isWelcome ? "Começar" : "Fechar")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.brass))
                    .foregroundColor(.bg)
            }
        }
    }
}
