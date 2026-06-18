import Foundation

/// Launches a binary and returns its standard output. Synchronous, to be called off the main thread.
enum Shell {
    static func run(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // we ignore stderr
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Scans crons + user and global LaunchAgents/LaunchDaemons.
enum JobScanner {

    static func scanAll() -> [ScheduledJob] {
        let disabledMap = parseDisabledMap()
        let listMap = parseListMap()
        let home = NSHomeDirectory()

        var jobs: [ScheduledJob] = []
        jobs += scanPlistDir(home + "/Library/LaunchAgents",
                             kind: .launchAgent, scope: .user,
                             source: "~/Library/LaunchAgents",
                             disabledMap: disabledMap, listMap: listMap)
        jobs += scanPlistDir("/Library/LaunchAgents",
                             kind: .launchAgent, scope: .global,
                             source: "/Library/LaunchAgents",
                             disabledMap: disabledMap, listMap: listMap)
        jobs += scanPlistDir("/Library/LaunchDaemons",
                             kind: .launchDaemon, scope: .global,
                             source: "/Library/LaunchDaemons",
                             disabledMap: disabledMap, listMap: listMap)
        jobs += scanCrontab()
        fillRunCounts(&jobs)
        return jobs
    }

    // MARK: - Run count + runtime (launchctl print, without root)

    /// Info extracted from `launchctl print <domain>/<label>`.
    private struct PrintInfo {
        var present = false      // print returned something (job bootstrapped in the domain)
        var runs: Int?
        var pid: Int?
        var lastExit: Int?
    }

    /// `runs`, `pid`, `last exit code` from the top of the dump (we ignore nested `state = active`
    /// by keeping only the 1st occurrence of each key). Works without root for gui and system.
    private static func printInfo(domain: String, label: String) -> PrintInfo {
        let text = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard !text.isEmpty else { return PrintInfo() }
        var info = PrintInfo(present: true)
        for raw in text.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if info.runs == nil, t.hasPrefix("runs =") {
                info.runs = Int(t.dropFirst("runs =".count).trimmingCharacters(in: .whitespaces))
            } else if info.pid == nil, t.hasPrefix("pid =") {
                info.pid = Int(t.dropFirst("pid =".count).trimmingCharacters(in: .whitespaces))
            } else if info.lastExit == nil, t.hasPrefix("last exit code =") {
                info.lastExit = Int(t.dropFirst("last exit code =".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return info
    }

    /// Fills `runCount` for all launchd jobs, and completes loaded/pid/lastExit when they
    /// were unknown (daemons missing from `launchctl list`). One Process call per job, launched in
    /// parallel (~0.4 s for ~33 jobs instead of ~3 s sequentially).
    private static func fillRunCounts(_ jobs: inout [ScheduledJob]) {
        let uid = getuid()
        // Immutable targets (Sendable): index in `jobs`, launchctl domain, label.
        let requests: [(index: Int, domain: String, label: String)] = jobs.indices.compactMap { i in
            let domain: String
            switch jobs[i].kind {
            case .launchAgent: domain = "gui/\(uid)"
            case .launchDaemon: domain = "system"
            case .cron: return nil
            }
            guard let label = jobs[i].label else { return nil }
            return (i, domain, label)
        }
        guard !requests.isEmpty else { return }

        // Writes to disjoint indices → safe. The mutable buffer expresses this invariant to the
        // compiler; `nonisolated(unsafe)` lifts the Sendable check on the shared pointer.
        var results = [PrintInfo](repeating: PrintInfo(), count: requests.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: buffer.count) { k in
                buffer[k] = printInfo(domain: requests[k].domain, label: requests[k].label)
            }
        }

        for (k, req) in requests.enumerated() {
            let info = results[k]
            let i = req.index
            jobs[i].runCount = info.runs
            // Complete the runtime only when it was unknown (daemons) AND print responded.
            if info.present, jobs[i].loaded == nil {
                jobs[i].loaded = true
                if jobs[i].pid == nil { jobs[i].pid = info.pid }
                if jobs[i].lastExitStatus == nil { jobs[i].lastExitStatus = info.lastExit }
            }
        }
    }

    // MARK: - launchd status

    /// Map `label -> isDisabled`, merging the gui and system domains
    /// (both work without root via `launchctl print-disabled`).
    private static func parseDisabledMap() -> [String: Bool] {
        var map: [String: Bool] = [:]
        let uid = getuid()
        for text in [Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]),
                     Shell.run("/bin/launchctl", ["print-disabled", "system"])] {
            for line in text.split(separator: "\n") {
                guard line.contains("=>") else { continue }
                let parts = line.components(separatedBy: "=>")
                guard parts.count == 2 else { continue }
                let label = parts[0]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let state = parts[1].trimmingCharacters(in: .whitespaces)
                map[label] = (state == "disabled")
            }
        }
        return map
    }

    /// Map `label -> (pid, lastExitStatus)` from `launchctl list` (gui domain).
    private static func parseListMap() -> [String: (pid: Int?, status: Int?)] {
        var map: [String: (pid: Int?, status: Int?)] = [:]
        let text = Shell.run("/bin/launchctl", ["list"])
        for (index, line) in text.split(separator: "\n").enumerated() {
            if index == 0 { continue } // PID Status Label header
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            map[cols[2]] = (pid: Int(cols[0]), status: Int(cols[1]))
        }
        return map
    }

    // MARK: - Plists

    private static func scanPlistDir(_ dir: String, kind: JobKind, scope: JobScope,
                                     source: String,
                                     disabledMap: [String: Bool],
                                     listMap: [String: (pid: Int?, status: Int?)]) -> [ScheduledJob] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return items
            .filter { $0.hasSuffix(".plist") }
            .sorted()
            .compactMap { name in
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                return makeJob(url: url, kind: kind, scope: scope, source: source,
                               disabledMap: disabledMap, listMap: listMap)
            }
    }

    private static func makeJob(url: URL, kind: JobKind, scope: JobScope, source: String,
                                disabledMap: [String: Bool],
                                listMap: [String: (pid: Int?, status: Int?)]) -> ScheduledJob? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }

        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent

