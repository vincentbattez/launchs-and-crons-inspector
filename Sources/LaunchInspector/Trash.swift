import Foundation

/// Un job supprimé, conservé pour pouvoir être restauré.
/// Pour un `.plist` : les octets d'origine sont sauvegardés dans `blobFile` (corbeille interne),
/// avec les permissions d'origine pour que launchd accepte de le recharger.
/// Pour un cron : la ligne exacte du crontab est stockée dans `cronLine` (pas de blob).
struct TrashEntry: Codable, Identifiable, Sendable {
    var id: String
    var date: Date
    var displayName: String
    var kind: JobKind
    var scope: JobScope
    var label: String?         // label launchd ; nil = cron
    var originalPath: String?  // chemin du .plist ; nil = cron
    var cronLine: String?      // ligne crontab exacte ; nil = launchd
    var blobFile: String?      // nom du fichier sauvegardé dans trash/ ; nil = cron
    var mode: UInt16?          // permissions d'origine (st_mode & 0o7777)
    var uid: UInt32?           // propriétaire d'origine
    var gid: UInt32?           // groupe d'origine
}

/// Stockage sur disque de la corbeille : `~/Library/Application Support/LaunchInspector/trash/`.
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
