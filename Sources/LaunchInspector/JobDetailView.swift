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
                section("Customization", systemImage: "pencil") { customizationBlock }
                section("What it does", systemImage: "terminal") { commandBlock }
                section("Schedule", systemImage: "calendar") { scheduleBlock }
                section("Status", systemImage: "bolt.horizontal") { statusBlock }
                section("Live logs", systemImage: "list.bullet.rectangle") { LogsView(job: job) }
                if job.path != nil { section("Metadata", systemImage: "info.circle") { metadataBlock } }
                if job.path != nil { section("File", systemImage: "doc") { fileBlock } }
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.displayName)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Badge(text: job.kind.label, systemImage: job.kind.icon)
                Badge(text: job.scope.label, systemImage: "person.2")
                if job.isHidden { Badge(text: "Hidden", systemImage: "eye.slash") }
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

    // MARK: - Customization (editable)

    private var customizationBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField(job.label ?? "Display name", text: $draftName)
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
                    Button("Show", systemImage: "eye") {
                        model.setHidden(keys: [job.configKey], false)
                    }
                } else {
                    Button("Hide", systemImage: "eye.slash") {
                        model.setHidden(keys: [job.configKey], true)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var groupMenu: some View {
        Menu {
            Button("No group") { model.setGroup(keys: [job.configKey], to: nil) }
            if !model.config.groups.isEmpty { Divider() }
            ForEach(model.config.groups) { group in
                Button(group.name) { model.setGroup(keys: [job.configKey], to: group.id) }
            }
            Divider()
            Button("New group…") { requestNewGroup([job.configKey]) }
        } label: {
            Label(currentGroupName, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentGroupName: String {
        guard let id = job.groupID,
              let group = model.config.groups.first(where: { $0.id == id }) else {
            return "No group"
        }
        return group.name
    }

    // MARK: - Read-only blocks

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let program = job.program {
                LabeledRow(label: "Program", value: program)
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
            LabeledRow(label: "Trigger", value: job.scheduleDescription)
            if !job.machServices.isEmpty {
                LabeledRow(label: "Mach service (trigger)", value: job.machServices.joined(separator: "\n"))
            }
            LabeledRow(label: "At load (RunAtLoad)", value: job.runAtLoad ? "Yes" : "No")
            if let keepAlive = job.keepAliveDescription {
                LabeledRow(label: "KeepAlive", value: keepAlive)
            }
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = job.installDate {
                LabeledRow(label: "Installed on", value: date.formatted(date: .long, time: .omitted))
            }
            if let session = job.sessionType {
                LabeledRow(label: "Load session", value: session)
            }
            LabeledRow(label: "App version", value: job.appVersion ?? "—")
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledRow(label: "Enabled", value: job.enabledState.label)
            LabeledRow(label: "Loaded", value: loadedText)
            LabeledRow(label: "Running", value: job.pid.map { "Yes (pid \($0))" } ?? "No")
            LabeledRow(label: "Runs", value: runsText)
            if let status = job.lastExitStatus {
                LabeledRow(label: "Last exit status", value: "\(status)")
            }
        }
    }

    private var loadedText: String {
        switch job.loaded {
        case true: "Yes"
        case false: "No"
        default: "Unknown"
        }
    }

    /// launchd `runs` counter: number of runs since load (login for agents,
    /// boot for daemons). This is not a timestamp — launchd doesn't expose a date.
    private var runsText: String {
        if job.kind == .cron { return "— (unavailable for crons)" }
        switch job.runCount {
        case .some(0): return "0 — never since the session started"
        case .some(let n): return "\(n) since the session started"
        case .none: return "Unknown (not loaded or state unreadable)"
        }
    }

    private var fileBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = job.path {
                LabeledRow(label: "Path", value: path)
                if let target = job.symlinkTarget {
                    LabeledRow(label: "Symlink to", value: target)
                }
                if let project = job.owningProject {
                    LabeledRow(label: "Project", value: project)
                }
            }
            LabeledRow(label: "Config key", value: job.configKey)
            HStack {
                if let path = job.path {
                    Button("Reveal the job", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button("Open the config", systemImage: "gearshape") {
                    NSWorkspace.shared.open(AppModel.configURL)
                }
                Button("Copy the key", systemImage: "doc.on.doc") {
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
            Label("File content", systemImage: "chevron.left.forwardslash.chevron.right")
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

// MARK: - Live logs

/// Carries the log scroll viewport width up the tree so the content can fill it (left-aligned)
/// instead of being centered when lines are shorter than the viewport.
private struct ViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reads the selected item's logs live. Owns its `LogStreamer`; the stream is driven
/// by `.task(id:)` → a single stream at a time, restarted on selection change, stopped on
/// disappear. A short initial delay avoids spawning a process when scrolling quickly through the list.
private struct LogsView: View {
    let job: ScheduledJob
    @State private var streamer = LogStreamer()
    @State private var viewportWidth: CGFloat = 0
    @State private var visibleCount = 100

    private let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = streamer.unavailable {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(streamer.isRunning ? .green : .secondary)
                    Text(streamer.sourceLabel.isEmpty ? "Connecting…" : streamer.sourceLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                logScroll
            }
        }
        .task(id: job.id) {
            visibleCount = pageSize          // reset the window when switching jobs
            // Anti-churn: if the item changes before the delay ends, nothing is launched.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let source = LogStreamer.source(for: job) {
                await streamer.run(source)
            } else {
                streamer.setUnavailable("No log source available for this job.")
            }
        }
    }

    private var logScroll: some View {
        let hiddenCount = max(0, streamer.lines.count - visibleCount)
        // Nested single-axis scroll views (not one two-axis ScrollView, which doesn't wire the
        // horizontal gesture on macOS): outer scrolls rows vertically, inner shifts the whole
        // stack horizontally so long unwrapped lines move together.
        return ScrollView(.vertical) {
            ScrollView(.horizontal) {
                // Plain VStack (not lazy): ≤ visibleCount rows is cheap and a non-lazy stack
                // measures its widest child correctly, so wide content actually overflows.
                VStack(alignment: .leading, spacing: 1) {
                    if hiddenCount > 0 {
                        Button {
                            visibleCount += pageSize
                        } label: {
                            Label("Show \(min(pageSize, hiddenCount)) earlier (\(hiddenCount) hidden)",
                                  systemImage: "chevron.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 4)
                    }
                    ForEach(streamer.lines.suffix(visibleCount)) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(line.id)")
                                .foregroundStyle(.tertiary)
                                .frame(alignment: .trailing)
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
                // minWidth (not a fixed width): fills the viewport when lines are
                // short (flush left, no margin), overflows when they are long (scroll).
                .frame(minWidth: viewportWidth, alignment: .leading)
            }
        }
        // Start anchored at the end (newest line) and follow the live tail.
        .defaultScrollAnchor(.bottomLeading)
        .frame(height: 240)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        // Measure the viewport width off the scroll frame itself (not its content),
        // so the measurement never feeds back into the scroll layout.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ViewportWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ViewportWidthKey.self) { viewportWidth = $0 }
        .overlay {
            if streamer.lines.isEmpty {
                Text("Listening… new entries will appear here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
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

// MARK: - Small components

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
