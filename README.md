# LaunchInspector

App macOS (SwiftUI) qui liste **tes** crons et `.plist` launchd, avec le détail de ce qu'ils font, leur planification et leur état.

## Fonctionnalités en bref

- **Scan ciblé** : crons utilisateur + LaunchAgents/Daemons perso et globaux ; les daemons Apple de `/System` sont ignorés.
- **Détail par job** : commande complète, planification traduite en clair, et état multi-dimensions (activé, chargé, en cours, nombre d'exécutions).
- **Métadonnées** : date d'installation, session de chargement, version de l'`.app`, service Mach déclencheur.
- **Organisation** : groupes repliables, renommage + description, masquage de lignes, affichage/masquage de colonnes (clic droit sur l'en-tête), tri par colonne.
- **Actions** (clic droit, avec confirmation) : **Activer / Désactiver** et **Supprimer** n'importe quel item ; **Corbeille** intégrée pour **restaurer** — un seul mot de passe admin pour les éléments `/Library`.
- **Recherche & filtres** : barre de recherche (nom, commande, projet), filtre par type, « activés uniquement ».
- **Repères visuels** : pastille de statut colorée, jobs dormants grisés.
- **Rafraîchissement auto** toutes les 10 s (+ ⟳ / ⌘R).
- **Config éditable par Claude Code** : noms, descriptions et groupes remplis automatiquement (prompts prêts à l'emploi plus bas).
- **Modes headless** : `--dump` (liste texte) et `--dump-json` (export complet).

## Ce qu'elle scanne

Portée « seulement les miens » — les daemons Apple de `/System/Library` sont volontairement ignorés :

| Source | Type |
|---|---|
| `crontab -l` (utilisateur) | Cron |
| `~/Library/LaunchAgents` | LaunchAgent (utilisateur) |
| `/Library/LaunchAgents` | LaunchAgent (global) |
| `/Library/LaunchDaemons` | LaunchDaemon (global) |

## Pour chaque job

- **Nom / Label** et, pour les `.plist` en symlink, le **projet** d'origine (ex. `auto-switch-mic`)
- **Ce que ça fait** : programme + arguments + ligne de commande complète
- **Planification** traduite en clair : `StartInterval`, `StartCalendarInterval` (dict ou tableau), `WatchPaths`, `KeepAlive`, `RunAtLoad`, et expressions cron
- **État** en plusieurs dimensions distinctes (pas un seul booléen) :
  - **Activé / désactivé** — lu dans la base d'overrides launchd (`launchctl print-disabled`), pas seulement la clé `Disabled` du fichier
  - **Chargé** — présence dans `launchctl list` ou `launchctl print` (daemons compris, sans root)
  - **En cours** — PID réel + dernier code de sortie
  - **Activité** — nombre d'exécutions depuis le chargement (`runs` de `launchctl print`), pour les agents **et** les daemons sans root. Approxime « a-t-il tourné cette session » : `0` = jamais, `26×` = 26 fois. ⚠️ launchd n'expose **pas** d'horodatage de dernière exécution — c'est un compteur, pas une date. Indisponible pour les crons.
- **Métadonnées** :
  - **Installé le** — date de création du `.plist` (≈ date d'installation ; approximative — une restauration la réinitialise)
  - **Session de chargement** — `LimitLoadToSessionType` (Aqua, LoginWindow, Système…)
  - **Version de l'app** — `CFBundleShortVersionString` quand le programme vit dans un `.app`
  - **Service Mach** — quand le job est « à la demande », le service qui le déclenche (`MachServices`)
- **Contenu brut** du fichier (les `.plist` binaires sont convertis en XML pour l'affichage)

## Organiser : groupes, renommage, descriptions, masquage

- **Groupes repliables** : clic droit sur une ou plusieurs lignes → *Déplacer vers ▸* (groupe existant, nouveau groupe, ou aucun). Chaque groupe se replie/déplie ; l'état est mémorisé.
- **Renommer + décrire** : volet détail → *Personnalisation* (nom affiché + description libre). Modifiable aussi par Claude Code dans le fichier de config.
- **Masquer (lignes)** : clic droit → *Masquer* déplace le job dans la section repliée **Masqués** tout en bas.
- **Afficher/masquer des colonnes** : clic droit sur l'**en-tête** du tableau → coche/décoche les colonnes (et réordonne-les). Pratique vu le nombre de colonnes (Type, Portée, Planification, État, Activité, Installé, Version…). *(Choix non persistés entre deux lancements pour l'instant.)*
- **Tri** : clic sur un en-tête de colonne — y compris **Activité**, **Installé** (par date) et **Version**.
- **Dormants grisés** : un job non démarré (launchd sans PID, cron désactivé) est affiché en opacité réduite ; les jobs en cours ressortent.
- **Rafraîchissement** : statut re-scanné automatiquement toutes les 10 s (+ bouton ⟳ / ⌘R).

## Agir : désactiver, supprimer, restaurer

⚠️ Contrairement au reste de l'app (lecture seule), ces actions **modifient** le système. Elles passent toujours par un **clic droit**, avec confirmation, et sont réversibles.

- **Activer / Désactiver** : (dé)charge le job via `launchctl enable|disable` + `bootstrap|bootout` ; pour un cron, (dé)commente la ligne. Réversible par l'action inverse.
- **Supprimer…** (confirmation obligatoire) : décharge le job puis déplace le `.plist` dans la **corbeille interne** de l'app (un cron est retiré du `crontab`, sa ligne exacte conservée). Aucun `rm` définitif tant que la corbeille n'est pas vidée.
- **Corbeille** (bouton de la barre d'outils) : liste les éléments supprimés ; **Restaurer** les remet à leur emplacement d'origine (permissions `root:wheel` rétablies pour les daemons) puis les recharge.
- **Mot de passe administrateur** : demandé une seule fois par action pour les éléments de `/Library` (agents globaux + daemons). Les crons et tes agents `~/Library` n'en ont pas besoin.

## Fichier de configuration

`~/Library/Application Support/LaunchInspector/config.json` — créé au 1er lancement avec un **stub vide par job** (la clé est pré-remplie, l'agent n'a qu'à compléter). Schéma :

```jsonc
{
  "_help": "…doc inline…",
  "version": 1,
  "groups": [
    { "id": "imprimante", "name": "Imprimante", "collapsed": false }
  ],
  "items": {
    // clé = Label launchd, ou "cron: <planning> <commande>"
    "com.vincent.printer-maintenance": {
      "name": "Maintenance buses",        // vide = label d'origine
      "description": "…",                  // note affichée dans le détail
      "group": "imprimante",               // id d'un groupe (absent = non groupé)
      "hidden": false                      // true = section "Masqués"
    }
  },
  "ungroupedCollapsed": false,
  "hiddenCollapsed": true
}
```

Conçu pour être édité par **Claude Code** : décodage tolérant (un champ absent prend sa valeur par défaut), clés stables fournies, `_help` documente le schéma. Préserver `collapsed` / `*Collapsed` (état d'UI) lors d'une édition.

### Remplir la config automatiquement avec Claude Code

[Claude Code](https://claude.com/claude-code) peut renseigner pour toi les `name`, `description` **et** la répartition en `groups`. **Étape commune** : exporter la liste des jobs résolus (depuis le dossier du projet) :

```sh
swift build --scratch-path /tmp/li-build
/tmp/li-build/debug/LaunchInspector --dump-json > /tmp/li-jobs.json
```

Ensuite, deux modes au choix.

#### Mode rapide (non-interactif)

Remplit `name` + `description` d'un coup, sans rien demander (édits auto-acceptés) :

```sh
claude -p --permission-mode acceptEdits "$(cat <<'PROMPT'
Remplis les champs "name" et "description" de chaque item de
~/Library/Application Support/LaunchInspector/config.json.

Source de données : /tmp/li-jobs.json — un tableau JSON dont le champ "configKey"
de chaque entrée correspond EXACTEMENT à une clé de l'objet "items" du config.json
(il fournit la commande, le programme, le planning, et pour les jobs perso le projet).

Pour chaque item :
- name        : nom court et clair, 2 à 4 mots (pas le label technique brut).
- description : une phrase en français expliquant à quoi sert le job.

Jobs tiers connus → décris d'après le programme/chemin. Jobs perso (champ "project"
ou "symlinkTarget") → lis les fichiers du projet pour être précis. N'invente jamais.

Ne modifie QUE "name" et "description". Préserve tout le reste : "_help", "groups"
(et leur "collapsed"), les "group"/"hidden" existants de chaque item,
"ungroupedCollapsed", "hiddenCollapsed". N'invente aucune clé. Termine en vérifiant
que le JSON reste bien formé.
PROMPT
)"
```

#### Mode interactif — tu choisis quoi remplir (nom / description / groupe)

Claude Code **présente d'abord ce qu'il peut faire**, te propose un **menu de choix**, puis n'applique **que ce que tu as choisi**. Lance-le sans `-p` (mode interactif, il pose ses questions dans le terminal) :

```sh
claude "$(cat <<'PROMPT'
Tu vas m'aider à personnaliser le fichier
~/Library/Application Support/LaunchInspector/config.json à partir de
/tmp/li-jobs.json (tableau JSON ; le champ "configKey" de chaque entrée correspond
EXACTEMENT à une clé de "items" et fournit commande / programme / planning / projet).

1. Présente-moi d'abord, en quelques lignes, ce que tu peux faire :
   - "name"        : un nom court et clair (2-4 mots) par item ;
   - "description" : une phrase en français expliquant à quoi sert chaque job ;
   - "group"       : répartir les items dans des groupes PAR FONCTION (ex. Mises à
     jour, Audio & captation, Écrans & affichage, Réseau & sécurité, Système &
     batterie, CodeBurn…).

2. Puis DEMANDE-MOI ce que je veux, sous forme de menu (attends ma réponse avant
   d'écrire quoi que ce soit) :
   (a) Tout : noms + descriptions + groupes
   (b) Noms + descriptions seulement
   (c) (Re)grouper par fonction seulement
   (d) Je définis moi-même les groupes / l'axe de regroupement

3. Si je demande les groupes, propose-moi d'abord la liste des groupes envisagés et
   leur contenu, et laisse-moi valider ou ajuster AVANT d'écrire.

4. N'écris QUE les champs que j'ai choisis ; préserve tout le reste : "_help",
   "groups" et leur "collapsed", ainsi que les "name"/"description"/"group"/"hidden"
   que je n'ai pas demandé de toucher. N'invente jamais de clé (utilise uniquement
   les "configKey" fournis). Termine en vérifiant que le JSON reste bien formé.
PROMPT
)"
```

Dans les deux cas, l'app **recharge le fichier à chaud** (polling mtime) — inutile de la relancer. Pour ne pas tout réécrire lors d'une relance, demande à Claude de « ne traiter que les items dont le `name` est vide ».

## Fichiers stockés sur le Mac

L'app ne touche au système que sur **action explicite** (Activer / Désactiver / Supprimer, avec confirmation) — jamais en tâche de fond, rien dans `/System`, aucun daemon installé. Elle écrit ces fichiers :

| Fichier | Rôle | Géré par |
|---|---|---|
| `~/Library/Application Support/LaunchInspector/config.json` | Tes personnalisations : groupes, noms, descriptions, masquages, états repliés. | L'app + Claude Code |
| `~/Library/Application Support/LaunchInspector/trash/` | Corbeille : `.plist` supprimés + `trash.json` (manifeste de restauration). | L'app |
| `~/Library/Preferences/LaunchInspector.plist` | État de fenêtre macOS : position/taille, largeurs de colonnes de la barre latérale. | macOS (automatique) |

**Désinstaller proprement** : supprimer le dossier `LaunchInspector` de `Application Support` et le `LaunchInspector.plist` de `Preferences`.

## Lancer

**Dans Xcode** (recommandé) — utilise DerivedData, donc pas d'effet Google Drive :
```sh
open Package.swift   # puis Cmd+R
```

**En ligne de commande** — placer le cache de build hors Google Drive :
```sh
swift build --scratch-path /tmp/li-build && /tmp/li-build/debug/LaunchInspector
```

**Mode headless** (liste dans le terminal, config appliquée, sans fenêtre) :
```sh
/tmp/li-build/debug/LaunchInspector --dump
```

**Mode JSON** (tous les jobs résolus — clé de config exacte, commande, planning, projet d'origine — sur stdout). Sert à Claude Code pour remplir `name`/`description` dans `config.json` sans avoir à localiser/parser les `.plist` :
```sh
/tmp/li-build/debug/LaunchInspector --dump-json > /tmp/li-jobs.json
```

## Limites connues (v1)

- **Restauration d'un symlink.** Supprimer un job dont le `.plist` est un symlink sauvegarde les octets de la cible ; la restauration recrée un **fichier régulier** (le `.plist` source du projet n'est pas re-symlinké). Comportement volontaire — les actions traitent tous les items de façon uniforme.
- **Pas d'horodatage de dernière exécution.** launchd n'expose aucune date de dernier déclenchement. On affiche le **compteur `runs`** (nb d'exécutions depuis le login/boot) comme approximation — pas une heure précise. Les crons n'ont pas de compteur (`—`).
- **Runtime des LaunchDaemons** : lu sans root via `launchctl print system/<label>` (chargé / en cours / `runs`). Les rares daemons dont `print` ne renvoie rien (non bootstrappés, ou réellement restreints) restent affichés « inconnu ».
- **Build CLI dans Google Drive** : `swift build` place `.build/` dans le dossier synchronisé → erreur `build.db disk I/O` et binaire périmé. Utiliser `--scratch-path /tmp/li-build` (ci-dessus) ou Xcode (DerivedData, non affecté).
- **Renommage/suppression de groupe** : via le fichier de config (ou l'agent). L'app permet de créer/assigner des groupes ; la gestion fine se fait dans `config.json`.
