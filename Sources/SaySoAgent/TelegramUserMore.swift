import Foundation
import SaySoCore

// Más herramientas con la cuenta de Telegram del usuario: envíos más completos (álbumes, encuestas,
// ubicación, contactos, dados, mensajes programados), gestión de chats y de la cuenta (fijar,
// silenciar, archivar, perfiles, contactos, bloqueos, grupos, enlaces) y lo menos habitual (votar,
// Mensajes guardados e historias). Todas pasan por el motor de permisos.

/// Un archivo para un álbum.
public struct TGOutgoingFile: Sendable, Hashable {
    public var data: Data
    public var filename: String
    public var kind: TGMediaKind

    public init(data: Data, filename: String, kind: TGMediaKind) {
        self.data = data
        self.filename = filename
        self.kind = kind
    }
}

/// Mensajes que no son texto ni archivo.
public enum TGSpecialContent: Sendable, Hashable {
    /// `correctOption`: con valor, es un cuestionario con esa respuesta buena (desde 0).
    case poll(question: String, options: [String], anonymous: Bool, multipleAnswers: Bool, correctOption: Int?)
    case location(latitude: Double, longitude: Double)
    /// La tarjeta de contacto de una persona de los chats del usuario.
    case contact(chatID: Int64)
    /// 🎲 🎯 🏀 ⚽ 🎳 🎰
    case dice(emoji: String)

    public static let diceEmojis = ["🎲", "🎯", "🏀", "⚽", "🎳", "🎰"]

    var label: String {
        switch self {
        case .poll(let question, _, _, _, let correct): return correct == nil ? "la encuesta «\(question)»" : "el cuestionario «\(question)»"
        case .location(let lat, let lon): return String(format: "la ubicación %.5f, %.5f", lat, lon)
        case .contact: return "una tarjeta de contacto"
        case .dice(let emoji): return "el dado \(emoji)"
        }
    }
}

/// Una historia activa de un chat.
public struct TGStory: Sendable, Hashable {
    public var id: Int
    public var date: Date
    public var caption: String
    /// «foto» o «vídeo».
    public var kind: String

    public init(id: Int, date: Date, caption: String, kind: String) {
        self.id = id
        self.date = date
        self.caption = caption
        self.kind = kind
    }
}

/// Un pack de stickers instalado.
public struct TGStickerPack: Sendable, Hashable {
    /// Identificador de TDLib (int64, en texto).
    public var id: String
    public var title: String
    public var count: Int

    public init(id: String, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// Una carpeta de chats.
public struct TGFolder: Sendable, Hashable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// Por defecto, una sesión que no sabe hacerlo lo dice.
public extension TelegramUserAPI {
    func send(chatID: Int64, text: String, at date: Date?) async throws {
        guard date == nil else { throw ToolInputError("Esta sesión de Telegram no puede programar mensajes.") }
        try await send(chatID: chatID, text: text)
    }
    func sendAlbum(chatID: Int64, files: [TGOutgoingFile], caption: String?) async throws { throw unsupported("enviar álbumes") }
    func sendSpecial(chatID: Int64, content: TGSpecialContent) async throws { throw unsupported("enviar ese tipo de mensaje") }
    func scheduledMessages(chatID: Int64) async throws -> [TGUserMessage] { throw unsupported("ver los mensajes programados") }
    func pin(chatID: Int64, messageID: Int64, pinned: Bool, onlyForSelf: Bool) async throws { throw unsupported("fijar mensajes") }
    func setMuted(chatID: Int64, muted: Bool) async throws { throw unsupported("silenciar chats") }
    func setArchived(chatID: Int64, archived: Bool) async throws { throw unsupported("archivar chats") }
    func profile(chatID: Int64) async throws -> String { throw unsupported("ver perfiles") }
    func addContact(chatID: Int64, firstName: String, lastName: String) async throws { throw unsupported("añadir contactos") }
    func setBlocked(chatID: Int64, blocked: Bool) async throws { throw unsupported("bloquear usuarios") }
    func createGroup(title: String, memberChatIDs: [Int64]) async throws -> TGUserChat { throw unsupported("crear grupos") }
    func addMembers(chatID: Int64, memberChatIDs: [Int64]) async throws { throw unsupported("añadir miembros") }
    func removeMember(chatID: Int64, memberChatID: Int64) async throws { throw unsupported("quitar miembros") }
    func join(inviteLink: String) async throws -> TGUserChat? { throw unsupported("unirse por enlace") }
    func leave(chatID: Int64) async throws { throw unsupported("salir de chats") }
    func messageLink(chatID: Int64, messageID: Int64) async throws -> String { throw unsupported("copiar enlaces") }
    func vote(chatID: Int64, messageID: Int64, options: [Int]) async throws { throw unsupported("votar en encuestas") }
    func savedMessagesChat() async throws -> TGUserChat { throw unsupported("usar Mensajes guardados") }
    func stories(chatID: Int64) async throws -> [TGStory] { throw unsupported("ver historias") }
    func stickerPacks() async throws -> [TGStickerPack] { throw unsupported("ver los stickers") }
    func sendSticker(chatID: Int64, emoji: String, packID: String?) async throws -> String { throw unsupported("enviar stickers") }
    func folders() async throws -> [TGFolder] { throw unsupported("ver las carpetas") }
    func folderChats(folderID: Int, limit: Int) async throws -> [TGUserChat] { throw unsupported("ver las carpetas") }
    func setInFolder(chatID: Int64, folderID: Int, included: Bool) async throws { throw unsupported("cambiar carpetas") }
    func createFolder(name: String, chatIDs: [Int64]) async throws -> TGFolder { throw unsupported("crear carpetas") }

    private func unsupported(_ what: String) -> ToolInputError {
        ToolInputError("Esta sesión de Telegram no puede \(what).")
    }
}

extension TelegramUserTools {
    /// Las herramientas de este archivo. `computer` hace falta para los álbumes (los archivos salen de ahí).
    static func more(api: TelegramUserAPI, broker: PermissionBrokering, limiter: SendRateLimiter,
                     computer: AgentComputer?) -> [AgentTool] {
        var tools: [AgentTool] = [
            SendPollTool(api: api, broker: broker, limiter: limiter),
            SendOtherTool(api: api, broker: broker, limiter: limiter),
            ScheduledMessagesTool(api: api, broker: broker),
            PinMessageTool(api: api, broker: broker),
            ChatSettingsTool(api: api, broker: broker),
            ProfileTool(api: api, broker: broker),
            ContactTool(api: api, broker: broker),
            GroupTool(api: api, broker: broker, limiter: limiter),
            MessageLinkTool(api: api, broker: broker),
            VoteTool(api: api, broker: broker),
            SavedMessagesTool(api: api, broker: broker),
            StoriesTool(api: api, broker: broker),
            StickerPacksTool(api: api, broker: broker),
            SendStickerTool(api: api, broker: broker, limiter: limiter),
            FoldersTool(api: api, broker: broker),
        ]
        if let computer { tools.insert(SendAlbumTool(api: api, broker: broker, limiter: limiter, computer: computer), at: 0) }
        return tools
    }

    /// Una fecha futura: ISO 8601 («2026-11-21T09:00»), con o sin zona; sin zona, la del Mac.
    static func futureDate(_ text: String, now: Date = Date()) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        var date = full.date(from: trimmed)
        if date == nil {
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = .current
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
                local.dateFormat = format
                if let parsed = local.date(from: trimmed) { date = parsed; break }
            }
        }
        guard let date else { throw ToolInputError("«send_at» debe ser una fecha como 2026-11-21T09:00.") }
        guard date > now.addingTimeInterval(30) else { throw ToolInputError("«send_at» tiene que ser en el futuro.") }
        guard date < now.addingTimeInterval(365 * 86_400) else { throw ToolInputError("Telegram solo programa hasta un año vista.") }
        return date
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM yyyy HH:mm"
        return f.string(from: date)
    }

