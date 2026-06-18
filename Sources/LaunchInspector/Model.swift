import Foundation

/// Kind of scheduled job.
enum JobKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case launchAgent
    case launchDaemon
    case cron

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchAgent: "LaunchAgent"
        case .launchDaemon: "LaunchDaemon"
        case .cron: "Cron"
        }
    }

    var icon: String {
        switch self {
        case .launchAgent: "person.crop.circle"
        case .launchDaemon: "gearshape.2"
        case .cron: "clock"
        }
    }
}

/// Scope: who owns the job.
enum JobScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case user   // ~/Library + user crontab
    case global // /Library

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: "User"
        case .global: "Global"
        }
    }
}

/// Enabled/disabled state, derived from the launchd overrides database (`launchctl print-disabled`),
/// not just the file's `Disabled` key.
enum EnabledState: Int, Comparable, Sendable {
    case enabled
    case disabled
    case unknown

    static func < (lhs: EnabledState, rhs: EnabledState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }
}

/// A cron or launchd job unified for display.
struct ScheduledJob: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var label: String?
    var kind: JobKind
    var scope: JobScope

    /// Stable key used in the config file (launchd label, or "cron: <schedule> <cmd>").
    var configKey: String = ""

    // Customization from the config file (filled in by AppModel.merge()).
    var customName: String?
    var customDescription: String?
    var groupID: String?
    var isHidden: Bool = false
    var sourceLabel: String          // e.g.: "~/Library/LaunchAgents", "crontab"
    var path: String?                // file path (.plist) — nil for the crontab
    var symlinkTarget: String?       // resolved target if the .plist is a symlink
    var owningProject: String?       // project folder inferred from the symlink target

    // What it does
    var program: String?
    var arguments: [String]
    var commandLine: String

    // Declared log outputs (launchd) — basis for live log reading.
    var standardOutPath: String? = nil
    var standardErrorPath: String? = nil

    // Schedule
    var scheduleDescription: String
    var runAtLoad: Bool
    var keepAliveDescription: String?

    // Status (three distinct dimensions — see launchctl)
    var enabledState: EnabledState
    var loaded: Bool?                // nil = unknown (launchctl print returned nothing)
    var pid: Int?
    var lastExitStatus: Int?
    var runCount: Int?               // number of runs since load (login/boot); nil = unknown or cron

    // Metadata
    var installDate: Date? = nil     // .plist creation date (≈ installation); nil for crons
    var sessionType: String? = nil   // LimitLoadToSessionType (Aqua, LoginWindow, System…)
    var appVersion: String? = nil    // CFBundleShortVersionString if the program lives in a .app
    var machServices: [String] = []  // exposed Mach services → explain the "On demand"

    // Raw
    var rawContent: String

    /// Displayed name: custom name if it exists, otherwise the original label/command.
    var displayName: String { customName ?? name }

    /// "Dormant" job → displayed dimmed. We dim only when we KNOW it's not running:
    /// disabled, or (launchd) loaded/not loaded without a PID. A daemon with unknown runtime is NOT dimmed.
    var isDimmed: Bool {
        switch kind {
        case .cron:
            return enabledState != .enabled
        default:
            return enabledState == .disabled || (pid == nil && loaded != nil)
        }
    }

    // Sort keys for the Table columns
    var displayNameSortKey: String { displayName.lowercased() }
    var kindSortKey: String { kind.label }
    var scopeSortKey: String { scope.label }
    var runCountSortKey: Int { runCount ?? -1 }   // cron / unknown → at the bottom of the sort
    var installDateSortKey: Date { installDate ?? .distantPast }
    var appVersionSortKey: String { appVersion ?? "" }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return displayName.lowercased().contains(q)
            || name.lowercased().contains(q)
            || commandLine.lowercased().contains(q)
            || (customDescription?.lowercased().contains(q) ?? false)
            || (label?.lowercased().contains(q) ?? false)
            || (owningProject?.lowercased().contains(q) ?? false)
            || sourceLabel.lowercased().contains(q)
    }
}
