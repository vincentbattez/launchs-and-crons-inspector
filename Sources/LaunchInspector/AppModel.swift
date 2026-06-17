import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// Jobs scannés + personnalisation appliquée (source de vérité pour les vues).
    private(set) var jobs: [ScheduledJob] = []
    private(set) var config = AppConfig()
    private(set) var trash: [TrashEntry] = []
    var isScanning = false
    var actionError: String?   // message d'échec de la dernière action (affiché en alerte)

    private var rawJobs: [ScheduledJob] = []
    private var configMtime: Date?
    private var didScaffold = false

    var enabledCount: Int { jobs.filter { $0.enabledState == .enabled }.count }
    var disabledCount: Int { jobs.filter { $0.enabledState == .disabled }.count }
    var hiddenCount: Int { jobs.filter(\.isHidden).count }

    // MARK: - Emplacement du fichier de config

    nonisolated static var configURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LaunchInspector/config.json")
    }

    // MARK: - Cycle de rafraîchissement

    /// Scanne le statut (toujours) et recharge la config si le fichier a changé sur disque.
    func refresh() async {
        isScanning = true
        defer { isScanning = false }

        rawJobs = await Task.detached(priority: .userInitiated) {
            JobScanner.scanAll()
        }.value

        if !didScaffold {
            loadConfig()
            scaffold()
            trash = TrashStore.load()
            didScaffold = true
        } else {
            loadConfigIfChanged()
        }
        merge()
    }

    // MARK: - Lecture / écriture de la config

    private func loadConfig() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            config = AppConfig()
            return
        }
        config = decoded
        configMtime = modificationDate()
    }

    private func loadConfigIfChanged() {
        if modificationDate() != configMtime { loadConfig() }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.configURL.path)[.modificationDate]) as? Date
    }

    /// Ajoute un stub vide pour chaque job non encore présent (idempotent, ne touche jamais aux valeurs existantes).
    private func scaffold() {
        var changed = false
        if config.help == nil {
            config.help = AppConfig.helpText
            changed = true
        }
        for job in rawJobs where config.items[job.configKey] == nil {
            config.items[job.configKey] = ConfigItem()
            changed = true
        }
        if changed { saveConfig() }
    }

    private func saveConfig() {
        try? FileManager.default.createDirectory(
            at: Self.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: Self.configURL)
        configMtime = modificationDate() // évite que le poll suivant recharge et écrase l'édition
        merge()
    }

    /// Applique la config aux jobs scannés.
    private func merge() {
        jobs = Self.applyConfig(rawJobs, config)
    }

    /// Fusion pure (réutilisée par le mode headless `--dump`).
    nonisolated static func applyConfig(_ rawJobs: [ScheduledJob], _ config: AppConfig) -> [ScheduledJob] {
        rawJobs.map { job in
            var job = job
            if let item = config.items[job.configKey] {
                job.customName = item.name.isEmpty ? nil : item.name
                job.customDescription = item.description.isEmpty ? nil : item.description
                job.groupID = item.group.flatMap { id in
                    config.groups.contains { $0.id == id } ? id : nil
                }
                job.isHidden = item.hidden
            }
            return job
        }
    }

    nonisolated static func loadConfigFromDisk() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return decoded
    }

    // MARK: - Mutateurs (UI)

    func configKeys(for ids: Set<ScheduledJob.ID>) -> [String] {
        jobs.filter { ids.contains($0.id) }.map(\.configKey)
    }

    func jobs(for ids: Set<ScheduledJob.ID>) -> [ScheduledJob] {
        jobs.filter { ids.contains($0.id) }
    }

    // MARK: - Actions système (désactiver / supprimer / restaurer)

    func setEnabled(ids: Set<ScheduledJob.ID>, enabled: Bool) async {
        let targets = jobs(for: ids)
        guard !targets.isEmpty else { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            JobActions.setEnabled(targets, enabled: enabled)
        }.value
        if !outcome.ok { actionError = outcome.message }
        await refresh()
    }

    func delete(ids: Set<ScheduledJob.ID>) async {
        let targets = jobs(for: ids)
        guard !targets.isEmpty else { return }
        let (outcome, entries) = await Task.detached(priority: .userInitiated) {
            JobActions.delete(targets)
        }.value
        if !entries.isEmpty {
            trash.append(contentsOf: entries)
            TrashStore.save(trash)
        }
        if !outcome.ok { actionError = outcome.message }
        await refresh()
    }

    func restore(_ entry: TrashEntry) async {
        let outcome = await Task.detached(priority: .userInitiated) {
            JobActions.restore(entry)
        }.value
        if outcome.ok {
            trash.removeAll { $0.id == entry.id }
            TrashStore.deleteBlob(entry)
            TrashStore.save(trash)
        } else {
            actionError = outcome.message
        }
        await refresh()
    }

    func setCustom(key: String, name: String, description: String) {
        config.items[key, default: ConfigItem()].name = name
        config.items[key, default: ConfigItem()].description = description
        saveConfig()
    }

    func setGroup(keys: [String], to groupID: String?) {
        for key in keys { config.items[key, default: ConfigItem()].group = groupID }
        saveConfig()
    }

    func setHidden(keys: [String], _ hidden: Bool) {
        for key in keys { config.items[key, default: ConfigItem()].hidden = hidden }
        saveConfig()
    }

    func anyHidden(keys: [String]) -> Bool {
        keys.contains { config.items[$0]?.hidden == true }
    }

    @discardableResult
    func createGroup(name: String) -> String {
        let id = uniqueGroupID(from: name)
        config.groups.append(ConfigGroup(id: id, name: name))
        saveConfig()
        return id
    }

    func setGroupCollapsed(_ id: String, _ collapsed: Bool) {
        guard let index = config.groups.firstIndex(where: { $0.id == id }) else { return }
        config.groups[index].collapsed = collapsed
        saveConfig()
    }

    func setUngroupedCollapsed(_ collapsed: Bool) {
        config.ungroupedCollapsed = collapsed
        saveConfig()
    }

    func setHiddenCollapsed(_ collapsed: Bool) {
        config.hiddenCollapsed = collapsed
        saveConfig()
    }

    private func uniqueGroupID(from name: String) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let slug = base.isEmpty ? "groupe" : base
        var candidate = slug
        var suffix = 2
        while config.groups.contains(where: { $0.id == candidate }) {
            candidate = "\(slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
