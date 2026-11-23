import Foundation
import SaySoCore

// MARK: - Modelos de la Bot API (solo los campos que usamos)

public struct TGUser: Decodable, Sendable, Hashable {
    public var id: Int64
    public var isBot: Bool?
    public var firstName: String?
    public var lastName: String?
    public var username: String?

    public var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? (username.map { "@\($0)" } ?? "Usuario \(id)") : full
    }
}

public struct TGChat: Decodable, Sendable, Hashable {
    public var id: Int64
    /// private, group, supergroup, channel
    public var type: String
    public var title: String?
    public var username: String?

    public var isPrivate: Bool { type == "private" }
    public var isGroup: Bool { type == "group" || type == "supergroup" }
}

public struct TGVoice: Decodable, Sendable, Hashable {
    public var fileId: String
    public var duration: Int?
}

/// Mensaje citado: lo justo para darle contexto al agente.
public struct TGQuotedMessage: Decodable, Sendable, Hashable {
    public var from: TGUser?
    public var text: String?
    public var caption: String?
}

public struct TGMessage: Decodable, Sendable, Hashable {
    public var messageId: Int64
    public var from: TGUser?
    public var chat: TGChat
    public var date: Int?
    public var text: String?
    public var caption: String?
    public var voice: TGVoice?
    public var audio: TGVoice?
    /// Mensaje al que responde este.
    public var replyToMessage: TGQuotedMessage?
    /// En una mención en modo invitado: el identificador con el que se contesta, una sola vez.
    public var guestQueryId: String?
    /// Tamaños de una foto, de menor a mayor.
    public var photo: [TGPhotoSize]?
    /// Un archivo mandado como documento (PDF, CSV, una foto sin comprimir…).
    public var document: TGDocument?
    /// De dónde viene un mensaje reenviado; `nil` si lo escribió quien lo manda.
    public var forwardOrigin: TGForwardOrigin?
}

/// Origen de un mensaje reenviado. Solo importa que lo sea: el texto es de otra persona.
public struct TGForwardOrigin: Decodable, Sendable, Hashable {
    public var type: String?
}

public struct TGDocument: Decodable, Sendable, Hashable {
    public var fileId: String
    public var fileName: String?
    public var mimeType: String?
    public var fileSize: Int?
}

public struct TGPhotoSize: Decodable, Sendable, Hashable {
    public var fileId: String
    public var width: Int?
    public var height: Int?
}

/// Lo que devuelve `answerGuestQuery`. No se usa ningún campo.
public struct TGSentGuestMessage: Decodable, Sendable, Hashable {}

public struct TGCallbackQuery: Decodable, Sendable, Hashable {
    public var id: String
    public var from: TGUser
    public var message: TGMessage?
    public var data: String?
}

public struct TGInlineQuery: Decodable, Sendable, Hashable {
    public var id: String
    public var from: TGUser
    public var query: String
}

public struct TGUpdate: Decodable, Sendable, Hashable {
    public var updateId: Int64
    public var message: TGMessage?
    public var callbackQuery: TGCallbackQuery?
    public var inlineQuery: TGInlineQuery?
    /// Mención al bot en un chat donde no está (Guest Mode, Bot API 10.0).
    public var guestMessage: TGMessage?
}

public struct TGFile: Decodable, Sendable, Hashable {
    public var fileId: String
    public var filePath: String?
    public var fileSize: Int?
}

public struct TGInlineButton: Sendable, Hashable {
    public var text: String
    public var callbackData: String
    public init(text: String, callbackData: String) {
        self.text = text
        self.callbackData = callbackData
    }
}

/// Resultado inline tipo artículo.
public struct TGInlineArticle: Sendable, Hashable {
    public var id: String
    public var title: String
    public var description: String?
    public var messageText: String
    public init(id: String, title: String, description: String?, messageText: String) {
        self.id = id
        self.title = title
        self.description = description
        self.messageText = messageText
    }
}

public enum TelegramError: Error, LocalizedError, Sendable, Equatable {
    case api(code: Int, description: String)
    /// 429 con el tiempo que Telegram pide esperar.
    case rateLimited(retryAfter: Int)
    case invalidResponse