    /// Varios chats de personas por nombre, @alias o número.
    static func resolvePeople(_ values: [JSONValue], api: TelegramUserAPI) async throws -> [TGUserChat] {
        var people: [TGUserChat] = []
        for value in values {
            let chat = try await resolveChat(["chat": value], api: api)
            guard chat.kind == .personal else { throw ToolInputError("«\(chat.title)» no es una persona: es un \(chat.kind.rawValue).") }
            if !people.contains(where: { $0.id == chat.id }) { people.append(chat) }
        }
        return people
    }
}

// MARK: - Envíos más completos

public struct SendAlbumTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let limiter: SendRateLimiter
    let computer: AgentComputer
    public var name: String { "telegram_send_album" }
    public var description: String {
        "Envía de 2 a 10 fotos o vídeos de tu ordenador Linux en un solo mensaje (un álbum), desde la cuenta del " +
            "usuario. También vale para varios documentos o varios audios, pero sin mezclarlos con fotos. Solo " +
            "para otras personas o grupos que el usuario haya nombrado: si las fotos son para él («envíamelas», " +
            "«mándamelas»), usa send_file sin «chat», una llamada por foto."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "paths": ["type": "array", "items": ["type": "string"], "description": "Rutas en el ordenador Linux (2 a 10)"],
            "caption": ["type": "string", "description": "Texto bajo el álbum (opcional)"],
        ], required: ["chat", "paths"])
    }

    /// Fotos y vídeos se pueden mezclar; documentos y audios van cada uno con los suyos.
    static func group(of kind: TGMediaKind) -> String {
        switch kind {
        case .photo, .video: return "fotos y vídeos"
        case .document: return "documentos"
        case .audio: return "audios"
        case .animation, .voice: return "no"
        }
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let paths = (input["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard (2...10).contains(paths.count) else { throw ToolInputError("Un álbum lleva entre 2 y 10 archivos.") }
        let kinds = paths.map(TGMediaKind.infer(from:))
        let groups = Set(kinds.map(Self.group(of:)))
        guard groups.count == 1, groups.first != "no" else {
            throw ToolInputError("Un álbum junta fotos y vídeos, o solo documentos, o solo audios. Los GIF y las notas de voz van sueltos.")
        }
        let caption = input["caption"]?.stringValue.map { String($0.prefix(1024)) }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        var files: [TGOutgoingFile] = []
        for (path, kind) in zip(paths, kinds) {
            let data = try await computer.readData(path, origin: context.origin)
            guard data.count <= 50 * 1024 * 1024 else { throw ToolInputError("\(path) pasa de 50 MB.") }
            // Los documentos de un álbum van como documento aunque sean fotos.
            files.append(TGOutgoingFile(data: data, filename: (path as NSString).lastPathComponent, kind: kind))
        }
        let id = chat.id
        let api = self.api
        let limiter = self.limiter
        let album = files
        try await broker.run(ActionRequest(
            action: TelegramAction.sendMessages, summary: "Enviar a «\(chat.title)» un álbum de \(files.count) archivos",
            parameters: ["Para": chat.title, "Archivos": files.map(\.filename).joined(separator: ", "), "Texto": caption ?? ""],
            origin: context.origin)) {
            try await limiter.take()
            try await api.sendAlbum(chatID: id, files: album, caption: caption)
        }
        return "Álbum de \(files.count) archivos enviado a «\(chat.title)»."
    }
}

public struct SendPollTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let limiter: SendRateLimiter
    public var name: String { "telegram_send_poll" }
    public var description: String {
        "Crea una encuesta en un chat desde la cuenta del usuario. Con «correct_option» es un cuestionario con una respuesta buena."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "question": .property("string", "La pregunta"),
            "options": ["type": "array", "items": ["type": "string"], "description": "Respuestas posibles (2 a 10)"],
            "anonymous": ["type": "boolean", "description": "Votos anónimos (sí por defecto)"],
            "multiple_answers": ["type": "boolean", "description": "Permitir varias respuestas (no por defecto)"],
            "correct_option": ["type": "integer", "description": "Solo para un cuestionario: la respuesta buena, desde 0"],
        ], required: ["chat", "question", "options"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let question = try input.requiredString("question", maxLength: 300)
        let options = (input["options"]?.arrayValue ?? []).compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (2...10).contains(options.count) else { throw ToolInputError("Una encuesta lleva entre 2 y 10 respuestas.") }
        guard options.allSatisfy({ $0.count <= 100 }) else { throw ToolInputError("Cada respuesta tiene 100 caracteres como mucho.") }
        let correct = input["correct_option"]?.intValue
        if let correct, !options.indices.contains(correct) { throw ToolInputError("«correct_option» no es ninguna de las respuestas.") }
        let multiple = input["multiple_answers"]?.boolValue ?? false
        if correct != nil, multiple { throw ToolInputError("Un cuestionario tiene una sola respuesta buena: sin «multiple_answers».") }
        let content = TGSpecialContent.poll(question: question, options: options,
                                            anonymous: input["anonymous"]?.boolValue ?? true,
                                            multipleAnswers: multiple, correctOption: correct)
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        // Telegram no deja mandar encuestas a un chat con una persona (comprobado contra la API).
        guard chat.kind != .personal else {
            throw ToolInputError("Telegram solo admite encuestas en grupos y canales, no en un chat con una persona.")
        }
        let id = chat.id
        let api = self.api
        let limiter = self.limiter
        try await broker.run(ActionRequest(
            action: TelegramAction.sendMessages, summary: "Enviar a «\(chat.title)» \(content.label)",
            parameters: ["Para": chat.title, "Pregunta": question, "Respuestas": options.joined(separator: " · ")],
            origin: context.origin)) {
            try await limiter.take()
            try await api.sendSpecial(chatID: id, content: content)
        }
        return "Enviada a «\(chat.title)» \(content.label)."
    }
}