        // Program / arguments
        let arguments = (dict["ProgramArguments"] as? [String]) ?? []
        let programKey = dict["Program"] as? String
        let program = programKey ?? arguments.first
        let commandLine: String
        if !arguments.isEmpty {
            commandLine = arguments.joined(separator: " ")
        } else if let programKey {
            commandLine = programKey
        } else {
            commandLine = "—"
        }

        // Symlink / project
        var symlinkTarget: String?
        var owningProject: String?
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : url.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
            symlinkTarget = resolved.path
            owningProject = resolved.deletingLastPathComponent().lastPathComponent
        }

        // Status
        let enabledState: EnabledState
        if let disabled = disabledMap[label] {
            enabledState = disabled ? .disabled : .enabled
        } else if (dict["Disabled"] as? Bool) == true {
            enabledState = .disabled
        } else {
            enabledState = .enabled
        }

        let loaded: Bool?
        let pid: Int?
        let lastExit: Int?
        if let entry = listMap[label] {
            loaded = true
            pid = entry.pid
            lastExit = entry.status
        } else if kind == .launchDaemon {
            loaded = nil // unknown without root
            pid = nil
            lastExit = nil
        } else {
            loaded = false
            pid = nil
            lastExit = nil
        }

        // Declared log outputs
        let stdoutPath = dict["StandardOutPath"] as? String
        let stderrPath = dict["StandardErrorPath"] as? String

        // Metadata
        let machServices = (dict["MachServices"] as? [String: Any])?.keys.sorted() ?? []
        let sessionType = describeSessionType(dict["LimitLoadToSessionType"], kind: kind)
        let appVersion = appVersion(forProgram: program)
        let installDate = creationDate(ofPath: url.path)

        return ScheduledJob(
            id: url.path,
            name: label,
            label: label,
            kind: kind,
            scope: scope,
            configKey: label,
            sourceLabel: source,
            path: url.path,
            symlinkTarget: symlinkTarget,
            owningProject: owningProject,
            program: program,
            arguments: arguments,
            commandLine: commandLine,
            standardOutPath: stdoutPath,
            standardErrorPath: stderrPath,
            scheduleDescription: describeSchedule(dict),
            runAtLoad: (dict["RunAtLoad"] as? Bool) == true,
            keepAliveDescription: describeKeepAlive(dict["KeepAlive"]),
            enabledState: enabledState,
            loaded: loaded,
            pid: pid,
            lastExitStatus: lastExit,
            installDate: installDate,
            sessionType: sessionType,
            appVersion: appVersion,
            machServices: machServices,
            rawContent: rawContent(from: data)
        )
    }

    // MARK: - Metadata (.plist + filesystem)

    /// File creation date (birthtime via lstat — that of the symlink itself, not its target),
    /// falling back to the modification date if the birthtime is absent.
    private static func creationDate(ofPath path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let bt = st.st_birthtimespec
        if bt.tv_sec > 0 {
            return Date(timeIntervalSince1970: TimeInterval(bt.tv_sec) + TimeInterval(bt.tv_nsec) / 1_000_000_000)
        }
        let mt = st.st_mtimespec
        return mt.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(mt.tv_sec) + TimeInterval(mt.tv_nsec) / 1_000_000_000) : nil
    }

    /// `CFBundleShortVersionString` if the program lives in a `.app`.
    private static func appVersion(forProgram program: String?) -> String? {
        guard let program, let r = program.range(of: ".app/") else { return nil }
        let bundle = String(program[..<r.lowerBound]) + ".app"
        let info = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    /// `LimitLoadToSessionType` → text; defaults to "Aqua" (agent) or "System" (daemon).
    private static func describeSessionType(_ raw: Any?, kind: JobKind) -> String {
        if let s = raw as? String { return s }
        if let a = raw as? [String] { return a.joined(separator: ", ") }
        return kind == .launchDaemon ? "System" : "Aqua"
    }

    private static func rawContent(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8),
           text.contains("<plist") || text.hasPrefix("<?xml") {
            return text
        }
        // binary plist → XML conversion for display
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return text
        }
        return "(unreadable binary content)"
    }

    // MARK: - launchd schedule

    private static func describeSchedule(_ dict: [String: Any]) -> String {
        var triggers: [String] = []

        if let interval = intValue(dict["StartInterval"]) {
            triggers.append(describeInterval(interval))
        }
        if let cal = dict["StartCalendarInterval"] as? [String: Any] {
            triggers.append(describeCalendar(cal))
        } else if let cals = dict["StartCalendarInterval"] as? [[String: Any]] {
            triggers.append(summarizeCalendars(cals.map(describeCalendar)))
        }
        if dict["WatchPaths"] != nil {
            triggers.append("When a watched path changes")
        }
        if dict["QueueDirectories"] != nil {
            triggers.append("When a queue directory receives content")
        }
        switch dict["KeepAlive"] {
        case let value as Bool where value:
            triggers.append("Kept alive permanently")
        case is [String: Any]:
            triggers.append("Restarted under conditions")
        default:
            break
        }
        if (dict["RunAtLoad"] as? Bool) == true {
            triggers.append(triggers.isEmpty ? "At startup / login" : "on load")
        }

        return triggers.isEmpty ? "On demand" : triggers.joined(separator: " · ")
    }

    private static func describeKeepAlive(_ value: Any?) -> String? {
        switch value {
        case let bool as Bool:
            return bool ? "Always (restarted if it stops)" : "No"
        case let conditions as [String: Any]:
            let parts = conditions.compactMap { key, raw -> String? in
                guard let flag = raw as? Bool else { return nil }
                return "\(key) = \(flag)"
            }
            return "Conditional — " + parts.sorted().joined(separator: ", ")
        default:
            return nil
        }
    }

    private static func describeCalendar(_ dict: [String: Any]) -> String {
        let weekday = intValue(dict["Weekday"])
        let hour = intValue(dict["Hour"])
        let minute = intValue(dict["Minute"])
        let day = intValue(dict["Day"])
        let month = intValue(dict["Month"])

        var prefix: String
        if let weekday {
            prefix = "every " + weekdayName(weekday)
        } else if let day {
            prefix = "on the \(day)th of the month"
        } else {
            prefix = "every day"
        }

        var time = ""
        if let hour, let minute {
            time = String(format: " at %02d:%02d", hour, minute)
        } else if let hour {
            time = String(format: " at %02dh", hour)
        } else if let minute {
            // minute only → at that minute of every hour
            return "at minute :" + String(format: "%02d", minute) + " of every hour"
        }

        var result = prefix + time
        if let month { result += " (month \(month))" }
        return result
    }

    private static func summarizeCalendars(_ parts: [String]) -> String {
        if parts.count <= 4 { return parts.joined(separator: " ; ") }
        return "\(parts.count) scheduled times"
    }

    private static func describeInterval(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 1 ? "Once a day" : "Every \(days) days"
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "Every minute" : "Every \(minutes) min"
        }
        return "Every \(seconds) s"
    }

    private static func weekdayName(_ value: Int) -> String {
        // launchd: 0 and 7 = Sunday
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return (0...7).contains(value) ? names[value] : "day \(value)"
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    // MARK: - Crontab

    private static func scanCrontab() -> [ScheduledJob] {
        let output = Shell.run("/usr/bin/crontab", ["-l"])
        guard !output.isEmpty else { return [] }

        var jobs: [ScheduledJob] = []
        var seenKeys: [String: Int] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            var working = line
            var enabled = true
            if working.hasPrefix("#") {
                working = String(working.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                enabled = false
            }
            guard isCronEntry(working) else { continue }

            let (schedule, command) = splitCron(working)
            let displayName = command.isEmpty ? schedule : command
            // ID derived from content (≠ position) → the selection survives a reordering of the crontab.
            // Occurrence suffix to distinguish two strictly identical lines.
            let configKey = "cron: \(schedule) \(command)"
            let occurrence = seenKeys[configKey, default: 0]
            seenKeys[configKey] = occurrence + 1
            jobs.append(ScheduledJob(
                id: occurrence == 0 ? configKey : "\(configKey)#\(occurrence)",
                name: displayName,
                label: nil,
                kind: .cron,
                scope: .user,
                configKey: configKey,
                sourceLabel: "crontab (user)",
                path: nil,
                symlinkTarget: nil,
                owningProject: nil,
                program: command.split(separator: " ").first.map(String.init),
                arguments: [],
                commandLine: command,
                scheduleDescription: describeCron(schedule),
                runAtLoad: false,
                keepAliveDescription: nil,
                enabledState: enabled ? .enabled : .disabled,
                loaded: nil,
                pid: nil,
                lastExitStatus: nil,
                rawContent: String(rawLine)
            ))
        }
        return jobs
    }

    private static func isCronEntry(_ line: String) -> Bool {
        if line.hasPrefix("@") { return true }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 6 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789*/,-")
        return tokens.prefix(5).allSatisfy { token in
            token.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static func splitCron(_ line: String) -> (schedule: String, command: String) {
        if line.hasPrefix("@") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 6 else { return (parts.joined(separator: " "), "") }
        return (parts[0..<5].joined(separator: " "), parts[5])
    }

    private static func describeCron(_ schedule: String) -> String {
        if schedule.hasPrefix("@") {
            switch schedule {
            case "@reboot": return "At startup"
            case "@daily", "@midnight": return "Every day at midnight"
            case "@hourly": return "Every hour"
            case "@weekly": return "Every week"
            case "@monthly": return "Every month"
            case "@yearly", "@annually": return "Every year"
            default: return schedule
            }
        }
        let fields = schedule.split(separator: " ").map(String.init)
        if fields.count == 5, fields[2] == "*", fields[3] == "*", fields[4] == "*",
           let minute = Int(fields[0]), let hour = Int(fields[1]) {
            return String(format: "Every day at %02d:%02d", hour, minute)
        }
        return schedule
    }
}
