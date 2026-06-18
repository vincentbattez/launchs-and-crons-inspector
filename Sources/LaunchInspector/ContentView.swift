import SwiftUI
import Foundation

/// A resolved group with its visible jobs (for the Table's ForEach).
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
        KeyPathComparator(\ScheduledJob.enabledState),       // enabled first (enabled < disabled < unknown)
        KeyPathComparator(\ScheduledJob.displayNameSortKey)  // then by name
    ]
    // Column customization (order + show/hide), persisted in UserDefaults.
    // TableColumnCustomization is Codable → we encode it as JSON via @AppStorage.
    @AppStorage("columnCustomization") private var columnCustomizationStore = Data()

    // Group creation (alert shared by the context menu and the detail view)
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var pendingGroupKeys: [String] = []

    // Delete + trash
    @State private var pendingDeleteIDs: Set<ScheduledJob.ID> = []
    @State private var showDeleteConfirm = false
    @State private var showTrash = false

    // MARK: - Derived data

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
                .searchable(text: $search, placement: .sidebar, prompt: "Filter by name, command, project…")
        } detail: {
            if let selectedJob {
                JobDetailView(job: selectedJob, requestNewGroup: { keys in
                    pendingGroupKeys = keys
                    showNewGroup = true
                })
            } else {
                ContentUnavailableView(
                    selection.isEmpty ? "Select a job" : selectionTitle,
                    systemImage: "list.bullet.rectangle",
                    description: Text(selection.isEmpty
                        ? "Choose a cron or an agent to see the details."
                        : "Right-click to group or hide them.")
                )
            }
        }
        .navigationTitle("Crons & Agents")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .alert("New group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { confirmNewGroup() }
            Button("Cancel", role: .cancel) { resetNewGroup() }
        } message: {
            Text("Give the new group a name.")
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                Task {
                    await model.delete(ids: ids)
                    selection.subtract(ids) // avoids a phantom selection on a deleted job
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showTrash) {
            TrashView().environment(model)
        }
        .alert("The action failed", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await model.refresh(userInitiated: false) // background poll: no scan indicator
            }
        }
    }

    private var subtitle: String {
        "\(model.jobs.count) jobs · \(model.enabledCount) enabled · \(model.disabledCount) disabled · \(model.hiddenCount) hidden"
    }

    private var selectionTitle: String {
        selection.count == 1 ? "1 job selected" : "\(selection.count) jobs selected"
    }

    // MARK: - Delete

    private var pendingDeleteJobs: [ScheduledJob] { model.jobs(for: pendingDeleteIDs) }

    private var deleteTitle: String {
        if let only = pendingDeleteJobs.first, pendingDeleteJobs.count == 1 {
            return "Delete “\(only.displayName)”?"
        }
        return "Delete \(pendingDeleteJobs.count) items?"
    }

    private var deleteMessage: String {
        var parts = ["The job will be unloaded then moved to the app's trash. You can restore it."]
        if pendingDeleteJobs.contains(where: { $0.scope == .global || $0.kind == .launchDaemon }) {
            parts.append("Some system items will ask for your administrator password.")
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
            .customizationID("status")
            .disabledCustomizationBehavior(.all)        // anchor column: always first, not movable

            TableColumn("Name", value: \.displayNameSortKey) { job in
                NameCell(job: job).dimmed(job.isDimmed)
            }
            .customizationID("name")
            .disabledCustomizationBehavior([.reorder, .visibility])  // leading: neither movable nor hideable

            TableColumn("Kind", value: \.kindSortKey) { job in
                Label(job.kind.label, systemImage: job.kind.icon)
                    .foregroundStyle(.secondary)
                    .dimmed(job.isDimmed)
            }
            .width(min: 95, ideal: 115)
            .customizationID("type")

            TableColumn("Scope", value: \.scopeSortKey) { job in
                Text(job.scope.label).foregroundStyle(.secondary).dimmed(job.isDimmed)
            }
            .width(min: 70, ideal: 80)
            .customizationID("scope")

            TableColumn("Schedule", value: \.scheduleDescription) { job in
                Text(job.scheduleDescription).lineLimit(1).dimmed(job.isDimmed)
            }
            .width(min: 150, ideal: 210)
            .customizationID("schedule")

            TableColumn("State", value: \.enabledState) { job in
                StatePill(job: job).dimmed(job.isDimmed)
            }
            .width(min: 130, ideal: 150)
            .customizationID("state")

            TableColumn("Activity", value: \.runCountSortKey) { job in
                ActivityCell(job: job).dimmed(job.isDimmed)
            }
            .width(min: 70, ideal: 90)
            .customizationID("activity")

            TableColumn("Installed", value: \.installDateSortKey) { job in
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
                        SectionHeader(title: bucket.group.name, count: bucket.jobs.count, systemImage: "folder", isExpanded: groupBinding(bucket.group.id))
                    }
                }
                if !ungroupedJobs.isEmpty {
                    Section(isExpanded: ungroupedBinding) {
                        ForEach(ungroupedJobs) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Ungrouped", count: ungroupedJobs.count, systemImage: "tray", isExpanded: ungroupedBinding)
                    }
                }
                if !hiddenJobs.isEmpty {
                    Section(isExpanded: hiddenBinding) {
                        ForEach(hiddenJobs) { TableRow($0) }
                    } header: {
                        SectionHeader(title: "Hidden", count: hiddenJobs.count, systemImage: "eye.slash", isExpanded: hiddenBinding)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: ScheduledJob.ID.self) { ids in
            contextMenu(for: ids)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for ids: Set<ScheduledJob.ID>) -> some View {
        let keys = model.configKeys(for: ids)
        if keys.isEmpty {
            EmptyView()
        } else {
            let targets = model.jobs(for: ids)
            if targets.contains(where: { $0.enabledState == .disabled }) {
                Button("Enable", systemImage: "play.circle") {
                    Task { await model.setEnabled(ids: ids, enabled: true) }
                }
            }
            if targets.contains(where: { $0.enabledState == .enabled }) {
                Button("Disable", systemImage: "pause.circle") {
                    Task { await model.setEnabled(ids: ids, enabled: false) }
                }
            }
            Divider()
            Menu("Move to") {
                ForEach(model.config.groups) { group in
                    Button(group.name) { model.setGroup(keys: keys, to: group.id) }
                }
                if !model.config.groups.isEmpty { Divider() }
                Button("New group…") {
                    pendingGroupKeys = keys
                    showNewGroup = true
                }
                Button("No group") { model.setGroup(keys: keys, to: nil) }
            }
            if model.anyHidden(keys: keys) {
                Button("Show", systemImage: "eye") { model.setHidden(keys: keys, false) }
            } else {
                Button("Hide", systemImage: "eye.slash") { model.setHidden(keys: keys, true) }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
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
                Section("Kinds") {
                    ForEach(JobKind.allCases) { kind in
                        Toggle(kind.label, isOn: kindBinding(kind))
                    }
                }
                Divider()
                Toggle("Enabled only", isOn: $enabledOnly)
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showTrash = true
            } label: {
                Label("Trash", systemImage: model.trash.isEmpty ? "trash" : "trash.fill")
            }
            .help(model.trash.isEmpty ? "Trash is empty" : "Trash (\(model.trash.count))")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isScanning)
        }
    }

    // MARK: - Bindings

    /// Reads/writes the column customization in UserDefaults (order + hidden columns).
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

    // MARK: - New group

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

// MARK: - Cells

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

    /// Subtitle: original label if renamed, otherwise the symlink's source project.
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
            .accessibilityLabel(helpText)
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
            case true: return .teal      // loaded, idle
            case false: return .orange   // not loaded
            default: return .secondary   // unknown runtime (daemon, root required)
            }
        }
    }

    private var helpText: String {
        switch job.enabledState {
        case .disabled: return "Disabled"
        case .unknown: return "Unknown state"
        case .enabled:
            if job.pid != nil { return "Enabled, running" }
            switch job.loaded {
            case true: return "Enabled and loaded (idle)"
            case false: return "Enabled, not loaded"
            default: return "Enabled — unknown runtime (root required)"
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
        if let pid = job.pid { return "running · pid \(pid)" }
        switch job.loaded {
        case true: return "loaded, idle"
        case false: return "not loaded"
        default: return "unknown runtime"
        }
    }
}

/// Run count since load (login/boot). Approximates “did it run this session”.
struct ActivityCell: View {
    let job: ScheduledJob

    var body: some View {
        switch label {
        case .count(let n):
            Text("\(n)×")
                .monospacedDigit()
                .help("\(n) run(s) since the session started")
        case .never:
            Text("never")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Loaded but never run since the session started")
        case .unavailable(let why):
            Text("—")
                .foregroundStyle(.tertiary)
                .help(why)
        }
    }

    private enum Label { case count(Int), never, unavailable(String) }

    private var label: Label {
        if job.kind == .cron { return .unavailable("Run counter unavailable for crons") }
        switch job.runCount {
        case .some(0): return .never
        case .some(let n): return .count(n)
        case .none: return .unavailable("Not loaded or state not readable")
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
            Label("\(title)  (\(count))", systemImage: systemImage)
        }
    }
}

// MARK: - Dimming modifier

private extension View {
    func dimmed(_ isDimmed: Bool) -> some View {
        opacity(isDimmed ? 0.45 : 1)
    }
}