public struct SendOtherTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let limiter: SendRateLimiter
    public var name: String { "telegram_send_other" }
    public var description: String {
        "Envía desde la cuenta del usuario una ubicación (type «location» con latitude y longitude), la tarjeta de " +
            "contacto de alguien de sus chats (type «contact» con «contact»: a quién se comparte) o un dado animado " +
            "(type «dice» con «emoji»: 🎲 🎯 🏀 ⚽ 🎳 o 🎰)."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "type": ["type": "string", "enum": ["location", "contact", "dice"]],
            "latitude": ["type": "number"], "longitude": ["type": "number"],
            "contact": ["type": "string", "description": "Para «contact»: la persona cuya tarjeta se envía"],
            "emoji": ["type": "string", "description": "Para «dice»"],
        ], required: ["chat", "type"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let content: TGSpecialContent
        var shared: TGUserChat?
        switch input["type"]?.stringValue {
        case "location":
            guard let lat = input["latitude"]?.doubleValue, let lon = input["longitude"]?.doubleValue,
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw ToolInputError("Para una ubicación hacen falta «latitude» (−90 a 90) y «longitude» (−180 a 180).")
            }
            content = .location(latitude: lat, longitude: lon)
        case "contact":
            let person = try await TelegramUserTools.resolveChat(["chat": input["contact"] ?? .null], api: api)
            guard person.kind == .personal else { throw ToolInputError("Solo se comparte la tarjeta de una persona.") }
            shared = person
            content = .contact(chatID: person.id)
        case "dice":
            let emoji = input["emoji"]?.stringValue ?? "🎲"
            guard TGSpecialContent.diceEmojis.contains(emoji) else {
                throw ToolInputError("«emoji» tiene que ser uno de \(TGSpecialContent.diceEmojis.joined(separator: " ")).")
            }
            content = .dice(emoji: emoji)
        default:
            throw ToolInputError("«type» tiene que ser location, contact o dice.")
        }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let limiter = self.limiter
        let what = shared.map { "la tarjeta de contacto de «\($0.title)»" } ?? content.label
        try await broker.run(ActionRequest(
            action: TelegramAction.sendMessages, summary: "Enviar a «\(chat.title)» \(what)",
            parameters: ["Para": chat.title, "Contenido": what], origin: context.origin)) {
            try await limiter.take()
            try await api.sendSpecial(chatID: id, content: content)
        }
        return "Enviada a «\(chat.title)» \(what)."
    }
}

