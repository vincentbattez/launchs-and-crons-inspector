import SwiftUI
import Foundation

/// Un groupe résolu avec ses jobs visibles (pour le ForEach du Table).
private struct GroupBucket: Identifiable {
    let group: ConfigGroup
    let jobs: [ScheduledJob]
    var id: String { group.id }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var selection = Set<ScheduledJob.ID>()
    @State private var search = ""
    @State private var kindFilter: Set<JobKind> = Set(JobKind.allCases)
    @State private var enabledOnly = false
    @State private var sortOrder = [
        KeyPathComparator(\ScheduledJob.enabledState),       // activés d'abord (enabled < disabled < unknown)
        KeyPathComparator(\ScheduledJob.displayNameSortKey)  // puis par nom
    ]
    // Personnalisation des colonnes (ordre + affichage/masquage), persistée dans UserDefaults.
    // TableColumnCustomization est Codable → on l'encode en JSON via @AppStorage.
    @AppStorage("columnCustomization") private var columnCustomizationStore = Data()

    // Création de groupe (alerte partagée par le menu contextuel et le détail)
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var pendingGroupKeys: [String] = []

    // Suppression + corbeille
    @State private var pendingDeleteIDs: Set<ScheduledJob.ID> = []
    @State private var showDeleteConfirm = false
    @State private var showTrash = false

    // MARK: - Données dérivées

    private var filtered: [ScheduledJob] {
        model.jobs
            .filter { job in
                kindFilter.contains(job.kind)
                    && (!enabledOnly || job.enabledState == .enabled)
                    && (search.isEmpty || job.matches(search))
            }
            .sorted(using: sortOrder)
    }

    private var visibleJobs: [ScheduledJob] { filtered.filter { !$0.isHidden } }
    private var hiddenJobs: [ScheduledJob] { filtered.filter(\.isHidden) }

    private var groupBuckets: [GroupBucket] {
        model.config.groups.compactMap { group in
            let jobs = visibleJobs.filter { $0.groupID == group.id }
            return jobs.isEmpty ? nil : GroupBucket(group: group, jobs: jobs)
        }
    }

    private var ungroupedJobs: [ScheduledJob] {
        visibleJobs.filter { $0.groupID == nil }
    }

