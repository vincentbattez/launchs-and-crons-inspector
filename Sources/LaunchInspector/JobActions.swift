import Foundation

/// Exécute un binaire et capture stdout / stderr / code de sortie (et stdin optionnel pour `crontab -`).
extension Shell {
    struct Out: Sendable { let stdout: String; let stderr: String; let code: Int32 }

    static func capture(_ launchPath: String, _ args: [String], stdin: String? = nil) -> Out {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }
        do {
            try process.run()
        } catch {
            return Out(stdout: "", stderr: error.localizedDescription, code: -1)
        }
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let od = out.fileHandleForReading.readDataToEndOfFile()
        let ed = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Out(stdout: String(decoding: od, as: UTF8.self),
                   stderr: String(decoding: ed, as: UTF8.self),
                   code: process.terminationStatus)
    }
}

/// Actions qui MODIFIENT le système : désactiver / activer, supprimer (vers corbeille), restaurer.
/// Tout passe hors du main thread (Process bloquant). Les opérations qui touchent `/Library`
/// (agents globaux + daemons) sont regroupées dans un seul `osascript … with administrator privileges`
/// → un seul prompt mot de passe par action.
enum JobActions {
    struct Outcome: Sendable { let ok: Bool; let message: String }

    // MARK: - Activer / désactiver

    static func setEnabled(_ jobs: [ScheduledJob], enabled: Bool) -> Outcome {
        let uid = getuid()
        var errors: [String] = []

        let crons = jobs.filter { $0.kind == .cron }
        if !crons.isEmpty {
            let r = rewriteCrontab { toggleCron($0, crons, enabled: enabled) }
            if !r.ok { errors.append(r.message) }
        }

        var rootCmds: [String] = []
        for job in jobs where job.kind != .cron {
            guard let label = job.label else { continue }
            let domain = job.kind == .launchDaemon ? "system" : "gui/\(uid)"
            let dl = "\(domain)/\(label)"
            let isDaemon = job.kind == .launchDaemon
            if enabled {
                let bootstrap = job.path.map { "/bin/launchctl bootstrap \(domain) \(shArg($0))" } ?? "true"
                if isDaemon {
                    rootCmds.append("/bin/launchctl enable \(shArg(dl)) && { \(bootstrap) ; true ; }")
                } else {
                    _ = Shell.capture("/bin/launchctl", ["enable", dl])
                    if let p = job.path { _ = Shell.capture("/bin/launchctl", ["bootstrap", domain, p]) }
                }
            } else {
                if isDaemon {
                    rootCmds.append("/bin/launchctl disable \(shArg(dl)) && { /bin/launchctl bootout \(shArg(dl)) ; true ; }")
                } else {
                    _ = Shell.capture("/bin/launchctl", ["disable", dl])
                    _ = Shell.capture("/bin/launchctl", ["bootout", dl])
                }
            }
        }
        if !rootCmds.isEmpty {
            let out = runRoot(rootCmds.joined(separator: " && "))
            if out.code != 0 { errors.append(adminError(out)) }
        }
        return Outcome(ok: errors.isEmpty, message: errors.isEmpty ? "OK" : errors.joined(separator: "\n"))
    }

    // MARK: - Supprimer (vers la corbeille interne)

