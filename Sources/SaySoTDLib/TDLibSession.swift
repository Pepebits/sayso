import Foundation
import SaySoAgent
import SaySoCore

public struct TDError: Error, LocalizedError, Equatable, Sendable {
    public var code: Int
    public var message: String

    public var errorDescription: String? {
        switch message {
        case "PHONE_NUMBER_INVALID": return tr("El número de teléfono no es válido. Escríbelo con prefijo internacional, por ejemplo +34…")
        case "PHONE_CODE_INVALID": return tr("El código no es correcto.")
        case "PHONE_CODE_EXPIRED": return tr("El código ha caducado. Vuelve a empezar.")
        case "PASSWORD_HASH_INVALID": return tr("La contraseña de verificación en dos pasos no es correcta.")
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD": return tr("El api_id o el api_hash no son válidos.")
        default:
            if message.hasPrefix("FLOOD_WAIT") || code == 429 { return tr("Telegram pide esperar antes de volver a intentarlo.") }
            return tr("Telegram respondió: %@", "\(message)")
        }
    }
}

/// Parámetros de la sesión. El `api_hash` y la clave de la base de datos vienen del Llavero.
public struct TDLibConfig: Sendable {
    public var apiID: Int
    public var apiHash: String
    public var directory: URL
    public var databaseKey: Data

    public init(apiID: Int, apiHash: String, directory: URL, databaseKey: Data) {
        self.apiID = apiID
        self.apiHash = apiHash
        self.directory = directory
        self.databaseKey = databaseKey
    }
}

