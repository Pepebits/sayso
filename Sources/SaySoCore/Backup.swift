import Foundation

// Copia de seguridad de la configuración: memoria, tareas, avisos, reglas, cuentas, plugins y
// ajustes, en un JSON que se puede llevar a otro Mac. Nunca lleva secretos, claves ni la sesión de
// Telegram (eso vive en el Llavero), ni conversaciones ni actividad.

public struct SaySoBackup: Codable, Sendable {
    /// Para poder leer copias de versiones anteriores.
    public var format: Int
    public var createdAt: Date
    public var appVersion: String
    public var notes: [MemoryNote]
    public var tasks: [ScheduledTask]
    public var rules: [String: String]
    public var settings: [String: String]
    /// Solo los nombres y para qué son: los valores se vuelven a guardar a mano.
    public var secretNames: [SecretMeta]

    public static let currentFormat = 1

    /// Ajustes que no viajan: son de este Mac (estado, medidas, lo instalado en la máquina Linux)
    /// o se rehacen solos.
    public static let localOnlySettings: Set<String> = [
        SettingsKey.contextUsage, SettingsKey.contextSummaries, SettingsKey.backgroundJobs,
        SettingsKey.agentRunning, GuardSettings.localInstalled, SettingsKey.budgetNotified,
    ]

    /// Ajustes de seguridad que una copia nunca cambia: quién es el dueño del bot, el acceso total,
    /// aprobar desde el bot y la protección. Un archivo manipulado no debe poder abrir la puerta.
    public static let protectedSettings: Set<String> = [
        SettingsKey.telegramOwnerID, SettingsKey.telegramBotID, SettingsKey.telegramBotName,
        SettingsKey.telegramFullAccess, SettingsKey.approveFromBot, GuardSettings.review, GuardSettings.detector,
    ]

    public init(format: Int = currentFormat, createdAt: Date = Date(), appVersion: String, notes: [MemoryNote],
                tasks: [ScheduledTask], rules: [String: String], settings: [String: String], secretNames: [SecretMeta]) {
        self.format = format
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.notes = notes
        self.tasks = tasks
        self.rules = rules
        self.settings = settings
        self.secretNames = secretNames
    }

    /// Lo que hay ahora en el almacén.
    public static func make(store: SaySoStoring, tasks: TaskStoring?, appVersion: String) throws -> SaySoBackup {
        let settings = try store.allSettings().filter { !localOnlySettings.contains($0.key) && !protectedSettings.contains($0.key) }
        return SaySoBackup(appVersion: appVersion, notes: try store.notes(), tasks: (try tasks?.tasks()) ?? [],
                           rules: Dictionary(uniqueKeysWithValues: try store.allRules().map { ($0.key.rawValue, $0.value.rawValue) }),
                           settings: settings,
                           secretNames: try store.secrets().map { SecretMeta(name: $0.name, reason: $0.reason, status: .requested) })
    }

    public struct Summary: Hashable, Sendable {
        public var notes = 0, tasks = 0, rules = 0, settings = 0, secrets = 0
        /// Lo que la copia traía y no se ha aplicado por seguridad.
        public var skipped = 0
    }

    /// Lo vuelca en el almacén sin borrar nada: las notas y tareas que ya existen no se repiten,
    /// las reglas y los ajustes se sobrescriben, y los secretos quedan como pendientes de guardar.
    @discardableResult
    public func restore(into store: SaySoStoring, tasks taskStore: TaskStoring?) throws -> Summary {
        var summary = Summary()
        let existingNotes = Set(try store.notes().map(\.text))
        for note in notes where !existingNotes.contains(note.text) {
            try store.addNote(MemoryNote(text: note.text, source: note.source, createdAt: note.createdAt, kind: note.kind))
            summary.notes += 1
        }
        if let taskStore {
            let existing = Set(try taskStore.tasks().map { "\($0.instruction)|\($0.schedule)" })
            for task in tasks where !existing.contains("\(task.instruction)|\(task.schedule)") {
                var copy = task
                copy.id = nil
                // «Enviar sin preguntar» lo vuelve a decidir el usuario en este Mac.
                if copy.sendWithoutAsking { copy.sendWithoutAsking = false; summary.skipped += 1 }
                try taskStore.addTask(copy)
                summary.tasks += 1
            }
        }
        for (action, raw) in rules {
            guard let rule = PermissionRule(rawValue: raw) else { continue }
            // Una copia puede endurecer reglas, pero no dejar que algo salga del Mac sin preguntar.
            if rule == .allow, GuardPolicy.isOutward(ActionID(action)) { summary.skipped += 1; continue }
            try store.setRule(rule, for: ActionID(action))
            summary.rules += 1
        }
        for (key, value) in settings where !Self.localOnlySettings.contains(key) {
            if Self.protectedSettings.contains(key) { summary.skipped += 1; continue }
            if key == SettingsKey.plugins {
                // Solo plugins del catálogo, con su definición de este Mac: ni URL ni comandos ajenos,
                // que recibirían los secretos del usuario.
                let restored = (try? JSONDecoder().decode([PluginConfig].self, from: Data(value.utf8))) ?? []
                let safe = restored.compactMap { config -> PluginConfig? in
                    guard var known = PluginCatalog.all.first(where: { $0.id == config.id }) else { return nil }
                    known.enabled = config.enabled
                    return known
                }
                summary.skipped += restored.count - safe.count
                // Los plugins que ya hay en este Mac se quedan como están.
                let current: [PluginConfig] = ((try? store.codableSetting(key)) ?? nil) ?? []
                let merged = current + safe.filter { config in !current.contains { $0.id == config.id } }
                try store.setCodableSetting(merged, for: key)
                summary.settings += 1
                continue
            }
            try store.setSetting(value, for: key)
            summary.settings += 1
        }
        let known = Set(try store.secrets().map(\.name))
        for meta in secretNames where !known.contains(meta.name) {
            try store.upsertSecret(SecretMeta(name: meta.name, reason: meta.reason, status: .requested))
            summary.secrets += 1
        }
        return summary
    }
}