public struct ScheduledMessagesTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_scheduled" }
    public var description: String {
        "Mensajes programados en Telegram (los que se crean con «send_at» en telegram_send_message y se envían aunque " +
            "el Mac esté apagado): action «list» los enseña con su número y «cancel» anula los de «message_ids»."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "action": ["type": "string", "enum": ["list", "cancel"]],
            "message_ids": ["type": "array", "items": ["type": "integer"], "description": "Para «cancel»"],
        ], required: ["chat", "action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        switch input["action"]?.stringValue {
        case "list":
            let items = try await broker.run(ActionRequest(
                action: TelegramAction.readMessages, summary: "Ver los mensajes programados de «\(chat.title)»",
                parameters: ["Chat": chat.title], origin: context.origin)) { try await api.scheduledMessages(chatID: id) }
            guard !items.isEmpty else { return "No hay mensajes programados en «\(chat.title)»." }
            return "Programados en «\(chat.title)»:\n" + items.sorted { $0.date < $1.date }
                .map { "#\($0.id) · \(TelegramUserTools.stamp($0.date)) · \($0.text)" }.joined(separator: "\n")
        case "cancel":
            let ids = (input["message_ids"]?.arrayValue ?? []).compactMap(\.intValue).map(Int64.init)
            guard (1...20).contains(ids.count) else { throw ToolInputError("«message_ids» admite entre 1 y 20 mensajes.") }
            try await broker.run(ActionRequest(
                action: TelegramAction.deleteMessages, summary: "Anular \(ids.count) mensaje(s) programado(s) de «\(chat.title)»",
                parameters: ["Chat": chat.title, "Mensajes": ids.map { "#\($0)" }.joined(separator: ", ")], origin: context.origin)) {
                try await api.delete(chatID: id, messageIDs: ids, forEveryone: true)
            }
            return "Anulado(s) \(ids.count) mensaje(s) programado(s) de «\(chat.title)»."
        default:
            throw ToolInputError("«action» tiene que ser list o cancel.")
        }
    }
}

// MARK: - Gestión de chats y de la cuenta

public struct PinMessageTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_pin" }
    public var description: String {
        "Fija (pinned true) o desfija (false) un mensaje en un chat. En un chat con otra persona, «only_for_self» lo fija solo para el usuario."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "message_id": ["type": "integer", "description": "Número del mensaje"],
            "pinned": ["type": "boolean", "description": "true fija, false desfija"],
            "only_for_self": ["type": "boolean", "description": "Solo en chats con una persona (falso por defecto)"],
        ], required: ["chat", "message_id", "pinned"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let messageID = try TelegramUserTools.messageID(input)
        guard let pinned = input["pinned"]?.boolValue else { throw ToolInputError("Falta «pinned»: true o false.") }
        let selfOnly = input["only_for_self"]?.boolValue ?? false
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let verb = pinned ? "Fijar" : "Desfijar"
        try await broker.run(ActionRequest(
            action: TelegramAction.pin, summary: "\(verb) el mensaje #\(messageID) de «\(chat.title)»",
            parameters: ["Chat": chat.title, "Mensaje": "#\(messageID)"], origin: context.origin)) {
            try await api.pin(chatID: id, messageID: messageID, pinned: pinned, onlyForSelf: selfOnly)
        }
        return "Mensaje #\(messageID) \(pinned ? "fijado" : "desfijado") en «\(chat.title)»."
    }
}

public struct ChatSettingsTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_chat_settings" }
    public var description: String {
        "Silencia (mute), vuelve a activar las notificaciones (unmute), archiva (archive) o saca del archivo (unarchive) un chat del usuario."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "action": ["type": "string", "enum": ["mute", "unmute", "archive", "unarchive"]],
        ], required: ["chat", "action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let action = input["action"]?.stringValue ?? ""
        let labels = ["mute": ("Silenciar", "silenciado"), "unmute": ("Activar las notificaciones de", "con notificaciones"),
                      "archive": ("Archivar", "archivado"), "unarchive": ("Sacar del archivo", "fuera del archivo")]
        guard let label = labels[action] else { throw ToolInputError("«action» tiene que ser mute, unmute, archive o unarchive.") }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        try await broker.run(ActionRequest(
            action: TelegramAction.organize, summary: "\(label.0) «\(chat.title)»",
            parameters: ["Chat": chat.title], origin: context.origin)) {
            switch action {
            case "mute", "unmute": try await api.setMuted(chatID: id, muted: action == "mute")
            default: try await api.setArchived(chatID: id, archived: action == "archive")
            }
        }
        return "«\(chat.title)» \(label.1)."
    }
}

public struct ProfileTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_profile" }
    public var description: String {
        "Ve el perfil de una persona (nombre, @alias, biografía, última conexión, si es contacto o está bloqueada) o la descripción y los miembros de un grupo o canal."
    }
    public var inputSchema: JSONValue { .objectSchema(["chat": TelegramUserTools.chatProperty], required: ["chat"]) }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let text = try await broker.run(ActionRequest(
            action: TelegramAction.readMessages, summary: "Ver el perfil de «\(chat.title)»",
            parameters: ["Chat": chat.title], origin: context.origin)) { try await api.profile(chatID: id) }
        return TelegramUserTools.untrusted + "\n" + text
    }
}

