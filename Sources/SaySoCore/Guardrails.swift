import Foundation

// Protección frente a instrucciones coladas en contenido de terceros (inyección de prompt).
//
// La defensa principal siguen siendo las reglas de permisos. Esto añade una capa encima: en un turno
// en el que el agente ha leído algo que no escribió el usuario (una web, mensajes de otros), una
// acción hacia fuera con regla «Permitir» ya no pasa sin más. Un revisor con el modelo rápido
// comprueba que la acción cuadra con lo que pidió el usuario; si no cuadra, o si un detector ha visto
// un intento de inyección, se pregunta en el Mac.

/// Lo que se sabe del turno en curso. Lo pone el bucle del agente alrededor de cada herramienta y lo
/// lee el motor de permisos.
public struct GuardContext: Sendable, Hashable {
    /// Lo que pidió el usuario, con la última respuesta del agente delante para entender un «sí, hazlo».
    public var userRequest: String
    /// Herramientas que han traído contenido de terceros en este turno.
    public var thirdPartySources: [String]
    /// Contenido de terceros en el que el detector ha visto instrucciones para el agente.
    public var injectionFlags: [String]

    public init(userRequest: String, thirdPartySources: [String] = [], injectionFlags: [String] = []) {
        self.userRequest = userRequest
        self.thirdPartySources = thirdPartySources
        self.injectionFlags = injectionFlags
    }

    public var isTainted: Bool { !thirdPartySources.isEmpty }

    @TaskLocal public static var current: GuardContext?
}

public enum GuardPolicy {
    /// Acciones que salen del Mac o cambian algo del usuario: las que una inyección querría provocar.
    public static let outwardActions: Set<ActionID> = [
        TelegramAction.sendMessages, TelegramAction.deleteMessages, "telegram.sendFile", TelegramAction.guestReply,
        TelegramAction.forward, TelegramAction.edit, TelegramAction.react,
        TelegramAction.pin, TelegramAction.contacts, TelegramAction.groups, TelegramAction.vote,
        MacScript.openURL.action, MacScript.note.action, MacScript.reminder.action, MacScript.changeReminder.action, MacScript.changeCalendar.action,
        TaskAction.schedule, TaskAction.cancel, ComputerAction.useSecrets,
    ]

    public static func isOutward(_ action: ActionID) -> Bool { outwardActions.contains(action) }

    /// Si una herramienta trae contenido que no escribió el usuario, su nombre para el aviso.
    public static func thirdPartySource(tool: String, input: String) -> String? {
        switch tool {
        case "web_search": return "una búsqueda web"
        case "telegram_read_messages", "telegram_search_messages", "telegram_list_chats", "telegram_transcribe",
             "telegram_profile", "telegram_stories", "telegram_view_image":
            return "mensajes de Telegram de otras personas"
        case "computer_run":
            // Un comando que descarga algo de internet trae contenido ajeno en su salida.
            let lower = input.lowercased()
            return ["curl", "wget", "http://", "https://", "git clone", "pip download"].contains(where: lower.contains)
                ? "una descarga de internet" : nil
        default:
            if tool.hasPrefix("fetch__") || tool.hasPrefix("browser__") { return "una página web" }
            return nil
        }
    }

    /// Por qué se pregunta en vez de permitir, para el diálogo de confirmación.
    public static let reasonKey = "Por qué se pregunta"
}

/// Ajustes de la protección.
public enum GuardSettings {
    /// Revisar con IA las acciones hacia fuera tras leer contenido ajeno. Activado por defecto.
    public static let review = "guard.review"
    /// Detector de inyecciones: «off», «fast» (modelo rápido de la cuenta) o «local» (Prompt Guard en
    /// la máquina Linux).
    public static let detector = "guard.detector"

    public enum Detector: String, CaseIterable, Sendable { case off, fast, local }
}

/// Comprueba si una acción cuadra con lo que pidió el usuario. Devuelve el motivo para preguntar, o
/// `nil` si cuadra.
public protocol ActionReviewing: Sendable {
    func reasonToAsk(_ request: ActionRequest, context: GuardContext) async -> String?
}