    /// Token rechazado por Telegram.
    public var isUnauthorized: Bool {
        if case let .api(code, _) = self { return code == 401 || code == 404 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case let .api(code, description):
            if code == 401 || code == 404 { return tr("El token del bot no es válido.") }
            if code == 409 { return tr("Otra copia de SaySo u otro programa está leyendo este bot, o tiene un webhook activo.") }
            if code == 429 { return tr("Telegram está limitando la frecuencia de peticiones.") }
            return tr("Telegram: %@ (%@)", "\(description)", "\(code)")
        case let .rateLimited(seconds):
            return tr("Telegram está limitando la frecuencia de peticiones (espera %@ s).", "\(seconds)")
        case .invalidResponse: return tr("Respuesta de Telegram no válida.")
        }
    }
}

// MARK: - Cliente

/// Cliente mínimo de la Bot API sobre `HTTPTransport`.
public struct TelegramBotClient: Sendable {
    public static let messageLimit = 4096
    private let token: String
    private let baseURL: URL
    private let transport: HTTPTransport

    public init(token: String, transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.telegram.org")!) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    public func getMe() async throws -> TGUser {
        try await call("getMe", [:])
    }

    /// Sondeo largo: `timeout` en segundos.
    public func getUpdates(offset: Int64?, timeout: Int = 50) async throws -> [TGUpdate] {
        var body: [String: JSONValue] = [
            "timeout": .number(Double(timeout)),
            "allowed_updates": ["message", "callback_query", "inline_query", "guest_message"],
        ]
        if let offset { body["offset"] = .number(Double(offset)) }
        return try await call("getUpdates", body, requestTimeout: TimeInterval(timeout + 15))
    }

    /// Envía texto troceado a 4096 caracteres; el teclado va en el último trozo.
    @discardableResult
    /// `retries`: cuántas veces repetir cada trozo ante un fallo pasajero (429, 5xx, red). Para las
    /// respuestas del agente, que si no se perderían sin aviso; se reintenta trozo a trozo para no
    /// repetir lo que ya llegó.
    public func sendMessage(chatID: Int64, text: String, buttons: [[TGInlineButton]]? = nil,
                            retries: Int = 0) async throws -> [TGMessage] {
        let chunks = Self.chunk(text)
        var sent: [TGMessage] = []
        for (i, chunk) in chunks.enumerated() {
            var body: [String: JSONValue] = ["chat_id": .number(Double(chatID)), "text": .string(chunk)]
            if let buttons, i == chunks.count - 1 { body["reply_markup"] = Self.keyboard(buttons) }
            sent.append(try await retrying(retries) { try await call("sendMessage", body) })
        }
        return sent
    }

    /// Escala de las esperas entre reintentos; los tests la ponen a 0.
    public var retryScale: Double = 1

    private func retrying<T>(_ retries: Int, _ body: () async throws -> T) async throws -> T {
        let delays: [Double] = [1, 3, 8]
        var attempt = 0
        while true {
            do { return try await body() } catch {
                guard attempt < min(retries, delays.count), let wait = Self.retryWait(error, default: delays[attempt]) else { throw error }
                if wait * retryScale > 0 { try await Task.sleep(nanoseconds: UInt64(wait * retryScale * 1_000_000_000)) }
                attempt += 1
            }
        }
    }

    /// Cuánto esperar antes de repetir, o `nil` si el fallo no es pasajero.
    static func retryWait(_ error: Error, default delay: Double) -> Double? {
        switch error {
        case let TelegramError.rateLimited(after) where after <= 60: return Double(after)
        case let TelegramError.api(code, _) where code >= 500: return delay
        case is URLError: return delay
        default: return nil
        }
    }

    /// Menú de comandos del bot (el botón «/» de Telegram), solo en chats privados.
    public func setMyCommands(_ commands: [(command: String, description: String)]) async throws {
        let list = commands.map { JSONValue.object(["command": .string($0.command), "description": .string(String($0.description.prefix(256)))]) }
        let _: JSONValue = try await call("setMyCommands", ["commands": .array(list),
                                                             "scope": .object(["type": .string("all_private_chats")])])
    }

    public func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {
        let _: TGMessage = try await call("editMessageText", ["chat_id": .number(Double(chatID)),
                                                              "message_id": .number(Double(messageID)),
                                                              "text": .string(String(text.prefix(4096)))])
    }