public struct ContactTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_contact" }
    public var description: String {
        "Añade una persona a los contactos del usuario (action «add», con el nombre con que guardarla), la bloquea («block») o la desbloquea («unblock»)."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "action": ["type": "string", "enum": ["add", "block", "unblock"]],
            "first_name": ["type": "string", "description": "Para «add»: nombre con que guardarla (por defecto, el suyo)"],
            "last_name": ["type": "string", "description": "Para «add»: apellidos (opcional)"],
        ], required: ["chat", "action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let action = input["action"]?.stringValue ?? ""
        guard ["add", "block", "unblock"].contains(action) else { throw ToolInputError("«action» tiene que ser add, block o unblock.") }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        guard chat.kind == .personal else { throw ToolInputError("«\(chat.title)» no es una persona.") }
        let id = chat.id
        let api = self.api
        let first = String((input["first_name"]?.stringValue ?? chat.title).prefix(64))
        let last = String((input["last_name"]?.stringValue ?? "").prefix(64))
        let summary: String
        switch action {
        case "add": summary = "Añadir a «\(chat.title)» a tus contactos como «\([first, last].filter { !$0.isEmpty }.joined(separator: " "))»"
        case "block": summary = "Bloquear a «\(chat.title)»"
        default: summary = "Desbloquear a «\(chat.title)»"
        }
        try await broker.run(ActionRequest(action: TelegramAction.contacts, summary: summary,
                                           parameters: ["Persona": chat.title], origin: context.origin)) {
            switch action {
            case "add": try await api.addContact(chatID: id, firstName: first, lastName: last)
            default: try await api.setBlocked(chatID: id, blocked: action == "block")
            }
        }
        switch action {
        case "add": return "«\(chat.title)» añadido a tus contactos."
        case "block": return "«\(chat.title)» bloqueado."
        default: return "«\(chat.title)» desbloqueado."
        }
    }
}