/// Busca instrucciones para el agente dentro de un texto ajeno.
public protocol InjectionDetecting: Sendable {
    /// `true` si el texto parece intentar darle órdenes al asistente.
    func looksLikeInjection(_ text: String) async throws -> Bool
}

/// Estado del detector local en la máquina Linux.
public enum LocalDetectorState: Hashable, Sendable {
    case notInstalled, installing, installed
    case failed(String)
}

public extension GuardSettings {
    /// Repositorio del modelo local instalado en la máquina Linux (vacío: ninguno). Versiones
    /// anteriores guardaban «1», que era Prompt Guard 2 86M.
    static let localInstalled = "guard.localInstalled"
    /// Repositorio del modelo local elegido.
    static let localModel = "guard.localModel"
}

/// Un clasificador de inyecciones que se puede instalar en la máquina Linux.
public struct LocalGuardModel: Hashable, Sendable, Identifiable {
    public var id: String { repo }
    /// Repositorio de Hugging Face («organización/nombre»).
    public var repo: String
    public var name: String
    /// Tamaño aproximado de la descarga del modelo, en MB.
    public var sizeMB: Int?
    public var languages: String
    public var license: String
    /// Hay que aceptar la licencia en Hugging Face y guardar HF_TOKEN para descargarlo.
    public var needsToken: Bool
    /// Lo que hay que saber antes de elegirlo.
    public var note: String

    public init(repo: String, name: String, sizeMB: Int?, languages: String, license: String, needsToken: Bool,
                note: String) {
        self.repo = repo
        self.name = name
        self.sizeMB = sizeMB
        self.languages = languages
        self.license = license
        self.needsToken = needsToken
        self.note = note
    }

    /// Los comprobados en Hugging Face (acceso, licencia, idiomas, tamaño y etiquetas) el 20/11/2026.
    public static let catalog: [LocalGuardModel] = [
        LocalGuardModel(repo: "meta-llama/Llama-Prompt-Guard-2-86M", name: "Llama Prompt Guard 2 · 86M", sizeMB: 1115,
                        languages: "Multilingüe (incluye español)", license: "Llama 4 Community", needsToken: true,
                        note: "El más preciso y el único entrenado en español. Hay que aceptar la licencia de Meta en Hugging Face y guardar HF_TOKEN en Secretos."),
        LocalGuardModel(repo: "meta-llama/Llama-Prompt-Guard-2-22M", name: "Llama Prompt Guard 2 · 22M", sizeMB: 283,
                        languages: "Sobre todo inglés", license: "Llama 4 Community", needsToken: true,
                        note: "Pequeño y rápido, pero acierta bastante menos fuera del inglés. Mismos requisitos que el de 86M."),
        LocalGuardModel(repo: "protectai/deberta-v3-base-prompt-injection-v2", name: "ProtectAI DeBERTa v3 · v2", sizeMB: 738,
                        languages: "Solo inglés", license: "Apache 2.0", needsToken: false,
                        note: "Libre: se descarga sin cuenta. Muy usado, pero solo entrenado en inglés: en español detectará peor."),
        LocalGuardModel(repo: "deepset/deberta-v3-base-injection", name: "deepset DeBERTa v3", sizeMB: 738,
                        languages: "Inglés y alemán", license: "MIT", needsToken: false,
                        note: "Libre: se descarga sin cuenta. Más antiguo y con menos uso que el de ProtectAI."),
    ]

    public static let recommended = catalog[0]

    /// Uno del catálogo, o uno propio del que solo se sabe el repositorio.
    public static func model(repo: String) -> LocalGuardModel {
        catalog.first { $0.repo == repo } ?? LocalGuardModel(
            repo: repo, name: repo, sizeMB: nil, languages: "Desconocido", license: "Consúltala en Hugging Face",
            needsToken: false,
            note: "Modelo propio: tiene que ser de clasificación de texto (transformers). Si es de acceso restringido, acepta su licencia y guarda HF_TOKEN.")
    }

    /// «organización/nombre» con caracteres válidos.
    public static func isValidRepo(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            && text.count <= 96
    }

    /// Carpeta del modelo en la máquina Linux.
    public var folder: String { repo.replacingOccurrences(of: "/", with: "--") }
}