    public func deleteMessage(chatID: Int64, messageID: Int64) async throws {
        let _: Bool = try await call("deleteMessage", ["chat_id": .number(Double(chatID)), "message_id": .number(Double(messageID))])
    }

    public func sendChatAction(chatID: Int64, action: String = "typing") async throws {
        let _: Bool = try await call("sendChatAction", ["chat_id": .number(Double(chatID)), "action": .string(action)])
    }

    public func answerCallbackQuery(id: String, text: String? = nil) async throws {
        var body: [String: JSONValue] = ["callback_query_id": .string(id)]
        if let text { body["text"] = .string(text) }
        let _: Bool = try await call("answerCallbackQuery", body)
    }

    /// Quita (o cambia) el teclado inline de un mensaje.
    public func editMessageReplyMarkup(chatID: Int64, messageID: Int64, buttons: [[TGInlineButton]]? = nil) async throws {
        var body: [String: JSONValue] = ["chat_id": .number(Double(chatID)), "message_id": .number(Double(messageID))]
        body["reply_markup"] = Self.keyboard(buttons ?? [])
        let _: JSONValue = try await call("editMessageReplyMarkup", body)
    }

    public func answerInlineQuery(id: String, results: [TGInlineArticle], cacheTime: Int = 0,
                                  isPersonal: Bool = true) async throws {
        let items: [JSONValue] = results.map { a in
            var r: [String: JSONValue] = [
                "type": "article", "id": .string(a.id), "title": .string(a.title),
                "input_message_content": ["message_text": .string(String(a.messageText.prefix(Self.messageLimit)))],
            ]
            if let d = a.description { r["description"] = .string(d) }
            return .object(r)
        }
        let _: Bool = try await call("answerInlineQuery", [
            "inline_query_id": .string(id), "results": .array(items),
            "cache_time": .number(Double(cacheTime)), "is_personal": .bool(isPersonal),
        ])
    }

    /// Contesta a una mención en modo invitado. Telegram admite una sola respuesta por mención; el
    /// mensaje se describe como un resultado inline de tipo artículo.
    /// Responde a una mención en modo invitado con una foto ya subida a Telegram.
    public func answerGuestQuery(id: String, photoFileID: String, caption: String?) async throws {
        var result: [String: JSONValue] = ["type": "photo", "id": "1", "photo_file_id": .string(photoFileID)]
        if let caption, !caption.isEmpty { result["caption"] = .string(String(caption.prefix(1024))) }
        let _: TGSentGuestMessage = try await call("answerGuestQuery",
                                                   ["guest_query_id": .string(id), "result": .object(result)])
    }

    public func answerGuestQuery(id: String, text: String) async throws {
        let result: JSONValue = [
            "type": "article", "id": "1", "title": "SaySo",
            "input_message_content": ["message_text": .string(String(text.prefix(Self.messageLimit)))],
        ]
        let _: TGSentGuestMessage = try await call("answerGuestQuery", ["guest_query_id": .string(id), "result": result])
    }

