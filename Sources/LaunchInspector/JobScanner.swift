import Foundation

/// Lance un binaire et renvoie sa sortie standard. Synchrone, à appeler hors du main thread.
enum Shell {
    static func run(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // on ignore stderr
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

/// Scanne crons + LaunchAgents/LaunchDaemons de l'utilisateur et globaux.
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

    // MARK: - Compteur d'exécutions + runtime (launchctl print, sans root)

    /// Infos extraites de `launchctl print <domaine>/<label>`.
    private struct PrintInfo {
        var present = false      // print a renvoyé quelque chose (job bootstrappé dans le domaine)
        var runs: Int?
        var pid: Int?
        var lastExit: Int?
    }

    /// `runs`, `pid`, `last exit code` du sommet du dump (on ignore les `state = active` imbriqués
    /// en ne gardant que la 1re occurrence de chaque clé). Fonctionne sans root pour gui et system.
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

    /// Remplit `runCount` pour tous les jobs launchd, et complète loaded/pid/lastExit quand ils
    /// étaient inconnus (daemons absents de `launchctl list`). Un appel Process par job, lancés en
    /// parallèle (~0,4 s pour ~33 jobs au lieu de ~3 s en séquentiel).
    private static func fillRunCounts(_ jobs: inout [ScheduledJob]) {
        let uid = getuid()
        // Cibles immuables (Sendable) : index dans `jobs`, domaine launchctl, label.
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

        // Écritures sur des indices disjoints → sûr ; `nonisolated(unsafe)` lève le contrôle Sendable.
        nonisolated(unsafe) var results = [PrintInfo](repeating: PrintInfo(), count: requests.count)
        DispatchQueue.concurrentPerform(iterations: requests.count) { k in
            results[k] = printInfo(domain: requests[k].domain, label: requests[k].label)
        }

        for (k, req) in requests.enumerated() {
            let info = results[k]
            let i = req.index
            jobs[i].runCount = info.runs
            // Compléter le runtime seulement quand il était inconnu (daemons) ET que print a répondu.
            if info.present, jobs[i].loaded == nil {
                jobs[i].loaded = true
                if jobs[i].pid == nil { jobs[i].pid = info.pid }
                if jobs[i].lastExitStatus == nil { jobs[i].lastExitStatus = info.lastExit }
            }
        }
    }

    // MARK: - Statut launchd

    /// Map `label -> estDésactivé`, fusion des domaines gui et system
    /// (les deux marchent sans root via `launchctl print-disabled`).
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

    /// Map `label -> (pid, lastExitStatus)` depuis `launchctl list` (domaine gui).
    private static func parseListMap() -> [String: (pid: Int?, status: Int?)] {
        var map: [String: (pid: Int?, status: Int?)] = [:]
        let text = Shell.run("/bin/launchctl", ["list"])
        for (index, line) in text.split(separator: "\n").enumerated() {
            if index == 0 { continue } // en-tête PID Status Label
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

        // Programme / arguments
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

        // Symlink / projet
        var symlinkTarget: String?
        var owningProject: String?
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : url.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
            symlinkTarget = resolved.path
            owningProject = resolved.deletingLastPathComponent().lastPathComponent
        }

        // Statut
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
            loaded = nil // inconnu sans root
            pid = nil
            lastExit = nil
        } else {
            loaded = false
            pid = nil
            lastExit = nil
        }

        // Sorties de log déclarées
        let stdoutPath = dict["StandardOutPath"] as? String
        let stderrPath = dict["StandardErrorPath"] as? String

        // Métadonnées
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

    // MARK: - Métadonnées (.plist + filesystem)

    /// Date de création du fichier (birthtime via lstat — celle du symlink lui-même, pas de sa cible),
    /// avec repli sur la date de modification si le birthtime est absent.
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

    /// `CFBundleShortVersionString` si le programme vit dans un `.app`.
    private static func appVersion(forProgram program: String?) -> String? {
        guard let program, let r = program.range(of: ".app/") else { return nil }
        let bundle = String(program[..<r.lowerBound]) + ".app"
        let info = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    /// `LimitLoadToSessionType` → texte ; défaut « Aqua » (agent) ou « Système » (daemon).
    private static func describeSessionType(_ raw: Any?, kind: JobKind) -> String {
        if let s = raw as? String { return s }
        if let a = raw as? [String] { return a.joined(separator: ", ") }
        return kind == .launchDaemon ? "Système" : "Aqua"
    }

    private static func rawContent(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8),
           text.contains("<plist") || text.hasPrefix("<?xml") {
            return text
        }
        // plist binaire → conversion XML pour l'affichage
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return text
        }
        return "(contenu binaire illisible)"
    }