    static func delete(_ jobs: [ScheduledJob]) -> (Outcome, [TrashEntry]) {
        TrashStore.ensureDir()
        let uid = getuid()
        var entries: [TrashEntry] = []
        var errors: [String] = []

        // Crons : retirer les lignes effectivement présentes en une seule réécriture du crontab.
        // On ne crée une entrée de corbeille que pour les lignes réellement retirées : si le crontab
        // a changé entre le scan et l'action, on n'enregistre pas un cron qui n'a pas été supprimé.
        let crons = jobs.filter { $0.kind == .cron }
        if !crons.isEmpty {
            var lines = readCrontab().components(separatedBy: "\n")
            var removed: [ScheduledJob] = []
            for job in crons {
                if let idx = lines.firstIndex(of: job.rawContent) {
                    lines.remove(at: idx)
                    removed.append(job)
                }
            }
            if removed.isEmpty {
                errors.append("Cron introuvable dans le crontab (modifié entre-temps ?).")
            } else {
                let r = writeCrontab(lines)
                if r.ok {
                    for job in removed {
                        entries.append(TrashEntry(
                            id: UUID().uuidString, date: Date(), displayName: job.displayName,
                            kind: .cron, scope: job.scope, label: nil, originalPath: nil,
                            cronLine: job.rawContent, blobFile: nil, mode: nil, uid: nil, gid: nil))
                    }
                } else { errors.append(r.message) }
            }
        }

        // launchd : sauvegarder les octets + commandes (bootout best-effort, rm fait foi).
        var rootCmds: [String] = []
        var rootEntries: [TrashEntry] = []
        var rootBlobs: [String] = []
        for job in jobs where job.kind != .cron {
            guard let path = job.path, let label = job.label else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                errors.append("\(job.displayName) : lecture impossible"); continue
            }
            var st = stat()
            let haveStat = stat(path, &st) == 0
            let blob = UUID().uuidString + ".plist"
            do { try data.write(to: TrashStore.blobURL(blob)) }
            catch { errors.append("\(job.displayName) : sauvegarde corbeille impossible"); continue }

            let entry = TrashEntry(
                id: UUID().uuidString, date: Date(), displayName: job.displayName,
                kind: job.kind, scope: job.scope, label: label, originalPath: path,
                cronLine: nil, blobFile: blob,
                mode: haveStat ? UInt16(st.st_mode & 0o7777) : nil,
                uid: haveStat ? st.st_uid : nil, gid: haveStat ? st.st_gid : nil)

            let domain = job.kind == .launchDaemon ? "system" : "gui/\(uid)"
            let dl = "\(domain)/\(label)"
            if job.scope == .global {
                rootCmds.append("{ /bin/launchctl bootout \(shArg(dl)) ; true ; } && /bin/rm -f \(shArg(path))")
                rootEntries.append(entry); rootBlobs.append(blob)
            } else {
                _ = Shell.capture("/bin/launchctl", ["bootout", dl])
                let rm = Shell.capture("/bin/rm", ["-f", path])
                if rm.code == 0 {
                    entries.append(entry)
                } else {
                    errors.append("\(job.displayName) : \(rm.stderr.isEmpty ? "suppression impossible" : rm.stderr)")
                    try? FileManager.default.removeItem(at: TrashStore.blobURL(blob))
                }
            }
        }
        if !rootCmds.isEmpty {
            let out = runRoot(rootCmds.joined(separator: " && "))
            if out.code == 0 {
                entries.append(contentsOf: rootEntries)
            } else {
                errors.append(adminError(out))
                for b in rootBlobs { try? FileManager.default.removeItem(at: TrashStore.blobURL(b)) }
            }
        }
        let ok = errors.isEmpty
        return (Outcome(ok: ok, message: ok ? "Supprimé" : errors.joined(separator: "\n")), entries)
    }

    // MARK: - Restaurer

    static func restore(_ entry: TrashEntry) -> Outcome {
        if let line = entry.cronLine {
            return rewriteCrontab { addCron($0, line) }
        }
        guard let path = entry.originalPath, let blob = entry.blobFile, let label = entry.label else {
            return Outcome(ok: false, message: "Entrée de corbeille invalide.")
        }
        let blobPath = TrashStore.blobURL(blob).path
        guard FileManager.default.fileExists(atPath: blobPath) else {
            return Outcome(ok: false, message: "Fichier de sauvegarde introuvable.")
        }
        let uid = getuid()
        let domain = entry.kind == .launchDaemon ? "system" : "gui/\(uid)"
        let dl = "\(domain)/\(label)"

        if entry.scope == .global {
            let mode = entry.mode.map { String($0, radix: 8) } ?? "644"
            let owner = "\(entry.uid ?? 0):\(entry.gid ?? 0)" // root:wheel = 0:0
            let cmd = "/bin/cp \(shArg(blobPath)) \(shArg(path))"
                + " && /usr/sbin/chown \(owner) \(shArg(path))"
                + " && /bin/chmod \(mode) \(shArg(path))"
                + " && { /bin/launchctl enable \(shArg(dl)) ; /bin/launchctl bootstrap \(domain) \(shArg(path)) ; true ; }"
            let out = runRoot(cmd)
            return Outcome(ok: out.code == 0, message: out.code == 0 ? "Restauré" : adminError(out))
        } else {
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                try FileManager.default.copyItem(atPath: blobPath, toPath: path)
            } catch {
                return Outcome(ok: false, message: "Restauration impossible : \(error.localizedDescription)")
            }
            _ = Shell.capture("/bin/launchctl", ["enable", dl])
            _ = Shell.capture("/bin/launchctl", ["bootstrap", domain, path])
            return Outcome(ok: true, message: "Restauré")
        }
    }

    // MARK: - Crontab (lecture / réécriture)

    private static func readCrontab() -> String {
        let out = Shell.capture("/usr/bin/crontab", ["-l"])
        return out.code == 0 ? out.stdout : "" // pas de crontab → on part d'un contenu vide
    }

    private static func rewriteCrontab(_ transform: ([String]) -> [String]) -> Outcome {
        let lines = readCrontab().components(separatedBy: "\n")
        return writeCrontab(transform(lines))
    }

    private static func writeCrontab(_ lines: [String]) -> Outcome {
        let out = Shell.capture("/usr/bin/crontab", ["-"], stdin: lines.joined(separator: "\n"))
        return Outcome(ok: out.code == 0,
                       message: out.code == 0 ? "OK" : (out.stderr.isEmpty ? "Écriture du crontab impossible." : out.stderr))
    }

    private static func toggleCron(_ lines: [String], _ jobs: [ScheduledJob], enabled: Bool) -> [String] {
        var result = lines
        for job in jobs {
            guard let idx = result.firstIndex(of: job.rawContent) else { continue }
            let line = result[idx]
            if enabled {
                var s = Substring(line)
                while s.first == "#" { s = s.dropFirst() }
                while s.first == " " { s = s.dropFirst() }
                result[idx] = String(s)
            } else if !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                result[idx] = "# " + line
            }
        }
        return result
    }

    private static func addCron(_ lines: [String], _ line: String) -> [String] {
        var result = lines
        guard !result.contains(line) else { return result }
        if let last = result.last, last.isEmpty {
            result.insert(line, at: result.count - 1) // garder la ligne vide finale
        } else {
            result.append(line)
        }
        return result
    }

    // MARK: - Escalade de privilèges + échappement

    private static func runRoot(_ shellCommand: String) -> Shell.Out {
        let script = "do shell script \"\(appleEscape(shellCommand))\" with administrator privileges"
        return Shell.capture("/usr/bin/osascript", ["-e", script])
    }

    /// Échappe pour la chaîne AppleScript de `do shell script "…"`.
    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Entoure d'apostrophes pour le shell (gère espaces et apostrophes dans les chemins).
    private static func shArg(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func adminError(_ out: Shell.Out) -> String {
        if out.stderr.contains("-128") || out.stderr.lowercased().contains("user canceled") {
            return "Action annulée (mot de passe administrateur non saisi)."
        }
        return out.stderr.isEmpty ? "L'action administrateur a échoué." : out.stderr
    }
}
