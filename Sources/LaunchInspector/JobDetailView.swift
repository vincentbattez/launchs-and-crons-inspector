import SwiftUI
import AppKit

struct JobDetailView: View {
    let job: ScheduledJob
    let requestNewGroup: ([String]) -> Void

    @Environment(AppModel.self) private var model

    @State private var editingKey = ""
    @State private var draftName = ""
    @State private var draftDescription = ""
    @FocusState private var focused: Field?

    private enum Field { case name, description }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Personnalisation", systemImage: "pencil") { customizationBlock }
                section("Ce que ça fait", systemImage: "terminal") { commandBlock }
                section("Planification", systemImage: "calendar") { scheduleBlock }
                section("Statut", systemImage: "bolt.horizontal") { statusBlock }
                section("Logs en direct", systemImage: "list.bullet.rectangle") { LogsView(job: job) }
                if job.path != nil { section("Métadonnées", systemImage: "info.circle") { metadataBlock } }
                if job.path != nil { section("Fichier", systemImage: "doc") { fileBlock } }
                if !job.rawContent.isEmpty { rawSection }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.displayName)
        .onChange(of: job.configKey, initial: true) { old, new in
            if old != new, !editingKey.isEmpty { flush() }
            editingKey = new
            draftName = job.customName ?? ""
            draftDescription = job.customDescription ?? ""
        }
        .onChange(of: focused) { _, newValue in
            if newValue == nil { flush() }
        }
        .onDisappear { flush() }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.displayName)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Badge(text: job.kind.label, systemImage: job.kind.icon)
                Badge(text: job.scope.label, systemImage: "person.2")
                if job.isHidden { Badge(text: "Masqué", systemImage: "eye.slash") }
                Spacer()
                statePill
            }
        }
    }

    private var statePill: some View {
        Text(job.enabledState.label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(stateColor.opacity(0.18), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch job.enabledState {
        case .enabled: .green
        case .disabled: .red
        case .unknown: .secondary
        }
    }

    // MARK: - Personnalisation (éditable)

    private var customizationBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nom personnalisé").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField(job.label ?? "Nom affiché", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .onSubmit { flush() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $draftDescription)
                    .focused($focused, equals: .description)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                groupMenu
                Spacer()
                if job.isHidden {
                    Button("Afficher", systemImage: "eye") {
                        model.setHidden(keys: [job.configKey], false)
                    }
                } else {
                    Button("Masquer", systemImage: "eye.slash") {
                        model.setHidden(keys: [job.configKey], true)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var groupMenu: some View {
        Menu {
            Button("Aucun groupe") { model.setGroup(keys: [job.configKey], to: nil) }
            if !model.config.groups.isEmpty { Divider() }
            ForEach(model.config.groups) { group in
                Button(group.name) { model.setGroup(keys: [job.configKey], to: group.id) }
            }
            Divider()
            Button("Nouveau groupe…") { requestNewGroup([job.configKey]) }
        } label: {
            Label(currentGroupName, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentGroupName: String {
        guard let id = job.groupID,
              let group = model.config.groups.first(where: { $0.id == id }) else {
            return "Aucun groupe"
        }
        return group.name
    }

    // MARK: - Blocs en lecture seule

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let program = job.program {
                LabeledRow(label: "Programme", value: program)
            }
            if !job.arguments.isEmpty {
                Text("Arguments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(job.arguments.enumerated()), id: \.offset) { _, arg in
                    Text(arg).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            codeBox(job.commandLine)
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledRow(label: "Déclenchement", value: job.scheduleDescription)
            if !job.machServices.isEmpty {
                LabeledRow(label: "Service Mach (déclencheur)", value: job.machServices.joined(separator: "\n"))
            }
            LabeledRow(label: "Au chargement (RunAtLoad)", value: job.runAtLoad ? "Oui" : "Non")
            if let keepAlive = job.keepAliveDescription {
                LabeledRow(label: "KeepAlive", value: keepAlive)
            }
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = job.installDate {
                LabeledRow(label: "Installé le", value: date.formatted(date: .long, time: .omitted))
            }
            if let session = job.sessionType {
                LabeledRow(label: "Session de chargement", value: session)
            }
            LabeledRow(label: "Version de l'app", value: job.appVersion ?? "—")
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledRow(label: "Activé", value: job.enabledState.label)
            LabeledRow(label: "Chargé", value: loadedText)
            LabeledRow(label: "En cours", value: job.pid.map { "Oui (pid \($0))" } ?? "Non")
            LabeledRow(label: "Exécutions", value: runsText)
            if let status = job.lastExitStatus {
                LabeledRow(label: "Dernier code de sortie", value: "\(status)")
            }
        }
    }

    private var loadedText: String {
        switch job.loaded {
        case true: "Oui"
        case false: "Non"
        default: "Inconnu"
        }
    }

    /// Compteur `runs` de launchd : nb d'exécutions depuis le chargement (login pour les agents,
    /// démarrage pour les daemons). Ce n'est pas un horodatage — launchd n'expose pas de date.
    private var runsText: String {
        if job.kind == .cron { return "— (indisponible pour les crons)" }
        switch job.runCount {
        case .some(0): return "0 — jamais depuis le démarrage de la session"
        case .some(let n): return "\(n) depuis le démarrage de la session"
        case .none: return "Inconnu (non chargé ou état non lisible)"
        }
    }

    private var fileBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = job.path {
                LabeledRow(label: "Chemin", value: path)
                if let target = job.symlinkTarget {
                    LabeledRow(label: "Symlink vers", value: target)
                }
                if let project = job.owningProject {
                    LabeledRow(label: "Projet", value: project)
                }
            }
            LabeledRow(label: "Clé de config", value: job.configKey)
            HStack {
                if let path = job.path {
                    Button("Révéler le job", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button("Ouvrir la config", systemImage: "gearshape") {
                    NSWorkspace.shared.open(AppModel.configURL)
                }
                Button("Copier la clé", systemImage: "doc.on.doc") {
                    copyToClipboard(job.configKey)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var rawSection: some View {
        DisclosureGroup {
            ScrollView(.horizontal) {
                Text(job.rawContent)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label("Contenu du fichier", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.headline)
        }
    }

    // MARK: - Helpers

    private func flush() {
        guard !editingKey.isEmpty else { return }
        model.setCustom(
            key: editingKey,
            name: draftName.trimmingCharacters(in: .whitespaces),
            description: draftDescription
        )
    }

    private func section(_ title: String, systemImage: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func codeBox(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Logs en direct

/// Lit les logs de l'item sélectionné en direct. Possède son `LogStreamer` ; le flux est piloté
/// par `.task(id:)` → un seul flux à la fois, redémarré au changement de sélection, arrêté à la
/// disparition. Un court délai initial évite de spawn un process quand on défile vite dans la liste.
private struct LogsView: View {
    let job: ScheduledJob
    @State private var streamer = LogStreamer()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = streamer.unavailable {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(streamer.isRunning ? .green : .secondary)
                    Text(streamer.sourceLabel.isEmpty ? "Connexion…" : streamer.sourceLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                logScroll
            }
        }
        .task(id: job.id) {
            // Anti-churn : si on change d'item avant la fin du délai, rien n'est lancé.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let source = LogStreamer.source(for: job) {
                await streamer.run(source)
            } else {
                streamer.setUnavailable("Aucune source de log disponible pour ce job.")
            }
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            // GeometryReader : on connaît la largeur du viewport pour forcer le contenu à la
            // remplir (sinon un ScrollView centre horizontalement tout contenu plus étroit que lui).
            GeometryReader { geo in
                // Deux axes : pas de retour à la ligne (unwrap) → les longues lignes défilent à l'horizontale.
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(streamer.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(line.id)")
                                    .foregroundStyle(.tertiary)
                                    .frame(minWidth: 44, alignment: .trailing)
                                    .fixedSize()
                                Text(line.text)
                                    .foregroundStyle(color(for: line.severity))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .padding(8)
                    // minWidth (et non width fixe) : remplit le viewport quand les lignes sont
                    // courtes (collé à gauche, pas de marge), déborde quand elles sont longues (scroll).
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if streamer.lines.isEmpty {
                        Text("En écoute… les nouvelles entrées apparaîtront ici.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .onChange(of: streamer.lines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottomLeading) }
                }
            }
            .frame(height: 240)
        }
    }

    private func color(for severity: LogStreamer.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .normal: .primary
        }
    }
}

// MARK: - Petits composants

private struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
