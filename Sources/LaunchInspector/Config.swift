import Foundation

/// Personnalisation d'un job : renommage, description, groupe, masquage.
/// Décodage tolérant : un champ absent prend sa valeur par défaut (l'agent peut n'écrire que ce qu'il veut).
struct ConfigItem: Codable, Sendable {
    var name: String
    var description: String
    var group: String?
    var hidden: Bool

    init(name: String = "", description: String = "", group: String? = nil, hidden: Bool = false) {
        self.name = name
        self.description = description
        self.group = group
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// Un groupe défini par l'utilisateur. `collapsed` = état d'UI persisté.
struct ConfigGroup: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var collapsed: Bool

    init(id: String, name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// Racine du fichier `config.json`.
struct AppConfig: Codable, Sendable {
    var help: String?
    var version: Int
    var groups: [ConfigGroup]
    var items: [String: ConfigItem]
    var ungroupedCollapsed: Bool
    var hiddenCollapsed: Bool

    enum CodingKeys: String, CodingKey {
        case help = "_help"
        case version, groups, items, ungroupedCollapsed, hiddenCollapsed
    }

    init() {
        help = AppConfig.helpText
        version = 1
        groups = []
        items = [:]
        ungroupedCollapsed = false
        hiddenCollapsed = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = (try c.decodeIfPresent([ConfigGroup].self, forKey: .groups) ?? [])
            .filter { !$0.id.isEmpty }
        items = try c.decodeIfPresent([String: ConfigItem].self, forKey: .items) ?? [:]
        ungroupedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .ungroupedCollapsed) ?? false
        hiddenCollapsed = try c.decodeIfPresent(Bool.self, forKey: .hiddenCollapsed) ?? true
    }

    static let helpText = """
        Fichier de personnalisation de LaunchInspector — éditable par Claude Code ou via l'app.
        • items : dictionnaire clé→personnalisation. La CLÉ est fournie : Label launchd (ex. com.vincent.x) \
        ou 'cron: <planning> <commande>'. Ne PAS inventer de clés ; l'app crée un stub vide pour chaque job détecté.
        • item.name : nom affiché à la place du label (vide = label d'origine).
        • item.description : note libre affichée dans le détail.
        • item.group : id d'un groupe défini dans 'groups' (absent/null = non groupé).
        • item.hidden : true = déplace le job dans la section repliée 'Masqués' tout en bas.
        • groups : liste ordonnée {id, name, collapsed}. PRÉSERVER 'collapsed' (état d'UI) lors d'une édition.
        • ungroupedCollapsed / hiddenCollapsed : état replié des sections spéciales — à préserver aussi.
        """
}
