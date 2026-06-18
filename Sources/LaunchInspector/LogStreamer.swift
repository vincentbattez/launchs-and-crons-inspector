import Foundation
import Observation

/// Reads a job's logs live via a subprocess.
///
/// Two possible sources (cf. `source(for:)`):
/// - `StandardOutPath`/`StandardErrorPath` files → `tail -F` (backfill + follow built in);
/// - otherwise the unified log filtered by process → `log show` (backfill) then `log stream` (live).
///
/// The `Process` lifecycle is tied to the SwiftUI task: on cancellation (selected item change
/// or view disappearance), we send `SIGTERM`, which closes the pipe and ends the stream.
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

    // MARK: - Source selection

    struct Source: Sendable {
        var backfill: (exe: String, args: [String])?
        var stream: (exe: String, args: [String])
        var label: String
    }

    /// Describes a job's log source, or nil if none is available.
    static func source(for job: ScheduledJob) -> Source? {
        // 1. Explicit log files (≠ /dev/null): backfill + live via `tail -F`.
        var files: [String] = []
        if let o = job.standardOutPath, o != "/dev/null" { files.append(o) }
        if let e = job.standardErrorPath, e != "/dev/null", e != job.standardOutPath { files.append(e) }
        if !files.isEmpty {
            return Source(
                backfill: nil,
                stream: ("/usr/bin/tail", ["-n", "200", "-F"] + files),
                label: "File: " + files.joined(separator: ", "))
        }

        // 2. Unified log filtered by process: `log show` (history) then `log stream` (live).
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
            label: "Unified log: " + name)
    }

    private static func escapePredicate(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Reading

    /// Runs the backfill (if it exists, finite process) then the live stream, until the task is cancelled.
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

    // MARK: - Private

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

    /// Severity inferred from the content (heuristic; works for `tail` as well as the unified log).
    private static func classify(_ text: String) -> Severity {
        let lower = text.lowercased()
        for needle in ["error", "fail", "fatal", "exception", "critical", "panic"] {
            if lower.contains(needle) { return .error }
        }
        return lower.contains("warn") ? .warning : .normal
    }

    /// Spawns a process and reads its output (stdout + stderr merged) line by line on the MainActor.
    /// A finite process (backfill) ends on its own (EOF); a live stream runs until cancellation,
    /// where `onCancel` sends `SIGTERM` (the `Int32` pid is `Sendable`, unlike `Process`).
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
            append("Unable to start reading: \(error.localizedDescription)")
            return
        }
        let pid = process.processIdentifier
        await withTaskCancellationHandler {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    append(line)
                }
            } catch {
                // stream interrupted (cancellation or read error) → we exit cleanly
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
        process.terminate()
    }
}
