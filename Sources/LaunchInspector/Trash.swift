import Foundation

/// A deleted job, kept so it can be restored.
/// For a `.plist`: the original bytes are saved in `blobFile` (internal trash),
/// with the original permissions so launchd will accept to reload it.
/// For a cron: the exact crontab line is stored in `cronLine` (no blob).
struct TrashEntry: Codable, Identifiable, Sendable {
    var id: String
    var date: Date
    var displayName: String
    var kind: JobKind
    var scope: JobScope
    var label: String?         // launchd label ; nil = cron
    var originalPath: String?  // .plist path ; nil = cron
    var cronLine: String?      // exact crontab line ; nil = launchd
    var blobFile: String?      // name of the file saved in trash/ ; nil = cron
    var mode: UInt16?          // original permissions (st_mode & 0o7777)
    var uid: UInt32?           // original owner
    var gid: UInt32?           // original group
}

/// On-disk storage for the trash: `~/Library/Application Support/LaunchInspector/trash/`.
enum TrashStore {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LaunchInspector/trash")
    }
    static var manifestURL: URL { dir.appendingPathComponent("trash.json") }
    static func blobURL(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func load() -> [TrashEntry] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrashEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [TrashEntry]) {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: manifestURL)
    }

    static func deleteBlob(_ entry: TrashEntry) {
        guard let blob = entry.blobFile else { return }
        try? FileManager.default.removeItem(at: blobURL(blob))
    }
}