/// Sesión de usuario de Telegram sobre TDLib: inicio de sesión y las cinco operaciones
/// que ven las herramientas del agente. Los chats secretos están desactivados en TDLib.
public actor TDLibSession: TelegramUserAPI {
    private let transport: TDTransport
    private let config: TDLibConfig
    private let onState: @Sendable (TelegramUserState) -> Void
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextExtra = 1
    /// Mensajes con archivo que esperan a que Telegram confirme la subida.
    private var deliveries: [Int64: CheckedContinuation<Void, Error>] = [:]
    private var parametersSent = false
    private var pump: Task<Void, Never>?
    private var userNames: [Int64: String] = [:]
    private var chatCache: [Int64: TGUserChat] = [:]
    /// Alias por usuario o supergrupo; `""` si no tiene.
    private var aliases: [String: String] = [:]
    /// Carpetas de chats: TDLib las manda en `updateChatFolders` y no tiene una petición para leerlas.
    var chatFolders: [TGFolder] = []
    /// Quien quiera enterarse de los mensajes que llegan (los avisos).
    private var incoming: (@Sendable (TGUserMessage) -> Void)?

    /// Chats a los que no se escribe nunca desde la cuenta: el del propio bot de SaySo. Lo que se
    /// mandara ahí llegaría al agente como si lo hubiera escrito el usuario.
    private var blockedTargets: @Sendable () -> Set<Int64> = { [] }
    public func blockWrites(to targets: @escaping @Sendable () -> Set<Int64>) { blockedTargets = targets }

    func checkTarget(_ chatID: Int64) throws {
        if blockedTargets().contains(chatID) {
            throw ToolInputError("Ese chat es tu propia conversación con el bot de SaySo: desde la cuenta no se escribe ahí. Pon el contenido en tu respuesta.")
        }
    }

    /// Avisa de cada mensaje nuevo que llega a la cuenta (no los enviados ni los programados).
    public func onNewMessage(_ handler: (@Sendable (TGUserMessage) -> Void)?) { incoming = handler }
    public private(set) var state: TelegramUserState = .off {
        didSet { if state != oldValue { onState(state) } }
    }

    public init(config: TDLibConfig, transport: TDTransport,
                onState: @escaping @Sendable (TelegramUserState) -> Void) {
        self.config = config
        self.transport = transport
        self.onState = onState
    }

    // MARK: Ciclo de vida

    public func start() {
        guard pump == nil else { return }
        state = .connecting
        let stream = transport.incoming
        pump = Task { [weak self] in
            for await message in stream { await self?.handle(message) }
        }
        // Cualquier petición despierta al cliente, que entonces anuncia su estado de autorización
        // con `updateAuthorizationState`. La respuesta directa a esta petición se ignora.
        transport.send(["@type": "getOption", "name": "version"])
    }

    /// Cierra la conexión conservando la sesión en disco.
    public func stop() {
        transport.send(["@type": "close"])
        finish(.off)
    }

    private var closedWaiters: [CheckedContinuation<Void, Never>] = []

    /// Para antes de salir de la app: pide el cierre y espera a que TDLib confirme que ha terminado
    /// (`authorizationStateClosed`). Si el proceso sale mientras TDLib aún está cerrando, la
    /// librería aborta al destruirse y macOS apunta un cierre inesperado. Si no contesta en
    /// `timeout`, se sigue adelante.
    public func stopAndWait(timeout: TimeInterval = 3) async {
        guard pump != nil else { return }
        transport.send(["@type": "close"])
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finish(.off)
        }
        await withCheckedContinuation { closedWaiters.append($0) }
        timer.cancel()
    }

    /// Cierra la sesión en Telegram y borra los datos locales de TDLib.
    public func logOut() async {
        _ = try? await request(["@type": "logOut"])
    }

    private func finish(_ final: TelegramUserState) {
        let waiters = closedWaiters
        closedWaiters = []
        defer { waiters.forEach { $0.resume() } }
        pump?.cancel()
        pump = nil
        transport.close()
        for (_, continuation) in pending { continuation.resume(throwing: TelegramUserError.notReady) }
        pending = [:]
        state = final
    }

    // MARK: Mensajes entrantes

    private func handle(_ message: JSONValue) {
        if let extra = message["@extra"]?.stringValue, let continuation = pending.removeValue(forKey: extra) {
            if message["@type"]?.stringValue == "error" {
                continuation.resume(throwing: TDError(code: message["code"]?.intValue ?? 0,
                                                      message: message["message"]?.stringValue ?? "error"))
            } else {
                continuation.resume(returning: message)
            }
            return
        }
        switch message["@type"]?.stringValue {
        case "updateAuthorizationState":
            if let auth = message["authorization_state"] { authorization(auth) }
        case "updateMessageSendSucceeded":
            if let id = message["old_message_id"]?.intValue { finishDelivery(Int64(id), error: nil) }
        case "updateMessageSendFailed":
            if let id = message["old_message_id"]?.intValue {
                finishDelivery(Int64(id), error: TDError(code: message["error"]?["code"]?.intValue ?? 0,
                                                         message: message["error"]?["message"]?.stringValue ?? "error"))
            }
        case "updateNewMessage":
            guard let handler = incoming, let raw = message["message"],
                  raw["is_outgoing"]?.boolValue != true, raw["scheduling_state"] == nil else { break }
            Task { [weak self] in
                guard let converted = await self?.convert([raw]).first else { return }
                handler(converted)
            }
        case "updateChatFolders":
            chatFolders = (message["chat_folders"]?.arrayValue ?? []).compactMap { info in
                guard let id = info["id"]?.intValue else { return nil }
                return TGFolder(id: id, name: info["name"]?["text"]?["text"]?.stringValue ?? "")
            }
        case "updateUser":
            if let user = message["user"], let id = user["id"]?.intValue { userNames[Int64(id)] = Self.name(of: user) }
        default:
            break
        }
    }

    private func authorization(_ auth: JSONValue) {
        switch auth["@type"]?.stringValue {
        case "authorizationStateWaitTdlibParameters":
            // TDLib rechaza un segundo envío de parámetros: se mandan una sola vez.
            guard !parametersSent else { return }
            parametersSent = true
            try? FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
            fire([
                "@type": "setTdlibParameters",
                "database_directory": .string(config.directory.appendingPathComponent("db").path),
                "files_directory": .string(config.directory.appendingPathComponent("files").path),
                "database_encryption_key": .string(config.databaseKey.base64EncodedString()),
                "use_file_database": false, "use_chat_info_database": true, "use_message_database": true,
                // Los chats secretos quedan fuera del alcance del agente desde la raíz.
                "use_secret_chats": false,
                "api_id": .number(Double(config.apiID)), "api_hash": .string(config.apiHash),
                "system_language_code": "es", "device_model": "Mac", "system_version": "macOS",
                "application_version": "0.1",
            ])
        case "authorizationStateWaitPhoneNumber":
            state = .waitingPhone
        case "authorizationStateWaitCode":
            state = .waitingCode(Self.codeHint(auth["code_info"]))
        case "authorizationStateWaitPassword":
            state = .waitingPassword(hint: auth["password_hint"]?.stringValue ?? "")
        case "authorizationStateReady":
            if !state.isReady { state = .ready("") }
            Task { await self.loadMe() }
        case "authorizationStateWaitOtherDeviceConfirmation", "authorizationStateWaitEmailAddress",
             "authorizationStateWaitEmailCode", "authorizationStateWaitRegistration",
             "authorizationStateWaitPremiumPurchase":
            state = .failed("Telegram pide un paso de inicio de sesión que SaySo aún no admite. Complétalo en la app oficial y vuelve a intentarlo.")
        case "authorizationStateClosed":
            finish(.off)
        default:
            break // LoggingOut, Closing
        }
    }

    private func loadMe() async {
        guard let me = try? await request(["@type": "getMe"]) else { return }
        state = .ready(Self.name(of: me))
    }

    /// Descarga la foto de perfil pequeña de la cuenta y devuelve dónde ha quedado en este Mac.
    /// `nil` si la cuenta no tiene foto o no se pudo descargar.
    public func profilePhoto() async -> URL? {
        guard state.isReady, let me = try? await request(["@type": "getMe"]),
              let fileID = me["profile_photo"]?["small"]?["id"]?.intValue else { return nil }
        guard let file = try? await request([
            "@type": "downloadFile", "file_id": .number(Double(fileID)), "priority": 1,
            "offset": 0, "limit": 0, "synchronous": true,
        ]), file["local"]?["is_downloading_completed"]?.boolValue == true,
            let path = file["local"]?["path"]?.stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Descarga la foto pequeña de un chat (la de la persona o la del grupo). `nil` si no tiene.
    public func chatPhoto(chatID: Int64) async -> URL? {
        guard state.isReady,
              let chat = try? await request(["@type": "getChat", "chat_id": .number(Double(chatID))]),
              let fileID = chat["photo"]?["small"]?["id"]?.intValue else { return nil }
        guard let file = try? await request([
            "@type": "downloadFile", "file_id": .number(Double(fileID)), "priority": 1,
            "offset": 0, "limit": 0, "synchronous": true,
        ]), file["local"]?["is_downloading_completed"]?.boolValue == true,
            let path = file["local"]?["path"]?.stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func codeHint(_ info: JSONValue?) -> String {
        switch info?["type"]?["@type"]?.stringValue {
        case "authenticationCodeTypeTelegramMessage": return tr("Telegram te ha enviado el código a tu app de Telegram en otro dispositivo.")
        case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase":
            return tr("Telegram te ha enviado el código por SMS.")
        case "authenticationCodeTypeCall", "authenticationCodeTypeFlashCall", "authenticationCodeTypeMissedCall":
            return tr("Telegram te dará el código con una llamada.")
        default: return tr("Telegram te ha enviado un código.")
        }
    }

    static func name(of user: JSONValue) -> String {
        let parts = [user["first_name"]?.stringValue, user["last_name"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? tr("Usuario") : parts.joined(separator: " ")
    }

    // MARK: Peticiones

    private func fire(_ body: JSONValue) {
        Task {
            do { _ = try await self.request(body) } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func request(_ body: JSONValue) async throws -> JSONValue {
        guard pump != nil, var object = body.objectValue else { throw TelegramUserError.notReady }
        let extra = "r\(nextExtra)"
        nextExtra += 1
        object["@extra"] = .string(extra)
        return try await withCheckedThrowingContinuation { continuation in
            pending[extra] = continuation
            transport.send(.object(object))
        }
    }

    /// Límite de lo que TDLib guarda en disco (fotos, audios y archivos descargados).
    public static let storageLimitBytes = 300 * 1024 * 1024
    public static let storageMaxAgeDays = 14

    /// Borra los archivos descargados que no se han usado en `storageMaxAgeDays` días y, si aun
    /// así pasan de `storageLimitBytes`, los más antiguos. TDLib los vuelve a bajar si hacen falta.
    public func optimizeStorage() async throws {
        _ = try await request([
            "@type": "optimizeStorage",
            "size": .number(Double(Self.storageLimitBytes)),
            "ttl": .number(Double(Self.storageMaxAgeDays * 86_400)),
            "count": -1, "immunity_delay": -1,
            "file_types": [], "chat_ids": [], "exclude_chat_ids": [],
            "return_deleted_file_statistics": false, "chat_limit": 0,
        ])
    }

    // MARK: Inicio de sesión (los datos los escribe el usuario en la app)

    public func submitPhone(_ phone: String) async throws {
        _ = try await request(["@type": "setAuthenticationPhoneNumber", "phone_number": .string(phone)])
    }

    public func submitCode(_ code: String) async throws {
        _ = try await request(["@type": "checkAuthenticationCode", "code": .string(code)])
    }

    public func submitPassword(_ password: String) async throws {
        _ = try await request(["@type": "checkAuthenticationPassword", "password": .string(password)])
    }

    // MARK: TelegramUserAPI

    func requireReady() throws {
        guard state.isReady else { throw TelegramUserError.notReady }
    }

    public func chats(limit: Int) async throws -> [TGUserChat] {
        try requireReady()
        let list: JSONValue = ["@type": "chatListMain"]
        // `loadChats` devuelve error 404 cuando ya no quedan más: no es un fallo.
        _ = try? await request(["@type": "loadChats", "chat_list": list, "limit": .number(Double(limit))])
        let result = try await request(["@type": "getChats", "chat_list": list, "limit": .number(Double(limit))])
        var out: [TGUserChat] = []
        for id in (result["chat_ids"]?.arrayValue ?? []).compactMap(\.intValue) {
            if let chat = try? await chat(id: Int64(id)) { out.append(chat) }
        }
        return out
    }

    public func findChats(query: String, limit: Int) async throws -> [TGUserChat] {
        try requireReady()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [Int64] = []
        func add(_ id: Int?) { if let id, !ids.contains(Int64(id)) { ids.append(Int64(id)) } }
        // Un alias público se resuelve directamente, se haya hablado antes con él o no.
        let alias = text.hasPrefix("@") ? String(text.dropFirst()) : text
        if !alias.isEmpty, alias.range(of: #"^[A-Za-z0-9_]{4,32}$"#, options: .regularExpression) != nil,
           let found = try? await request(["@type": "searchPublicChat", "username": .string(alias)]) {
            add(found["id"]?.intValue)
        }
        if !text.hasPrefix("@") {
            // Por nombre: primero los contactos, que es donde está la gente a la que se escribe.
            if let contacts = try? await request(["@type": "searchContacts", "query": .string(text),
                                                  "limit": .number(Double(limit))]) {
                for userID in (contacts["user_ids"]?.arrayValue ?? []).compactMap(\.intValue) {
                    let chat = try? await request(["@type": "createPrivateChat", "user_id": .number(Double(userID)),
                                                   "force": false])
                    add(chat?["id"]?.intValue)
                }
            }
            // Después lo que TDLib ya conoce y lo que sabe el servidor.
            for method in ["searchChats", "searchChatsOnServer"] {
                let result = try? await request(["@type": .string(method), "query": .string(text),
                                                 "limit": .number(Double(limit))])
                for id in (result?["chat_ids"]?.arrayValue ?? []).compactMap(\.intValue) { add(id) }
            }
        }
        var out: [TGUserChat] = []
        for id in ids.prefix(limit) {
            if let chat = try? await chat(id: id) { out.append(chat) }
        }
        if !text.hasPrefix("@") {
            // Lo que la búsqueda de Telegram no encuentra (cuentas eliminadas, nombres mal oídos)
            // se busca a mano entre los chats recientes.
            let recent = (try? await chats(limit: 200)) ?? []
            for chat in Self.localMatches(text, in: recent, fuzzy: out.isEmpty) where !out.contains(where: { $0.id == chat.id }) {
                out.append(chat)
            }
            out = Array(out.prefix(limit))
        }
        // Personas antes que grupos, y grupos antes que canales: a un canal casi nunca se le escribe.
        func rank(_ chat: TGUserChat) -> Int {
            switch chat.kind {
            case .personal: return 0
            case .group: return 1
            case .channel, .secret: return 2
            }
        }
        return out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    public func chat(id: Int64) async throws -> TGUserChat {
        try requireReady()
        let raw = try await request(["@type": "getChat", "chat_id": .number(Double(id))])
        var chat = Self.chat(from: raw, id: id)
        chat.username = await alias(of: raw)
        chatCache[id] = chat
        return chat
    }

    /// Primer alias activo de una persona o un supergrupo. TDLib lo tiene en local; se guarda igual
    /// para no preguntarlo en cada lista.
    private func alias(of rawChat: JSONValue) async -> String? {
        let type = rawChat["type"]
        let key: String
        let query: JSONValue
        switch type?["@type"]?.stringValue {
        case "chatTypePrivate", "chatTypeSecret":
            guard let user = type?["user_id"]?.intValue else { return nil }
            key = "u\(user)"
            query = ["@type": "getUser", "user_id": .number(Double(user))]
        case "chatTypeSupergroup":
            guard let group = type?["supergroup_id"]?.intValue else { return nil }
            key = "s\(group)"
            query = ["@type": "getSupergroup", "supergroup_id": .number(Double(group))]
        default:
            return nil
        }
        if let cached = aliases[key] { return cached.isEmpty ? nil : cached }
        let found = (try? await request(query)).flatMap { Self.alias(fromUsernames: $0["usernames"]) }
        aliases[key] = found ?? ""
        return found
    }

    static func alias(fromUsernames usernames: JSONValue?) -> String? {
        let active = usernames?["active_usernames"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return active.first { !$0.isEmpty } ?? usernames?["editable_username"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Texto para comparar nombres: sin mayúsculas, sin tildes y sin signos.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// Distancia de edición entre dos textos.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let current = row[j]
                row[j] = x[i - 1] == y[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[y.count]
    }

    /// Chats cuyo título contiene lo buscado. Con `fuzzy`, si ninguno lo contiene, los que más se
    /// parecen: un nombre dictado llega a menudo con una letra cambiada («Lukas» por «Lucas»).
    static func localMatches(_ query: String, in chats: [TGUserChat], fuzzy: Bool) -> [TGUserChat] {
        let needle = normalized(query)
        guard needle.count >= 2 else { return [] }
        let bare = needle.hasPrefix("@") ? String(needle.dropFirst()) : needle
        let exact = chats.filter {
            normalized($0.title).contains(needle) || ($0.username.map { normalized($0).contains(normalized(bare)) } ?? false)
        }
        guard exact.isEmpty, fuzzy, needle.count >= 4 else { return exact }
        let words = needle.split(separator: " ").map(String.init)
        var scored: [(TGUserChat, Double)] = []
        for chat in chats {
            let title = normalized(chat.title)
            guard !title.isEmpty else { continue }
            let titleWords = title.split(separator: " ").map(String.init)
            // Cada palabra buscada se compara con la palabra del título que más se le parece.
            var total = 0.0
            for word in words {
                let best = titleWords.map { 1 - Double(distance(word, $0)) / Double(max(word.count, $0.count)) }.max() ?? 0
                total += best
            }
            let score = total / Double(words.count)
            if score >= 0.6 { scored.append((chat, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    static func chat(from raw: JSONValue, id: Int64) -> TGUserChat {
        let kind: TGUserChat.Kind
        switch raw["type"]?["@type"]?.stringValue {
        case "chatTypeSecret": kind = .secret
        case "chatTypeBasicGroup": kind = .group
        case "chatTypeSupergroup": kind = raw["type"]?["is_channel"]?.boolValue == true ? .channel : .group
        default: kind = .personal
        }
        return TGUserChat(id: id, title: raw["title"]?.stringValue ?? "", kind: kind,
                          unread: raw["unread_count"]?.intValue ?? 0,
                          lastMessage: raw["last_message"].map { text(of: $0) })
    }

    public func messages(chatID: Int64, limit: Int) async throws -> [TGUserMessage] {
        try requireReady()
        var collected: [JSONValue] = []
        var from = 0
        // TDLib puede devolver menos de lo pedido en cada llamada: se insiste unas pocas veces.
        for _ in 0..<5 where collected.count < limit {
            let result = try await request([
                "@type": "getChatHistory", "chat_id": .number(Double(chatID)), "from_message_id": .number(Double(from)),
                "offset": 0, "limit": .number(Double(limit - collected.count)), "only_local": false,
            ])
            let batch = result["messages"]?.arrayValue ?? []
            guard !batch.isEmpty, let last = batch.last?["id"]?.intValue else { break }
            collected += batch
            from = last
        }
        return await convert(collected)
    }

    public func search(query: String, chatID: Int64?, limit: Int) async throws -> [TGUserMessage] {
        try requireReady()
        let result: JSONValue
        if let chatID {
            result = try await request([
                "@type": "searchChatMessages", "chat_id": .number(Double(chatID)), "query": .string(query),
                "from_message_id": 0, "offset": 0, "limit": .number(Double(limit)),
            ])
        } else {
            result = try await request([
                "@type": "searchMessages", "query": .string(query), "offset": "", "limit": .number(Double(limit)),
            ])
        }
        var messages = await convert(result["messages"]?.arrayValue ?? [])
        if chatID == nil {
            // Una búsqueda global puede traer mensajes de chats excluidos.
            var allowed: [Int64: Bool] = [:]
            for id in Set(messages.map(\.chatID)) {
                let chat = chatCache[id]
                let known: TGUserChat? = chat != nil ? chat : try? await self.chat(id: id)
                allowed[id] = known.map { !TelegramUserFilter.isExcluded($0) } ?? false
            }
            messages = messages.filter { allowed[$0.chatID] == true }
        }
        return messages
    }

    public func send(chatID: Int64, text: String) async throws {
        try checkTarget(chatID)
        try requireReady()
        _ = try await request([
            "@type": "sendMessage", "chat_id": .number(Double(chatID)),
            "input_message_content": ["@type": "inputMessageText",
                                      "text": ["@type": "formattedText", "text": .string(text)]],
        ])
    }

    /// Carpeta de donde TDLib sube los archivos salientes. Se vacía de lo que tenga más de una hora.
    static func outgoingFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-salida", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-3600)
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, created < old {
                try? FileManager.default.removeItem(at: item)
            }
        }
        return folder
    }

    /// Contenido de un mensaje con archivo. En esta versión de TDLib el archivo va dentro de un
    /// objeto propio de cada tipo (`inputPhoto`, `inputDocument`…), no directamente en el mensaje.
    static func fileContent(path: String, caption: String?, kind: TGMediaKind) -> JSONValue {
        let file: JSONValue = ["@type": "inputFileLocal", "path": .string(path)]
        var content: [String: JSONValue]
        switch kind {
        case .photo:
            content = ["@type": "inputMessagePhoto", "photo": ["@type": "inputPhoto", "photo": file]]
        case .video:
            content = ["@type": "inputMessageVideo",
                       "video": ["@type": "inputVideo", "video": file, "supports_streaming": true]]
        case .animation:
            content = ["@type": "inputMessageAnimation", "animation": ["@type": "inputAnimation", "animation": file]]
        case .audio:
            content = ["@type": "inputMessageAudio", "audio": ["@type": "inputAudio", "audio": file]]
        case .voice:
            content = ["@type": "inputMessageVoiceNote", "voice_note": ["@type": "inputVoiceNote", "voice_note": file]]
        case .document:
            content = ["@type": "inputMessageDocument", "document": ["@type": "inputDocument", "document": file]]
        }
        if let caption, !caption.isEmpty {
            content["caption"] = ["@type": "formattedText", "text": .string(caption)]
        }
        return .object(content)
    }

    public func sendFile(chatID: Int64, data: Data, filename: String, caption: String?, kind: TGMediaKind) async throws {
        try checkTarget(chatID)
        try requireReady()
        // TDLib sube desde un archivo local, y lo hace después de contestar: tiene que seguir ahí.
        let folder = try Self.outgoingFolder().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = (filename as NSString).lastPathComponent.isEmpty ? "archivo" : (filename as NSString).lastPathComponent
        let url = folder.appendingPathComponent(safeName)
        try data.write(to: url)
        let message = try await request([
            "@type": "sendMessage", "chat_id": .number(Double(chatID)),
            "input_message_content": Self.fileContent(path: url.path, caption: caption, kind: kind),
        ])
        // La respuesta solo dice que está en cola: el resultado de la subida llega después.
        if let id = message["id"]?.intValue { try await waitForDelivery(messageID: Int64(id)) }
    }

    /// Espera a que Telegram confirme o rechace un mensaje en cola. Si pasa el tiempo sin noticia
    /// (una subida lenta), se da por bueno: sigue subiendo.
    func waitForDelivery(messageID: Int64, timeout: TimeInterval = 90) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deliveries[messageID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.finishDelivery(messageID, error: nil)
            }
        }
    }

    private func finishDelivery(_ messageID: Int64, error: Error?) {
        guard let continuation = deliveries.removeValue(forKey: messageID) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    static func textContent(_ text: String) -> JSONValue {
        ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": .string(text)]]
    }

    public func reply(chatID: Int64, messageID: Int64, text: String) async throws {
        try checkTarget(chatID)
        try requireReady()
        let message = try await request([
            "@type": "sendMessage", "chat_id": .number(Double(chatID)),
            "reply_to": ["@type": "inputMessageReplyToMessage", "message_id": .number(Double(messageID))],
            "input_message_content": Self.textContent(text),
        ])
        if let id = message["id"]?.intValue { try await waitForDelivery(messageID: Int64(id), timeout: 30) }
    }

    public func forward(fromChatID: Int64, messageIDs: [Int64], toChatID: Int64) async throws {
        try checkTarget(toChatID)
        try requireReady()
        _ = try await request([
            "@type": "forwardMessages", "chat_id": .number(Double(toChatID)), "from_chat_id": .number(Double(fromChatID)),
            "message_ids": .array(messageIDs.map { .number(Double($0)) }), "send_copy": false, "remove_caption": false,
        ])
    }

    public func edit(chatID: Int64, messageID: Int64, text: String) async throws {
        try requireReady()
        _ = try await request([
            "@type": "editMessageText", "chat_id": .number(Double(chatID)), "message_id": .number(Double(messageID)),
            "input_message_content": Self.textContent(text),
        ])
    }

    public func react(chatID: Int64, messageID: Int64, emoji: String) async throws {
        try requireReady()
        _ = try await request([
            "@type": "addMessageReaction", "chat_id": .number(Double(chatID)), "message_id": .number(Double(messageID)),
            "reaction_type": ["@type": "reactionTypeEmoji", "emoji": .string(emoji)],
            "is_big": false, "update_recent_reactions": true,
        ])
    }

    public func markRead(chatID: Int64) async throws -> Int {
        try requireReady()
        let history = try await request([
            "@type": "getChatHistory", "chat_id": .number(Double(chatID)), "from_message_id": 0,
            "offset": 0, "limit": 50, "only_local": false,
        ])
        let ids = (history["messages"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue }
        guard !ids.isEmpty else { return 0 }
        _ = try await request([
            "@type": "viewMessages", "chat_id": .number(Double(chatID)),
            "message_ids": .array(ids.map { .number(Double($0)) }),
            "source": ["@type": "messageSourceChatHistory"], "force_read": true,
        ])
        return ids.count
    }

    /// El archivo de un mensaje (foto en su tamaño mayor, documento, nota de voz…) y cómo llamarlo.
    static func mediaFile(in message: JSONValue) -> (file: JSONValue, name: String, kind: String)? {
        let content = message["content"]
        let id = message["id"]?.intValue ?? 0
        switch content?["@type"]?.stringValue {
        case "messagePhoto":
            guard let file = content?["photo"]?["sizes"]?.arrayValue?.last?["photo"] else { return nil }
            return (file, "foto-\(id).jpg", "foto")
        case "messageDocument":
            guard let file = content?["document"]?["document"] else { return nil }
            let name = content?["document"]?["file_name"]?.stringValue ?? ""
            return (file, name.isEmpty ? "documento-\(id)" : name, "documento")
        case "messageVoiceNote":
            guard let file = content?["voice_note"]?["voice"] else { return nil }
            return (file, "nota-de-voz-\(id).ogg", "nota de voz")
        case "messageAudio":
            guard let file = content?["audio"]?["audio"] else { return nil }
            let name = content?["audio"]?["file_name"]?.stringValue ?? ""
            return (file, name.isEmpty ? "audio-\(id).mp3" : name, "audio")
        case "messageVideo":
            guard let file = content?["video"]?["video"] else { return nil }
            let name = content?["video"]?["file_name"]?.stringValue ?? ""
            return (file, name.isEmpty ? "video-\(id).mp4" : name, "vídeo")
        case "messageAnimation":
            guard let file = content?["animation"]?["animation"] else { return nil }
            return (file, "animacion-\(id).mp4", "animación")
        case "messageVideoNote":
            guard let file = content?["video_note"]?["video"] else { return nil }
            return (file, "video-redondo-\(id).mp4", "vídeo redondo")
        default:
            return nil
        }
    }

    /// Hasta este tamaño se descarga un archivo recibido.
    public static let maxDownload = 50 * 1024 * 1024

    public func download(chatID: Int64, messageID: Int64) async throws -> TGDownloadedMedia {
        try requireReady()
        let message = try await request(["@type": "getMessage", "chat_id": .number(Double(chatID)),
                                         "message_id": .number(Double(messageID))])
        guard let media = Self.mediaFile(in: message), let fileID = media.file["id"]?.intValue else {
            throw TelegramUserError.noMedia
        }
        let size = media.file["size"]?.intValue ?? media.file["expected_size"]?.intValue ?? 0
        guard size <= Self.maxDownload else { throw TelegramUserError.tooLarge }
        let file = try await request([
            "@type": "downloadFile", "file_id": .number(Double(fileID)), "priority": 16,
            "offset": 0, "limit": 0, "synchronous": true,
        ])
        guard file["local"]?["is_downloading_completed"]?.boolValue == true,
              let path = file["local"]?["path"]?.stringValue, !path.isEmpty else { throw TelegramUserError.noMedia }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let safe = (media.name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return TGDownloadedMedia(data: data, filename: safe, kind: media.kind)
    }

    public func delete(chatID: Int64, messageIDs: [Int64], forEveryone: Bool) async throws {
        try requireReady()
        _ = try await request([
            "@type": "deleteMessages", "chat_id": .number(Double(chatID)),
            "message_ids": .array(messageIDs.map { .number(Double($0)) }), "revoke": .bool(forEveryone),
        ])
    }

    // MARK: Conversión

    func convert(_ raw: [JSONValue]) async -> [TGUserMessage] {
        var out: [TGUserMessage] = []
        for message in raw {
            guard let id = message["id"]?.intValue, let chatID = message["chat_id"]?.intValue else { continue }
            out.append(TGUserMessage(
                id: Int64(id), chatID: Int64(chatID), sender: await senderName(message["sender_id"]),
                date: Date(timeIntervalSince1970: message["date"]?.doubleValue ?? 0),
                text: Self.text(of: message), outgoing: message["is_outgoing"]?.boolValue ?? false))
        }
        return out
    }

    private func senderName(_ sender: JSONValue?) async -> String {
        if let id = sender?["user_id"]?.intValue {
            if let name = userNames[Int64(id)] { return name }
            if let user = try? await request(["@type": "getUser", "user_id": .number(Double(id))]) {
                let name = Self.name(of: user)
                userNames[Int64(id)] = name
                return name
            }
            return "Usuario \(id)"
        }
        if let id = sender?["chat_id"]?.intValue {
            if let chat = chatCache[Int64(id)] { return chat.title }
            return (try? await chat(id: Int64(id)))?.title ?? "Chat \(id)"
        }
        return "Desconocido"
    }

    /// Texto legible de un mensaje; lo que no es texto se nombra entre corchetes.
    static func text(of message: JSONValue) -> String {
        let content = message["content"]
        let type = content?["@type"]?.stringValue ?? ""
        if type == "messageText" { return content?["text"]?["text"]?.stringValue ?? "" }
        if let detail = detail(of: content) { return detail }
        let label: String
        switch type {
        case "messagePhoto": label = "[foto]"
        case "messageVideo", "messageAnimation": label = "[vídeo]"
        case "messageVideoNote": label = "[vídeo redondo]"
        case "messageVoiceNote": label = "[nota de voz]"
        case "messageAudio": label = "[audio]"
        case "messageDocument": label = "[archivo]"
        case "messageSticker", "messageAnimatedEmoji": label = "[sticker]"
        case "messageLocation", "messageVenue": label = "[ubicación]"
        case "messageContact": label = "[contacto]"
        case "messagePoll": label = "[encuesta]"
        case "": label = "[mensaje]"
        default: label = "[otro tipo de mensaje]"
        }
        let caption = content?["caption"]?["text"]?.stringValue ?? ""
        return caption.isEmpty ? label : "\(label) \(caption)"
    }

    /// Encuestas, ubicaciones, contactos y dados con lo que hace falta para usarlos: las respuestas
    /// de una encuesta van numeradas desde 0, que es lo que pide telegram_vote.
    static func detail(of content: JSONValue?) -> String? {
        switch content?["@type"]?.stringValue {
        case "messagePoll":
            guard let poll = content?["poll"] else { return nil }
            let question = poll["question"]?["text"]?.stringValue ?? ""
            let options = (poll["options"]?.arrayValue ?? []).enumerated().map { index, option -> String in
                var text = "\(index)) \(option["text"]?["text"]?.stringValue ?? "")"
                if let votes = option["voter_count"]?.intValue, votes > 0 { text += " (\(votes))" }
                if option["is_chosen"]?.boolValue == true { text += " ✓ tu voto" }
                return text
            }
            let closed = poll["is_closed"]?.boolValue == true ? " (cerrada)" : ""
            return "[encuesta\(closed)] \(question) · " + options.joined(separator: " · ")
        case "messageLocation":
            guard let lat = content?["location"]?["latitude"]?.doubleValue,
                  let lon = content?["location"]?["longitude"]?.doubleValue else { return nil }
            return String(format: "[ubicación] %.5f, %.5f", lat, lon)
        case "messageContact":
            let contact = content?["contact"]
            let name = [contact?["first_name"]?.stringValue, contact?["last_name"]?.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? nil : "[contacto] \(name)"
        case "messageDice":
            let emoji = content?["emoji"]?.stringValue ?? "🎲"
            let value = content?["value"]?.intValue ?? 0
            return value > 0 ? "[dado \(emoji) \(value)]" : "[dado \(emoji)]"
        default:
            return nil
        }
    }
}