    private var selectedJob: ScheduledJob? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.jobs.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            jobTable
                .frame(minWidth: 580)
                .searchable(text: $search, placement: .sidebar, prompt: "Filtrer par nom, commande, projet…")
        } detail: {
            if let selectedJob {
                JobDetailView(job: selectedJob, requestNewGroup: { keys in
                    pendingGroupKeys = keys
                    showNewGroup = true
                })
            } else {
                ContentUnavailableView(
                    selection.isEmpty ? "Sélectionne un job" : "\(selection.count) jobs sélectionnés",
                    systemImage: "list.bullet.rectangle",
                    description: Text(selection.isEmpty
                        ? "Choisis un cron ou un agent pour voir le détail."
                        : "Clic droit pour les grouper ou les masquer.")
                )
            }
        }
        .navigationTitle("Crons & Agents")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .alert("Nouveau groupe", isPresented: $showNewGroup) {
            TextField("Nom du groupe", text: $newGroupName)
            Button("Créer") { confirmNewGroup() }
            Button("Annuler", role: .cancel) { resetNewGroup() }
        } message: {
            Text("Donne un nom au nouveau groupe.")
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                Task { await model.delete(ids: ids) }
            }
            Button("Annuler", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showTrash) {
            TrashView().environment(model)
        }
        .alert("L'action a échoué", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await model.refresh()
            }
        }
    }

    private var subtitle: String {
        "\(model.jobs.count) jobs · \(model.enabledCount) activés · \(model.disabledCount) désactivés · \(model.hiddenCount) masqués"
    }

    // MARK: - Suppression

    private var pendingDeleteJobs: [ScheduledJob] { model.jobs(for: pendingDeleteIDs) }

    private var deleteTitle: String {
        if let only = pendingDeleteJobs.first, pendingDeleteJobs.count == 1 {
            return "Supprimer « \(only.displayName) » ?"
        }
        return "Supprimer \(pendingDeleteJobs.count) éléments ?"
    }

    private var deleteMessage: String {
        var parts = ["Le job sera déchargé puis déplacé dans la corbeille de l'app. Tu pourras le restaurer."]
        if pendingDeleteJobs.contains(where: { $0.scope == .global || $0.kind == .launchDaemon }) {
            parts.append("Certains éléments système demanderont ton mot de passe administrateur.")
        }
        return parts.joined(separator: "\n\n")
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )
    }

    // MARK: - Table

    private var jobTable: some View {
        Table(of: ScheduledJob.self, selection: $selection, sortOrder: $sortOrder,
              columnCustomization: columnCustomizationBinding) {
            TableColumn("") { job in
                StatusDot(job: job).dimmed(job.isDimmed)
            }
            .width(22)

            TableColumn("Nom", value: \.displayNameSortKey) { job in
                NameCell(job: job).dimmed(job.isDimmed)
            }

            TableColumn("Type", value: \.kindSortKey) { job in
                Label(job.kind.label, systemImage: job.kind.icon)
                    .foregroundStyle(.secondary)
                    .dimmed(job.isDimmed)
            }
            .width(min: 95, ideal: 115)
            .customizationID("type")

            TableColumn("Portée", value: \.scopeSortKey) { job in
                Text(job.scope.label).foregroundStyle(.secondary).dimmed(job.isDimmed)
            }
            .width(min: 70, ideal: 80)
            .customizationID("scope")

            TableColumn("Planification", value: \.scheduleDescription) { job in
                Text(job.scheduleDescription).lineLimit(1).dimmed(job.isDimmed)
            }
            .width(min: 150, ideal: 210)
            .customizationID("schedule")

            TableColumn("État", value: \.enabledState) { job in
                StatePill(job: job).dimmed(job.isDimmed)
            }
            .width(min: 130, ideal: 150)
            .customizationID("state")

            TableColumn("Activité", value: \.runCountSortKey) { job in
                ActivityCell(job: job).dimmed(job.isDimmed)
            }
            .width(min: 70, ideal: 90)
            .customizationID("activity")

            TableColumn("Installé", value: \.installDateSortKey) { job in
                Group {
                    if let date = job.installDate {
                        Text(date.formatted(.dateTime.year().month(.abbreviated).day()))
                            .help(date.formatted(date: .long, time: .shortened))
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .dimmed(job.isDimmed)
            }
            .width(min: 90, ideal: 110)
            .customizationID("installed")

            TableColumn("Version", value: \.appVersionSortKey) { job in
                Text(job.appVersion ?? "—")
                    .foregroundStyle(job.appVersion == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .dimmed(job.isDimmed)
            }
            .width(min: 70, ideal: 95)
            .customizationID("version")
        } rows: {
            if groupBuckets.isEmpty && hiddenJobs.isEmpty {
                ForEach(visibleJobs) { TableRow($0) }
            } else {
                ForEach(groupBuckets) { bucket in
                    Section(isExpanded: groupBinding(bucket.group.id)) {
                        ForEach(bucket.jobs) { TableRow($0) }
                    } header: {
                        SectionHeader(title: bucket.group.name, count: bucket.jobs.count, systemImage: "folder")
                    }
                }
                if !ungroupedJobs.isEmpty {
                    Section(isExpanded: ungroupedBinding) {
                        ForEach(ungroupedJobs) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Non groupé", count: ungroupedJobs.count, systemImage: "tray")
                    }
                }
                if !hiddenJobs.isEmpty {
                    Section(isExpanded: hiddenBinding) {
                        ForEach(hiddenJobs) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Masqués", count: hiddenJobs.count, systemImage: "eye.slash")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: ScheduledJob.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    // MARK: - Menu contextuel

    @ViewBuilder
    private func contextMenu(for ids: Set<ScheduledJob.ID>) -> some View {
        let keys = model.configKeys(for: ids)
        if keys.isEmpty {
            EmptyView()
        } else {
            let targets = model.jobs(for: ids)
            if targets.contains(where: { $0.enabledState == .disabled }) {
                Button("Activer", systemImage: "play.circle") {
                    Task { await model.setEnabled(ids: ids, enabled: true) }
                }
            }
            if targets.contains(where: { $0.enabledState == .enabled }) {
                Button("Désactiver", systemImage: "pause.circle") {
                    Task { await model.setEnabled(ids: ids, enabled: false) }
                }
            }
            Divider()
            Menu("Déplacer vers") {
                ForEach(model.config.groups) { group in
                    Button(group.name) { model.setGroup(keys: keys, to: group.id) }
                }
                if !model.config.groups.isEmpty { Divider() }
                Button("Nouveau groupe…") {
                    pendingGroupKeys = keys
                    showNewGroup = true
                }
                Button("Aucun groupe") { model.setGroup(keys: keys, to: nil) }
            }
            if model.anyHidden(keys: keys) {
                Button("Afficher", systemImage: "eye") { model.setHidden(keys: keys, false) }
            } else {
                Button("Masquer", systemImage: "eye.slash") { model.setHidden(keys: keys, true) }
            }
            Divider()
            Button("Supprimer…", systemImage: "trash", role: .destructive) {
                pendingDeleteIDs = ids
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Section("Types") {
                    ForEach(JobKind.allCases) { kind in
                        Toggle(kind.label, isOn: kindBinding(kind))
                    }
                }
                Divider()
                Toggle("Activés uniquement", isOn: $enabledOnly)
            } label: {
                Label("Filtres", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showTrash = true
            } label: {
                Label("Corbeille", systemImage: model.trash.isEmpty ? "trash" : "trash.fill")
            }
            .help(model.trash.isEmpty ? "Corbeille vide" : "Corbeille (\(model.trash.count))")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isScanning)
        }
    }

    // MARK: - Bindings

    /// Lit/écrit la personnalisation des colonnes dans UserDefaults (ordre + colonnes masquées).
    private var columnCustomizationBinding: Binding<TableColumnCustomization<ScheduledJob>> {
        Binding(
            get: {
                (try? JSONDecoder().decode(TableColumnCustomization<ScheduledJob>.self, from: columnCustomizationStore))
                    ?? TableColumnCustomization<ScheduledJob>()
            },
            set: { columnCustomizationStore = (try? JSONEncoder().encode($0)) ?? Data() }
        )
    }

    private func kindBinding(_ kind: JobKind) -> Binding<Bool> {
        Binding(
            get: { kindFilter.contains(kind) },
            set: { isOn in
                if isOn { kindFilter.insert(kind) } else { kindFilter.remove(kind) }
            }
        )
    }

    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !(model.config.groups.first { $0.id == id }?.collapsed ?? false) },
            set: { expanded in model.setGroupCollapsed(id, !expanded) }
        )
    }

    private var ungroupedBinding: Binding<Bool> {
        Binding(
            get: { !model.config.ungroupedCollapsed },
            set: { expanded in model.setUngroupedCollapsed(!expanded) }
        )
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(
            get: { !model.config.hiddenCollapsed },
            set: { expanded in model.setHiddenCollapsed(!expanded) }
        )
    }

    // MARK: - Nouveau groupe

    private func confirmNewGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { resetNewGroup(); return }
        let id = model.createGroup(name: name)
        if !pendingGroupKeys.isEmpty { model.setGroup(keys: pendingGroupKeys, to: id) }
        resetNewGroup()
    }

    private func resetNewGroup() {
        newGroupName = ""
        pendingGroupKeys = []
    }
}

// MARK: - Cellules

private struct NameCell: View {
    let job: ScheduledJob

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(job.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if job.customDescription != nil {
                    Image(systemName: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(job.customDescription ?? "")
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Sous-titre : label d'origine si renommé, sinon projet d'origine du symlink.
    private var subtitle: String? {
        if job.customName != nil, let label = job.label { return label }
        return job.owningProject
    }
}

struct StatusDot: View {
    let job: ScheduledJob

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(helpText)
            .imageScale(.small)
    }

    private var symbol: String {
        switch job.enabledState {
        case .disabled: "minus.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .enabled: job.pid != nil ? "circle.fill" : "circle"
        }
    }

    private var color: Color {
        switch job.enabledState {
        case .disabled: return .red
        case .unknown: return .secondary
        case .enabled:
            if job.pid != nil { return .green }
            switch job.loaded {
            case true: return .teal      // chargé, inactif
            case false: return .orange   // non chargé
            default: return .secondary   // runtime inconnu (daemon, root requis)
            }
        }
    }

    private var helpText: String {
        switch job.enabledState {
        case .disabled: return "Désactivé"
        case .unknown: return "État inconnu"
        case .enabled:
            if job.pid != nil { return "Activé, en cours d'exécution" }
            switch job.loaded {
            case true: return "Activé et chargé (inactif)"
            case false: return "Activé, non chargé"
            default: return "Activé — runtime inconnu (root requis)"
            }
        }
    }
}

struct StatePill: View {
    let job: ScheduledJob

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(job.enabledState.label)
                .font(.callout)
            if let detail = runtimeDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeDetail: String? {
        if job.kind == .cron { return nil }
        if let pid = job.pid { return "en cours · pid \(pid)" }
        switch job.loaded {
        case true: return "chargé, inactif"
        case false: return "non chargé"
        default: return "runtime inconnu"
        }
    }
}

/// Nombre d'exécutions depuis le chargement (login/boot). Approxime « a-t-il tourné cette session ».
struct ActivityCell: View {
    let job: ScheduledJob

    var body: some View {
        switch label {
        case .count(let n):
            Text("\(n)×")
                .monospacedDigit()
                .help("\(n) exécution(s) depuis le démarrage de la session")
        case .never:
            Text("jamais")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Chargé mais jamais exécuté depuis le démarrage de la session")
        case .unavailable(let why):
            Text("—")
                .foregroundStyle(.tertiary)
                .help(why)
        }
    }

    private enum Label { case count(Int), never, unavailable(String) }

    private var label: Label {
        if job.kind == .cron { return .unavailable("Compteur d'exécutions indisponible pour les crons") }
        switch job.runCount {
        case .some(0): return .never
        case .some(let n): return .count(n)
        case .none: return .unavailable("Non chargé ou état non lisible")
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        Label("\(title)  (\(count))", systemImage: systemImage)
    }
}

// MARK: - Modificateur de grisage

private extension View {
    func dimmed(_ isDimmed: Bool) -> some View {
        opacity(isDimmed ? 0.45 : 1)
    }
}
