import SwiftUI

// MARK: - Lista de projetos (músicas)

@MainActor
struct StudioProjectListView: View {
    @ObservedObject var studio: StudioEngine
    @State private var renaming: StudioProject?
    @State private var renameText = ""
    @State private var deleting: StudioProject?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioNewProjectHeader(studio: studio)
                if studio.projects.isEmpty {
                    StudioEmptyState(studio: studio)
                } else {
                    projectList
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var projectList: some View {
        LazyVStack(spacing: 10) {
            ForEach(studio.projects) { project in
                StudioProjectCard(
                    project: project,
                    onOpen: { studio.open(project.id) },
                    onRename: {
                        renameText = project.name
                        renaming = project
                    },
                    onDelete: { deleting = project }
                )
            }
        }
        .alert("Renomear música", isPresented: renameBinding, presenting: renaming) { project in
            TextField("Nome", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { commitRename(project) }
        }
        .background(deleteAlertHost)
    }

    // Alerta em outra view para não disputar com o de renomear (iOS 16).
    private var deleteAlertHost: some View {
        Color.clear
            .alert("Apagar música?", isPresented: deleteBinding, presenting: deleting) { project in
                Button("Apagar", role: .destructive) { studio.deleteProject(project.id) }
                Button("Cancelar", role: .cancel) {}
            } message: { project in
                Text("“\(project.name)” e todas as faixas dela serão apagadas do iPhone. Não dá para desfazer.")
            }
    }

    private var renameBinding: Binding<Bool> {
        Binding<Bool>(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding<Bool>(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func commitRename(_ project: StudioProject) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { studio.rename(project.id, to: name) }
    }
}

// MARK: - Cabeçalho com "Nova música"

@MainActor
struct StudioNewProjectHeader: View {
    @ObservedObject var studio: StudioEngine
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Estúdio")
                .font(.system(size: 24, weight: .heavy, design: .serif))
            Spacer()
            Button {
                newName = ""
                showNew = true
            } label: {
                Label("Nova música", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.brass))
                    .foregroundColor(.bg)
            }
            .accessibilityLabel("Criar nova música")
        }
        .alert("Nova música", isPresented: $showNew) {
            TextField(defaultName, text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Criar") { create() }
        } message: {
            Text("Dê um nome para o projeto. Dá para mudar depois.")
        }
    }

    private var defaultName: String { "Música \(studio.projects.count + 1)" }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? defaultName : trimmed
        _ = studio.newProject(name: name)
    }
}

// MARK: - Cartão de projeto

struct StudioProjectCard: View {
    let project: StudioProject
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var details: String {
        let date = project.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(StudioUIFormat.tracksCount(project.tracks.count)) · \(Int(project.bpm)) BPM · \(date)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.brass)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.system(size: 19, weight: .semibold, design: .serif))
                            .lineLimit(1)
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(project.name), \(StudioUIFormat.tracksCount(project.tracks.count))")

            Menu {
                Button(action: onRename) { Label("Renomear", systemImage: "pencil") }
                Button(role: .destructive, action: onDelete) { Label("Apagar", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.muted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Opções de \(project.name)")
        }
        .studioPanel(padding: 12)
        .contextMenu {
            Button(action: onRename) { Label("Renomear", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Apagar", systemImage: "trash") }
        }
    }
}

// MARK: - Estado vazio

@MainActor
struct StudioEmptyState: View {
    @ObservedObject var studio: StudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.brass)
                .accessibilityHidden(true)
            Text("Grave em camadas")
                .font(.system(size: 26, weight: .heavy, design: .serif))
            Text("Grave o violão, depois ouça essa faixa enquanto grava a voz por cima, depois um solo… Cada gravação vira uma camada que você mixa do seu jeito.")
                .font(.system(size: 15))
                .foregroundColor(.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Crie uma música e escolha o BPM — o clique ajuda a manter o tempo.")
                step(2, "Toque em gravar. As faixas que já existem tocam enquanto você grava a próxima.")
                step(3, "Ajuste volume, pan e efeitos de cada faixa.")
                step(4, "Exporte e mande pelo WhatsApp ou salve no Arquivos.")
            }
            Label("Use fone de ouvido: assim o som das outras faixas não vaza para a nova gravação.", systemImage: "headphones")
                .font(.system(size: 13))
                .foregroundColor(.brass)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                _ = studio.newProject(name: "Música 1")
            } label: {
                Label("Criar primeira música", systemImage: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.brass))
                    .foregroundColor(.bg)
            }
            .padding(.top, 4)
        }
        .studioPanel(padding: 18)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.line))
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
