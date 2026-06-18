import Foundation

/// Customization of a job: renaming, description, group, hiding.
/// Tolerant decoding: an absent field takes its default value (the agent can write only what it wants).
struct ConfigItem: Codable, Sendable {
    var name: String
    var description: String
    var group: String?
    var hidden: Bool

    init(name: String = "", description: String = "", group: String? = nil, hidden: Bool = false) {
        self.name = name
        self.description = description
        self.group = group
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// A user-defined group. `collapsed` = persisted UI state.
struct ConfigGroup: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var collapsed: Bool

    init(id: String, name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// Root of the `config.json` file.
struct AppConfig: Codable, Sendable {
    var help: String?
    var version: Int
    var groups: [ConfigGroup]
    var items: [String: ConfigItem]
    var ungroupedCollapsed: Bool
    var hiddenCollapsed: Bool

    enum CodingKeys: String, CodingKey {
        case help = "_help"
        case version, groups, items, ungroupedCollapsed, hiddenCollapsed
    }

    init() {
        help = AppConfig.helpText
        version = 1
        groups = []
        items = [:]
        ungroupedCollapsed = false
        hiddenCollapsed = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = (try c.decodeIfPresent([ConfigGroup].self, forKey: .groups) ?? [])
            .filter { !$0.id.isEmpty }
        items = try c.decodeIfPresent([String: ConfigItem].self, forKey: .items) ?? [:]
        ungroupedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .ungroupedCollapsed) ?? false
        hiddenCollapsed = try c.decodeIfPresent(Bool.self, forKey: .hiddenCollapsed) ?? true
    }

    static let helpText = """
        LaunchInspector customization file — editable by Claude Code or via the app.
        • items: key→customization dictionary. The KEY is provided: launchd Label (e.g. com.vincent.x) \
        or 'cron: <schedule> <command>'. Do NOT invent keys; the app creates an empty stub for each detected job.
        • item.name: name displayed instead of the label (empty = original label).
        • item.description: free-form note displayed in the detail.
        • item.group: id of a group defined in 'groups' (absent/null = ungrouped).
        • item.hidden: true = moves the job into the collapsed 'Hidden' section at the very bottom.
        • groups: ordered list {id, name, collapsed}. PRESERVE 'collapsed' (UI state) when editing.
        • ungroupedCollapsed / hiddenCollapsed: collapsed state of the special sections — preserve these too.
        """
}