    /// Sube un archivo al chat: las imágenes como foto y el resto como documento.
    @discardableResult
    public func sendFile(chatID: Int64, data: Data, filename: String, caption: String?, asPhoto: Bool) async throws -> TGMessage {
        let method = asPhoto ? "sendPhoto" : "sendDocument"
        let boundary = "sayso-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        if let caption, !caption.isEmpty { field("caption", String(caption.prefix(1024))) }
        // El nombre va entre comillas: se le quitan las que traiga y los saltos de línea.
        let safeName = filename.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(asPhoto ? "photo" : "document")\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: baseURL.appendingPathComponent("bot\(token)").appendingPathComponent(method),
                                 timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = body
        let (responseData, response) = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope<TGMessage>.self, from: responseData), envelope.ok else {
            let envelope = try? decoder.decode(Envelope<TGMessage>.self, from: responseData)
            throw TelegramError.api(code: envelope?.errorCode ?? response.statusCode,
                                    description: envelope?.description ?? "no se pudo enviar el archivo")
        }
        guard let message = envelope.result else { throw TelegramError.invalidResponse }
        return message
    }

    public func getFile(fileID: String) async throws -> TGFile {
        try await call("getFile", ["file_id": .string(fileID)])
    }

    /// Descarga un archivo por su `file_path`.
    public func downloadFile(path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("file").appendingPathComponent("bot\(token)").appendingPathComponent(path)
        let (data, response) = try await transport.send(URLRequest(url: url, timeoutInterval: 120))
        guard (200..<300).contains(response.statusCode) else {
            throw TelegramError.api(code: response.statusCode, description: "descarga fallida")
        }
        return data
    }

    // MARK: Widgets (Bot API 10.4)

    /// Un mensaje con un widget HTML. En producción, solo en chats privados con el bot.
    public func sendWidget(chatID: Int64, html: String, height: Int? = nil, chatData: String? = nil,
                           caption: String? = nil) async throws -> TGMessage {
        var body: [String: JSONValue] = ["chat_id": .number(Double(chatID)), "html": .string(html)]
        if let height { body["height"] = .number(Double(height)) }
        if let chatData, !chatData.isEmpty { body["chat_data"] = .string(chatData) }
        if let caption, !caption.isEmpty { body["caption"] = .string(String(caption.prefix(1024))) }
        return try await call("sendWidget", body)
    }

    /// Cambia los datos de un widget ya enviado (lo que lee con `TelegramWidget.chatData`).
    public func editMessageWidgetData(chatID: Int64, messageID: Int64, chatData: String) async throws {
        let _: Bool = try await call("editMessageWidgetData", ["chat_id": .number(Double(chatID)),
                                                               "message_id": .number(Double(messageID)),
                                                               "chat_data": .string(chatData)])
    }

    // MARK: Interno

    private func call<T: Decodable>(_ method: String, _ body: [String: JSONValue],
                                    requestTimeout: TimeInterval = 60) async throws -> T {
        let url = baseURL.appendingPathComponent("bot\(token)").appendingPathComponent(method)
        let request = try URLRequest.postJSON(url, body: .object(body), timeout: requestTimeout)
        let (data, response) = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope<T>.self, from: data) else {
            if !(200..<300).contains(response.statusCode) {
                throw TelegramError.api(code: response.statusCode, description: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
            }
            throw TelegramError.invalidResponse
        }
        guard envelope.ok, let result = envelope.result else {
            if let wait = envelope.parameters?.retryAfter { throw TelegramError.rateLimited(retryAfter: wait) }
            throw TelegramError.api(code: envelope.errorCode ?? response.statusCode,
                                    description: envelope.description ?? "error desconocido")
        }
        return result
    }

    private struct Envelope<T: Decodable>: Decodable {
        var ok: Bool
        var result: T?
        var errorCode: Int?
        var description: String?
        var parameters: Parameters?

        struct Parameters: Decodable { var retryAfter: Int? }
    }

    static func keyboard(_ rows: [[TGInlineButton]]) -> JSONValue {
        ["inline_keyboard": .array(rows.map { row in
            .array(row.map { ["text": .string($0.text), "callback_data": .string($0.callbackData)] })
        })]
    }

    /// Trocea en partes de como mucho `limit` unidades UTF-16 (como cuenta Telegram),
    /// cortando preferentemente en saltos de línea y luego en espacios.
    public static func chunk(_ text: String, limit: Int = messageLimit) -> [String] {
        guard text.utf16.count > limit else { return [text] }
        var chunks: [String] = []
        var rest = Substring(text)
        while rest.utf16.count > limit {
            // Mayor prefijo de caracteres completos que cabe.
            var end = rest.startIndex
            var units = 0
            while end < rest.endIndex {
                let n = rest[end].utf16.count
                if units + n > limit { break }
                units += n
                end = rest.index(after: end)
            }
            if end == rest.startIndex { end = rest.index(after: end) } // carácter gigante: se fuerza
            let window = rest[rest.startIndex..<end]
            var cut = end
            let minimum = window.index(window.startIndex, offsetBy: window.count / 2)
            if let nl = window.lastIndex(of: "\n"), nl >= minimum {
                cut = window.index(after: nl)
            } else if let sp = window.lastIndex(of: " "), sp >= minimum {
                cut = window.index(after: sp)
            }
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks.isEmpty ? [""] : chunks
    }
}
