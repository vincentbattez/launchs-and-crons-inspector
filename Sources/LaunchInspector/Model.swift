import Foundation

/// Nature du job planifié.
enum JobKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case launchAgent
    case launchDaemon
    case cron

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchAgent: "LaunchAgent"
        case .launchDaemon: "LaunchDaemon"
        case .cron: "Cron"
        }
    }

    var icon: String {
        switch self {
        case .launchAgent: "person.crop.circle"
        case .launchDaemon: "gearshape.2"
        case .cron: "clock"
        }
    }
}

/// Portée : qui possède le job.
enum JobScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case user   // ~/Library + crontab utilisateur
    case global // /Library

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: "Utilisateur"
        case .global: "Global"
        }
    }
}

/// État activé/désactivé, issu de la base d'overrides launchd (`launchctl print-disabled`),
/// pas seulement de la clé `Disabled` du fichier.
enum EnabledState: Int, Comparable, Sendable {
    case enabled
    case disabled
    case unknown

    static func < (lhs: EnabledState, rhs: EnabledState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .enabled: "Activé"
        case .disabled: "Désactivé"
        case .unknown: "Inconnu"
        }
    }
}

/// Un cron ou un job launchd unifié pour l'affichage.
struct ScheduledJob: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var label: String?
    var kind: JobKind
    var scope: JobScope

    /// Clé stable utilisée dans le fichier de config (label launchd, ou « cron: <planning> <cmd> »).
    var configKey: String = ""

    // Personnalisation issue du fichier de config (remplie par AppModel.merge()).
    var customName: String?
    var customDescription: String?
    var groupID: String?
    var isHidden: Bool = false
    var sourceLabel: String          // ex: "~/Library/LaunchAgents", "crontab"
    var path: String?                // chemin du fichier (.plist) — nil pour le crontab
    var symlinkTarget: String?       // cible résolue si le .plist est un symlink
    var owningProject: String?       // dossier projet déduit de la cible du symlink

    // Ce que ça fait
    var program: String?
    var arguments: [String]
    var commandLine: String

    // Sorties de log déclarées (launchd) — base de la lecture des logs en direct.
    var standardOutPath: String? = nil
    var standardErrorPath: String? = nil

    // Planification
    var scheduleDescription: String
    var runAtLoad: Bool
    var keepAliveDescription: String?

    // Statut (trois dimensions distinctes — voir launchctl)
    var enabledState: EnabledState
    var loaded: Bool?                // nil = inconnu (launchctl print n'a rien renvoyé)
    var pid: Int?
    var lastExitStatus: Int?
    var runCount: Int?               // nb d'exécutions depuis le chargement (login/boot) ; nil = inconnu ou cron

    // Métadonnées
    var installDate: Date? = nil     // date de création du .plist (≈ installation) ; nil pour les crons
    var sessionType: String? = nil   // LimitLoadToSessionType (Aqua, LoginWindow, Système…)
    var appVersion: String? = nil    // CFBundleShortVersionString si le programme vit dans un .app
    var machServices: [String] = []  // services Mach exposés → expliquent le « À la demande »

    // Brut
    var rawContent: String

    /// Nom affiché : nom perso s'il existe, sinon le label/commande d'origine.
    var displayName: String { customName ?? name }

    /// Job « dormant » → affiché grisé. On grise seulement quand on SAIT qu'il ne tourne pas :
    /// désactivé, ou (launchd) chargé/non-chargé sans PID. Un daemon au runtime inconnu n'est PAS grisé.
    var isDimmed: Bool {
        switch kind {
        case .cron:
            return enabledState != .enabled
        default:
            return enabledState == .disabled || (pid == nil && loaded != nil)
        }
    }

    // Clés de tri pour les colonnes du Table
    var displayNameSortKey: String { displayName.lowercased() }
    var kindSortKey: String { kind.label }
    var scopeSortKey: String { scope.label }
    var runCountSortKey: Int { runCount ?? -1 }   // cron / inconnu → en bas du tri
    var installDateSortKey: Date { installDate ?? .distantPast }
    var appVersionSortKey: String { appVersion ?? "" }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return displayName.lowercased().contains(q)
            || name.lowercased().contains(q)
            || commandLine.lowercased().contains(q)
            || (customDescription?.lowercased().contains(q) ?? false)
            || (label?.lowercased().contains(q) ?? false)
            || (owningProject?.lowercased().contains(q) ?? false)
            || sourceLabel.lowercased().contains(q)
    }
}
