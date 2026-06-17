import Foundation
import Observation

/// Lit les logs d'un job en direct via un sous-processus.
///
/// Deux sources possibles (cf. `source(for:)`) :
/// - fichiers `StandardOutPath`/`StandardErrorPath` → `tail -F` (backfill + suivi intégrés) ;
/// - sinon journal unifié filtré par process → `log show` (backfill) puis `log stream` (live).
///
/// Le cycle de vie du `Process` est collé à la tâche SwiftUI : à l'annulation (changement d'item
/// sélectionné ou disparition de la vue), on envoie `SIGTERM`, ce qui ferme le tube et termine le flux.
@MainActor
@Observable
final class LogStreamer {

    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
        let severity: Severity
    }

    enum Severity: Sendable { case normal, warning, error }

    private(set) var lines: [Line] = []
    private(set) var sourceLabel = ""
    private(set) var isRunning = false
    private(set) var unavailable: String?

    private var seq = 0
    private let maxLines = 600

    // MARK: - Choix de la source

    struct Source: Sendable {
        var backfill: (exe: String, args: [String])?
        var stream: (exe: String, args: [String])
        var label: String
    }

    /// Décrit la source de log d'un job, ou nil si aucune n'est disponible.
    static func source(for job: ScheduledJob) -> Source? {
        // 1. Fichiers de log explicites (≠ /dev/null) : backfill + live via `tail -F`.
        var files: [String] = []
        if let o = job.standardOutPath, o != "/dev/null" { files.append(o) }
        if let e = job.standardErrorPath, e != "/dev/null", e != job.standardOutPath { files.append(e) }
        if !files.isEmpty {
            return Source(
                backfill: nil,
                stream: ("/usr/bin/tail", ["-n", "200", "-F"] + files),
                label: "Fichier : " + files.joined(separator: ", "))
        }

        // 2. Journal unifié filtré par process : `log show` (historique) puis `log stream` (live).
        guard let program = job.program, !program.isEmpty else { return nil }
        let predicate: String
        let name: String
        if program.hasPrefix("/") {
            predicate = "processImagePath == \"\(escapePredicate(program))\""
            name = (program as NSString).lastPathComponent
        } else {
            predicate = "process == \"\(escapePredicate(program))\""
            name = program
        }
        return Source(
            backfill: ("/usr/bin/log", ["show", "--last", "1h", "--info", "--predicate", predicate, "--style", "compact"]),
            stream: ("/usr/bin/log", ["stream", "--predicate", predicate, "--style", "compact", "--level", "info"]),
            label: "Journal unifié : " + name)
    }

    private static func escapePredicate(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Lecture

    /// Lance le backfill (s'il existe, process fini) puis le flux live, jusqu'à annulation de la tâche.
    func run(_ source: Source) async {
        reset(label: source.label)
        isRunning = true
        defer { isRunning = false }
        if let backfill = source.backfill {
            await pump(backfill.exe, backfill.args)
        }
        guard !Task.isCancelled else { return }
        await pump(source.stream.exe, source.stream.args)
    }

    func setUnavailable(_ message: String) {
        reset(label: "")
        unavailable = message
    }

    // MARK: - Privé

    private func reset(label: String) {
        lines = []
        seq = 0
        sourceLabel = label
        unavailable = nil
    }

    private func append(_ text: String) {
        seq += 1
        lines.append(Line(id: seq, text: text, severity: Self.classify(text)))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// Sévérité déduite du contenu (heuristique ; fonctionne pour `tail` comme pour le journal unifié).
    private static func classify(_ text: String) -> Severity {
        let lower = text.lowercased()
        for needle in ["error", "fail", "fatal", "exception", "critical", "panic"] {
            if lower.contains(needle) { return .error }
        }
        return lower.contains("warn") ? .warning : .normal
    }

    /// Spawn un process et lit sa sortie (stdout + stderr fusionnés) ligne à ligne sur le MainActor.
    /// Un process fini (backfill) se termine seul (EOF) ; un flux live tourne jusqu'à l'annulation,
    /// où `onCancel` envoie `SIGTERM` (le pid `Int32` est `Sendable`, contrairement à `Process`).
    private func pump(_ exe: String, _ args: [String]) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            append("Impossible de démarrer la lecture : \(error.localizedDescription)")
            return
        }
        let pid = process.processIdentifier
        await withTaskCancellationHandler {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    append(line)
                }
            } catch {
                // flux interrompu (annulation ou erreur de lecture) → on sort proprement
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
        process.terminate()
    }
}