    // MARK: - Planification launchd

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
            triggers.append("Quand un chemin surveillé change")
        }
        if dict["QueueDirectories"] != nil {
            triggers.append("Quand un dossier file d'attente reçoit du contenu")
        }
        switch dict["KeepAlive"] {
        case let value as Bool where value:
            triggers.append("Maintenu actif en permanence")
        case is [String: Any]:
            triggers.append("Relancé sous conditions")
        default:
            break
        }
        if (dict["RunAtLoad"] as? Bool) == true {
            triggers.append(triggers.isEmpty ? "Au démarrage / login" : "au chargement")
        }

        return triggers.isEmpty ? "À la demande" : triggers.joined(separator: " · ")
    }

    private static func describeKeepAlive(_ value: Any?) -> String? {
        switch value {
        case let bool as Bool:
            return bool ? "Toujours (redémarré s'il s'arrête)" : "Non"
        case let conditions as [String: Any]:
            let parts = conditions.compactMap { key, raw -> String? in
                guard let flag = raw as? Bool else { return nil }
                return "\(key) = \(flag)"
            }
            return "Conditionnel — " + parts.sorted().joined(separator: ", ")
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
            prefix = "chaque " + weekdayName(weekday)
        } else if let day {
            prefix = "le \(day) du mois"
        } else {
            prefix = "chaque jour"
        }

        var time = ""
        if let hour, let minute {
            time = String(format: " à %02d:%02d", hour, minute)
        } else if let hour {
            time = String(format: " à %02dh", hour)
        } else if let minute {
            // minute seule → à cette minute de chaque heure
            return "à la minute :" + String(format: "%02d", minute) + " de chaque heure"
        }

        var result = prefix + time
        if let month { result += " (mois \(month))" }
        return result
    }

    private static func summarizeCalendars(_ parts: [String]) -> String {
        if parts.count <= 4 { return parts.joined(separator: " ; ") }
        return "\(parts.count) horaires programmés"
    }

    private static func describeInterval(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 1 ? "Une fois par jour" : "Tous les \(days) jours"
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return hours == 1 ? "Toutes les heures" : "Toutes les \(hours) heures"
        }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "Toutes les minutes" : "Toutes les \(minutes) min"
        }
        return "Toutes les \(seconds) s"
    }

    private static func weekdayName(_ value: Int) -> String {
        // launchd : 0 et 7 = dimanche
        let names = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
        return (0...7).contains(value) ? names[value] : "jour \(value)"
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
        for (index, rawLine) in output.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
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
            jobs.append(ScheduledJob(
                id: "cron-\(index)",
                name: displayName,
                label: nil,
                kind: .cron,
                scope: .user,
                configKey: "cron: \(schedule) \(command)",
                sourceLabel: "crontab (utilisateur)",
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
            case "@reboot": return "Au démarrage"
            case "@daily", "@midnight": return "Chaque jour à minuit"
            case "@hourly": return "Toutes les heures"
            case "@weekly": return "Chaque semaine"
            case "@monthly": return "Chaque mois"
            case "@yearly", "@annually": return "Chaque année"
            default: return schedule
            }
        }
        let fields = schedule.split(separator: " ").map(String.init)
        if fields.count == 5, fields[2] == "*", fields[3] == "*", fields[4] == "*",
           let minute = Int(fields[0]), let hour = Int(fields[1]) {
            return String(format: "Tous les jours à %02d:%02d", hour, minute)
        }
        return schedule
    }
}