public struct GroupTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let limiter: SendRateLimiter
    public var name: String { "telegram_group" }
    public var description: String {
        """
        Grupos desde la cuenta del usuario: «create» crea uno con «title» y «members»; «add_members» añade \
        «members» al grupo «chat»; «remove_member» saca a «member» de «chat»; «join» entra con un «invite_link» \
        (t.me/+…); «leave» sale de «chat». Los miembros van por nombre, @alias o número.
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["create", "add_members", "remove_member", "join", "leave"]],
            "chat": ["type": "string", "description": "El grupo (salvo en create y join)"],
            "title": ["type": "string", "description": "Para «create»"],
            "members": ["type": "array", "items": ["type": "string"], "description": "Para «create» y «add_members» (hasta 20)"],
            "member": ["type": "string", "description": "Para «remove_member»"],
            "invite_link": ["type": "string", "description": "Para «join»"],
        ], required: ["action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let api = self.api
        let limiter = self.limiter
        switch input["action"]?.stringValue {
        case "create":
            let title = try input.requiredString("title", maxLength: 128)
            let people = try await TelegramUserTools.resolvePeople(input["members"]?.arrayValue ?? [], api: api)
            guard (1...20).contains(people.count) else { throw ToolInputError("Un grupo nuevo lleva entre 1 y 20 personas.") }
            let ids = people.map(\.id)
            let created = try await broker.run(ActionRequest(
                action: TelegramAction.groups, summary: "Crear el grupo «\(title)» con \(people.map(\.title).joined(separator: ", "))",
                parameters: ["Grupo": title, "Miembros": people.map(\.title).joined(separator: ", ")], origin: context.origin)) {
                try await limiter.take()
                return try await api.createGroup(title: title, memberChatIDs: ids)
            }
            return "Grupo «\(created.title)» creado (id \(created.id)) con \(people.count) persona(s)."
        case "add_members":
            let group = try await TelegramUserTools.resolveChat(input, api: api)
            guard group.kind == .group || group.kind == .channel else { throw ToolInputError("«\(group.title)» no es un grupo ni un canal.") }
            let people = try await TelegramUserTools.resolvePeople(input["members"]?.arrayValue ?? [], api: api)
            guard (1...20).contains(people.count) else { throw ToolInputError("Se añaden entre 1 y 20 personas de una vez.") }
            let ids = people.map(\.id)
            try await broker.run(ActionRequest(
                action: TelegramAction.groups, summary: "Añadir a «\(group.title)»: \(people.map(\.title).joined(separator: ", "))",
                parameters: ["Grupo": group.title, "Miembros": people.map(\.title).joined(separator: ", ")], origin: context.origin)) {
                try await limiter.take()
                try await api.addMembers(chatID: group.id, memberChatIDs: ids)
            }
            return "Añadido(s) \(people.count) a «\(group.title)»."
        case "remove_member":
            let group = try await TelegramUserTools.resolveChat(input, api: api)
            let person = try await TelegramUserTools.resolvePeople([input["member"] ?? .null], api: api)[0]
            try await broker.run(ActionRequest(
                action: TelegramAction.groups, summary: "Sacar a «\(person.title)» de «\(group.title)»",
                parameters: ["Grupo": group.title, "Persona": person.title], origin: context.origin)) {
                try await api.removeMember(chatID: group.id, memberChatID: person.id)
            }
            return "«\(person.title)» ya no está en «\(group.title)»."
        case "join":
            let link = try input.requiredString("invite_link", maxLength: 200).trimmingCharacters(in: .whitespaces)
            guard link.range(of: #"^(https?://)?(t\.me|telegram\.me)/(\+|joinchat/)[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
            else { throw ToolInputError("«invite_link» tiene que ser un enlace de invitación como t.me/+AbCd…") }
            let joined = try await broker.run(ActionRequest(
                action: TelegramAction.groups, summary: "Unirte al chat del enlace \(link)",
                parameters: ["Enlace": link], origin: context.origin)) { try await api.join(inviteLink: link) }
            return joined.map { "Te has unido a «\($0.title)» (id \($0.id))." }
                ?? "Solicitud enviada: un administrador del chat tiene que aprobarla."
        case "leave":
            let group = try await TelegramUserTools.resolveChat(input, api: api)
            guard group.kind != .personal else { throw ToolInputError("«\(group.title)» es una persona: para dejar de hablar con ella, archiva o bloquea.") }
            try await broker.run(ActionRequest(
                action: TelegramAction.groups, summary: "Salir de «\(group.title)»",
                parameters: ["Chat": group.title], origin: context.origin)) { try await api.leave(chatID: group.id) }
            return "Has salido de «\(group.title)»."
        default:
            throw ToolInputError("«action» tiene que ser create, add_members, remove_member, join o leave.")
        }
    }
}

public struct MessageLinkTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_message_link" }
    public var description: String { "Da el enlace (t.me/…) de un mensaje de un grupo o canal, para compartirlo." }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "message_id": ["type": "integer", "description": "Número del mensaje"],
        ], required: ["chat", "message_id"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let messageID = try TelegramUserTools.messageID(input)
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        guard chat.kind != .personal else { throw ToolInputError("Los mensajes de un chat con una persona no tienen enlace: solo los de grupos y canales.") }
        let id = chat.id
        let api = self.api
        let link = try await broker.run(ActionRequest(
            action: TelegramAction.readMessages, summary: "Copiar el enlace del mensaje #\(messageID) de «\(chat.title)»",
            parameters: ["Chat": chat.title], origin: context.origin)) { try await api.messageLink(chatID: id, messageID: messageID) }
        return "Enlace del mensaje #\(messageID) de «\(chat.title)»: \(link)"
    }
}

// MARK: - Menos habitual

public struct VoteTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_vote" }
    public var description: String {
        "Vota en una encuesta de un chat. telegram_read_messages enseña las encuestas con sus respuestas numeradas desde 0; " +
            "«options» son esos números (vacío retira el voto)."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "message_id": ["type": "integer", "description": "Número del mensaje con la encuesta"],
            "options": ["type": "array", "items": ["type": "integer"], "description": "Respuestas elegidas, desde 0"],
        ], required: ["chat", "message_id", "options"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let messageID = try TelegramUserTools.messageID(input)
        let options = (input["options"]?.arrayValue ?? []).compactMap(\.intValue)
        guard options.count <= 10, options.allSatisfy({ (0..<10).contains($0) }) else {
            throw ToolInputError("«options» son los números de las respuestas, de 0 a 9.")
        }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let what = options.isEmpty ? "Retirar tu voto" : "Votar \(options.map(String.init).joined(separator: ", "))"
        try await broker.run(ActionRequest(
            action: TelegramAction.vote, summary: "\(what) en la encuesta #\(messageID) de «\(chat.title)»",
            parameters: ["Chat": chat.title, "Encuesta": "#\(messageID)", "Respuestas": options.map(String.init).joined(separator: ", ")],
            origin: context.origin)) { try await api.vote(chatID: id, messageID: messageID, options: options) }
        return options.isEmpty ? "Voto retirado de la encuesta #\(messageID)." : "Votado en la encuesta #\(messageID) de «\(chat.title)»."
    }
}

public struct SavedMessagesTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_saved_messages" }
    public var description: String {
        "Los Mensajes guardados del usuario, su bloc de notas en Telegram: «save» guarda «text» y «read» lee las últimas notas."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["save", "read"]],
            "text": ["type": "string", "description": "Para «save»"],
            "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Para «read» (20 por defecto)"],
        ], required: ["action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let api = self.api
        switch input["action"]?.stringValue {
        case "save":
            let text = try input.requiredString("text", maxLength: 4096)
            try await broker.run(ActionRequest(
                action: TelegramAction.savedMessages, summary: "Guardar en Mensajes guardados: \(String(text.prefix(200)))",
                parameters: ["Nota": text], origin: context.origin)) {
                let saved = try await api.savedMessagesChat()
                try await api.send(chatID: saved.id, text: text)
            }
            return "Guardado en tus Mensajes guardados."
        case "read":
            let limit = try TelegramUserTools.limit(input, default: 20)
            let notes = try await broker.run(ActionRequest(
                action: TelegramAction.savedMessages, summary: "Leer \(limit) notas de Mensajes guardados", origin: context.origin)) {
                let saved = try await api.savedMessagesChat()
                return try await api.messages(chatID: saved.id, limit: limit)
            }
            return "Mensajes guardados.\n" + TelegramUserTools.render(notes)
        default:
            throw ToolInputError("«action» tiene que ser save o read.")
        }
    }
}

public struct StoriesTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_stories" }
    public var description: String { "Lista las historias activas de una persona o canal: fecha, si es foto o vídeo, y su texto." }
    public var inputSchema: JSONValue { .objectSchema(["chat": TelegramUserTools.chatProperty], required: ["chat"]) }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let stories = try await broker.run(ActionRequest(
            action: TelegramAction.readMessages, summary: "Ver las historias de «\(chat.title)»",
            parameters: ["Chat": chat.title], origin: context.origin)) { try await api.stories(chatID: id) }
        guard !stories.isEmpty else { return "«\(chat.title)» no tiene historias activas." }
        return TelegramUserTools.untrusted + "\nHistorias de «\(chat.title)»:\n" + stories.sorted { $0.date < $1.date }.map {
            "[\(TelegramUserTools.stamp($0.date))] \($0.kind)\($0.caption.isEmpty ? "" : ": \($0.caption)")"
        }.joined(separator: "\n")
    }
}

// MARK: - Stickers y carpetas

public struct StickerPacksTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_sticker_packs" }
    public var description: String { "Lista los packs de stickers que el usuario tiene instalados en Telegram, con su id." }
    public var inputSchema: JSONValue { .objectSchema([:]) }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let api = self.api
        let packs = try await broker.run(ActionRequest(action: TelegramAction.listChats, summary: "Ver tus packs de stickers",
                                                       origin: context.origin)) { try await api.stickerPacks() }
        guard !packs.isEmpty else { return "No tienes packs de stickers instalados." }
        return packs.map { "\($0.id) · \($0.title) · \($0.count) stickers" }.joined(separator: "\n")
    }
}

public struct SendStickerTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let limiter: SendRateLimiter
    public var name: String { "telegram_send_sticker" }
    public var description: String {
        "Envía un sticker de los packs del usuario que corresponda a un emoji (😂, 👍, ❤️…). Con «pack» (el id de " +
            "telegram_sticker_packs) lo busca solo en ese pack."
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "chat": TelegramUserTools.chatProperty,
            "emoji": .property("string", "Un emoji"),
            "pack": ["type": "string", "description": "Opcional: id del pack"],
        ], required: ["chat", "emoji"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let emoji = try input.requiredString("emoji", maxLength: 16).trimmingCharacters(in: .whitespaces)
        guard emoji.count == 1 else { throw ToolInputError("«emoji» tiene que ser un solo emoji.") }
        let pack = input["pack"]?.stringValue.flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil }
        if input["pack"]?.stringValue != nil, pack == nil { throw ToolInputError("«pack» es el id numérico de telegram_sticker_packs.") }
        let chat = try await TelegramUserTools.resolveChat(input, api: api)
        let id = chat.id
        let api = self.api
        let limiter = self.limiter
        let sent = try await broker.run(ActionRequest(
            action: TelegramAction.sendMessages, summary: "Enviar a «\(chat.title)» un sticker \(emoji)",
            parameters: ["Para": chat.title, "Sticker": emoji], origin: context.origin)) {
            try await limiter.take()
            return try await api.sendSticker(chatID: id, emoji: emoji, packID: pack)
        }
        return "Sticker \(sent) enviado a «\(chat.title)»."
    }
}

public struct FoldersTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    public var name: String { "telegram_folders" }
    public var description: String {
        """
        Carpetas de chats del usuario: «list» las enseña con su id; «chats» lista los chats de la carpeta \
        «folder»; «add» y «remove» meten o sacan «chat» de «folder»; «create» crea una con «name» y, si se \
        quiere, los «chats» que lleva. «folder» puede ser el id o el nombre.
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["list", "chats", "add", "remove", "create"]],
            "folder": ["type": "string", "description": "Id o nombre de la carpeta"],
            "chat": ["type": "string", "description": "Para «add» y «remove»"],
            "name": ["type": "string", "description": "Para «create» (12 caracteres como mucho)"],
            "chats": ["type": "array", "items": ["type": "string"], "description": "Para «create» (opcional, hasta 20)"],
        ], required: ["action"])
    }

    func folder(_ input: JSONValue) async throws -> TGFolder {
        guard let raw = input["folder"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? input["folder"]?.intValue.map(String.init),
              !raw.isEmpty else { throw ToolInputError("Falta «folder»: el id o el nombre de la carpeta.") }
        let all = try await api.folders()
        if let id = Int(raw), let found = all.first(where: { $0.id == id }) { return found }
        if let found = all.first(where: { $0.name.compare(raw, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return found
        }
        throw ToolInputError("No hay ninguna carpeta «\(raw)». Carpetas: \(all.map(\.name).joined(separator: ", ")).")
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        let api = self.api
        switch input["action"]?.stringValue {
        case "list":
            let all = try await broker.run(ActionRequest(action: TelegramAction.listChats, summary: "Ver tus carpetas de chats",
                                                         origin: context.origin)) { try await api.folders() }
            guard !all.isEmpty else { return "No tienes carpetas de chats." }
            return all.map { "\($0.id) · \($0.name)" }.joined(separator: "\n")
        case "chats":
            let folder = try await folder(input)
            let chats = try await broker.run(ActionRequest(action: TelegramAction.listChats, summary: "Ver los chats de la carpeta «\(folder.name)»",
                                                           origin: context.origin)) {
                try await api.folderChats(folderID: folder.id, limit: 50)
            }
            let visible = chats.filter { !TelegramUserFilter.isExcluded($0) }
            guard !visible.isEmpty else { return "La carpeta «\(folder.name)» está vacía." }
            return "Carpeta «\(folder.name)»:\n" + visible.map { "\($0.id) · \($0.kind.rawValue) · \($0.displayName)" }.joined(separator: "\n")
        case "add", "remove":
            let add = input["action"]?.stringValue == "add"
            let folder = try await folder(input)
            let chat = try await TelegramUserTools.resolveChat(input, api: api)
            try await broker.run(ActionRequest(
                action: TelegramAction.organize,
                summary: add ? "Meter «\(chat.title)» en la carpeta «\(folder.name)»" : "Sacar «\(chat.title)» de la carpeta «\(folder.name)»",
                parameters: ["Chat": chat.title, "Carpeta": folder.name], origin: context.origin)) {
                try await api.setInFolder(chatID: chat.id, folderID: folder.id, included: add)
            }
            return add ? "«\(chat.title)» está en «\(folder.name)»." : "«\(chat.title)» ya no está en «\(folder.name)»."
        case "create":
            let name = try input.requiredString("name", maxLength: 64).trimmingCharacters(in: .whitespaces)
            // Telegram corta los nombres de carpeta a 12 caracteres.
            guard (1...12).contains(name.count) else { throw ToolInputError("El nombre de una carpeta tiene de 1 a 12 caracteres.") }
            var chats: [TGUserChat] = []
            for value in (input["chats"]?.arrayValue ?? []).prefix(20) {
                let chat = try await TelegramUserTools.resolveChat(["chat": value], api: api)
                if !chats.contains(where: { $0.id == chat.id }) { chats.append(chat) }
            }
            guard !chats.isEmpty else { throw ToolInputError("Una carpeta nueva necesita al menos un chat en «chats».") }
            let ids = chats.map(\.id)
            let created = try await broker.run(ActionRequest(
                action: TelegramAction.organize, summary: "Crear la carpeta «\(name)» con \(chats.map(\.title).joined(separator: ", "))",
                parameters: ["Carpeta": name, "Chats": chats.map(\.title).joined(separator: ", ")], origin: context.origin)) {
                try await api.createFolder(name: name, chatIDs: ids)
            }
            return "Carpeta «\(created.name)» creada (id \(created.id)) con \(chats.count) chat(s)."
        default:
            throw ToolInputError("«action» tiene que ser list, chats, add, remove o create.")
        }
    }
}

// MARK: - Avisos por mensajes

/// `telegram_watch`: avisos que se disparan cuando llega algo a un chat del usuario.
public struct WatchTool: AgentTool {
    let api: TelegramUserAPI
    let broker: PermissionBrokering
    let store: SaySoStoring
    public init(api: TelegramUserAPI, broker: PermissionBrokering, store: SaySoStoring) {
        self.api = api
        self.broker = broker
        self.store = store
    }
    public var name: String { "telegram_watch" }
    public var description: String {
        """
        Avisos por mensajes de Telegram. «create»: cuando llegue algo a «chat» (y, con «keyword», solo si lo \
        contiene), al usuario le llega un aviso por su bot con los mensajes; con «instruction», en vez del \
        aviso tú sigues esa instrucción con lo que ha llegado («resúmelo», «avísame solo si piden algo») y le \
        mandas el resultado. Los mensajes se juntan durante un minuto. «list» los enseña; «delete» quita uno \
        por su id. Úsalo para «avísame cuando…», no para tareas a una hora (eso es schedule_task).
        """
    }
    public var inputSchema: JSONValue {
        .objectSchema([
            "action": ["type": "string", "enum": ["create", "list", "delete"]],
            "chat": TelegramUserTools.chatProperty,
            "keyword": .property("string", "Opcional: solo mensajes que contengan esta palabra"),
            "instruction": .property("string", "Opcional: qué hacer con lo que llegue"),
            "id": .property("string", "Para delete"),
        ], required: ["action"])
    }

    public func call(input: JSONValue, context: ToolContext) async throws -> String {
        var watches = MessageWatch.load(store)
        switch input["action"]?.stringValue {
        case "list":
            guard !watches.isEmpty else { return "No hay avisos." }
            return watches.map { w in
                var line = "\(w.id) · «\(w.chatTitle)»"
                if let k = w.keyword, !k.isEmpty { line += " · si contiene «\(k)»" }
                line += w.instruction.map { " · instrucción: \($0)" } ?? " · solo avisar"
                return line + (w.enabled ? "" : " · pausado")
            }.joined(separator: "\n")
        case "delete":
            let id = try input.requiredString("id", maxLength: 20)
            guard let index = watches.firstIndex(where: { $0.id == id }) else { throw ToolInputError("No hay ningún aviso \(id).") }
            let removed = watches.remove(at: index)
            MessageWatch.save(watches, store)
            return "Aviso de «\(removed.chatTitle)» quitado."
        case "create":
            guard watches.count < MessageWatch.maxWatches else {
                throw ToolInputError("Ya hay \(MessageWatch.maxWatches) avisos: quita alguno antes.")
            }
            let chat = try await TelegramUserTools.resolveChat(input, api: api)
            let keyword = try input.optionalString("keyword", maxLength: 100)?.trimmingCharacters(in: .whitespaces)
            let instruction = try input.optionalString("instruction", maxLength: 1000)?.trimmingCharacters(in: .whitespaces)
            let watch = MessageWatch(chatID: chat.id, chatTitle: chat.title,
                                     keyword: keyword?.isEmpty == false ? keyword : nil,
                                     instruction: instruction?.isEmpty == false ? instruction : nil)
            var summary = "Avisarte cuando llegue algo a «\(chat.title)»"
            if let k = watch.keyword { summary += " que contenga «\(k)»" }
            if let i = watch.instruction { summary += " y hacer: \(String(i.prefix(200)))" }
            var parameters = ["Chat": chat.title]
            if let k = watch.keyword { parameters["Palabra"] = k }
            if let i = watch.instruction { parameters["Instrucción"] = i }
            let store = self.store
            try await broker.run(ActionRequest(action: TelegramAction.watch, summary: summary, parameters: parameters,
                                               origin: context.origin)) {
                var current = MessageWatch.load(store)
                current.append(watch)
                MessageWatch.save(current, store)
            }
            return "Aviso creado (id \(watch.id)) para «\(chat.title)»."
        default:
            throw ToolInputError("«action» tiene que ser create, list o delete.")
        }
    }
}
