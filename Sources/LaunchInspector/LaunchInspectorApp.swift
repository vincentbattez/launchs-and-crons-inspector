import SwiftUI
import AppKit

@main
struct LaunchInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // JSON mode: `LaunchInspector --dump-json` emits all resolved jobs (exact config key +
        // command, program, schedule, originating project) to stdout. Intended for Claude Code to
        // fill in name/description in config.json without having to locate/parse the .plist itself.
        if CommandLine.arguments.contains("--dump-json") {
            let arr: [[String: Any]] = JobScanner.scanAll().map { job in
                var d: [String: Any] = [
                    "configKey": job.configKey,
                    "name": job.name,
                    "kind": job.kind.label,
                    "scope": job.scope.label,
                    "source": job.sourceLabel,
                    "command": job.commandLine,
                    "schedule": job.scheduleDescription,
                    "enabled": job.enabledState.label,
                ]
                if let v = job.label { d["label"] = v }
                if let v = job.program { d["program"] = v }
                if !job.arguments.isEmpty { d["arguments"] = job.arguments }
                if let v = job.path { d["path"] = v }
                if let v = job.symlinkTarget { d["symlinkTarget"] = v }
                if let v = job.owningProject { d["project"] = v }
                if let v = job.keepAliveDescription { d["keepAlive"] = v }
                if let v = job.runCount { d["runCount"] = v }
                if let v = job.installDate { d["installDate"] = v.ISO8601Format() }
                if let v = job.sessionType { d["sessionType"] = v }
                if let v = job.appVersion { d["appVersion"] = v }
                if !job.machServices.isEmpty { d["machServices"] = job.machServices }
                return d
            }
            guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let json = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(Data("Failed to serialize jobs to JSON.\n".utf8))
                exit(1)
            }
            print(json)
            exit(0)
        }

        // Headless mode: `swift run LaunchInspector --dump` lists the jobs (config applied) without opening a window.
        if CommandLine.arguments.contains("--dump") {
            let config = AppModel.loadConfigFromDisk()
            for job in AppModel.applyConfig(JobScanner.scanAll(), config) {
                var groupName = ""
                if let id = job.groupID, let g = config.groups.first(where: { $0.id == id }) {
                    groupName = " [grp: \(g.name)]"
                }
                let pid = job.pid.map { " pid \($0)" } ?? ""
                let runs = job.runCount.map { " runs=\($0)" } ?? ""
                let hidden = job.isHidden ? " [HIDDEN]" : ""
                let dimmed = job.isDimmed ? " [dimmed]" : ""
                print("[\(job.enabledState.label)] \(job.kind.label) · \(job.displayName)\(groupName)\(hidden)\(dimmed)")
                print("    schedule : \(job.scheduleDescription)\(pid)\(runs)")
                if let desc = job.customDescription { print("    desc : \(desc)") }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1150, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            #if canImport(Sparkle)
            CheckForUpdatesCommand()
            #endif
        }
    }
}

/// Ensures a window appears in the foreground even when launched from the CLI (`swift run`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
